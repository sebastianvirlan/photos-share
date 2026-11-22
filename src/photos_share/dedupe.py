"""photos-dedupe: after File → Import from another library, find what's safe to delete.

Read-only by default: reports which photos of SOURCE are already in DEST. Then, after you
confirm:
  --trash-library  everything verified → the whole SOURCE library goes to the Trash;
  --delete         verified photos are deleted via PhotoKit (SOURCE must be the System
                   Photo Library; macOS confirms; Recently Deleted keeps them 30 days);
  --mark           verified photos are collected in an album in SOURCE for you to delete.
It never edits a library's database itself.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

BATCH = 200          # photos added to the album per AppleScript call
SAMPLE = 15          # missing photos listed in the report


@dataclass(frozen=True)
class Item:
    """The parts of a photo that identify it across libraries."""
    uuid: str
    fingerprint: str | None
    filename: str | None
    size: int | None
    date: str           # ISO, second precision
    edited: bool
    hidden: bool = False

    @classmethod
    def from_photo(cls, p) -> "Item":
        return cls(uuid=p.uuid, fingerprint=p.fingerprint,
                   filename=(p.original_filename or "").lower() or None,
                   size=p.original_filesize or None,
                   date=p.date.replace(microsecond=0).isoformat() if p.date else "",
                   edited=bool(p.hasadjustments), hidden=bool(p.hidden))

    @property
    def fallback_key(self):
        if self.filename and self.size:
            return (self.filename, self.size, self.date)
        return None


@dataclass
class Result:
    matched: list[Item] = field(default_factory=list)            # safe to delete from source
    matched_by_fallback: int = 0                                 # of `matched`, not by fingerprint
    edit_lost: list[Item] = field(default_factory=list)          # in DEST, but without the edit
    missing: list[Item] = field(default_factory=list)            # not in DEST at all
    pairs: dict[str, tuple[str, str]] = field(default_factory=dict)  # src uuid → (dest uuid, how)

    @property
    def total(self) -> int:
        return len(self.matched) + len(self.edit_lost) + len(self.missing)


def match(source: list[Item], dest: list[Item]) -> Result:
    """Match by content fingerprint first, then by (filename, size, date)."""
    by_fp: dict[str, list[Item]] = defaultdict(list)
    by_key: dict[tuple, list[Item]] = defaultdict(list)
    for d in dest:
        if d.fingerprint:
            by_fp[d.fingerprint].append(d)
        if d.fallback_key:
            by_key[d.fallback_key].append(d)

    r = Result()
    for s in source:
        hits = by_fp.get(s.fingerprint, []) if s.fingerprint else []
        fallback = False
        if not hits and s.fallback_key:
            hits, fallback = by_key.get(s.fallback_key, []), True
        if not hits:
            r.missing.append(s)
            continue
        best = next((d for d in hits if d.edited), hits[0]) if s.edited else hits[0]
        r.pairs[s.uuid] = (best.uuid, "filename, size and date" if fallback else "fingerprint")
        if s.edited and not best.edited:
            r.edit_lost.append(s)
        else:
            r.matched.append(s)
            r.matched_by_fallback += fallback
    return r


def load(path: Path) -> list[Item]:
    import osxphotos
    db = osxphotos.PhotosDB(dbfile=str(path), _skip_searchinfo=True)
    return [Item.from_photo(p) for p in db.photos()]  # excludes Recently Deleted


def report(r: Result, src: Path, dst: Path) -> str:
    lines = [
        f"Source:      {src.stem}  ({r.total:,} items)",
        f"Destination: {dst.stem}",
        "",
        f"  ✓ In destination:            {len(r.matched):,}"
        + (f"  ({r.matched_by_fallback:,} matched by filename+size+date)"
           if r.matched_by_fallback else ""),
        f"  ! In destination, edit lost: {len(r.edit_lost):,}  (kept out of the delete album)",
        f"  ✗ Not in destination:        {len(r.missing):,}",
    ]
    if r.missing:
        lines += ["", "Not imported (first few):"]
        lines += [f"  {i.filename or i.uuid}  {i.date[:10]}" for i in r.missing[:SAMPLE]]
    lines.append("")
    if r.total and not r.missing and not r.edit_lost:
        lines.append(f"Everything in “{src.stem}” is in “{dst.stem}”. After a final look, the "
                     "whole source library can go to the Trash (--trash-library).")
    elif r.matched:
        lines.append(f"Run again with --delete (if the source is the System Photo Library) or "
                     f"--mark to clean up the {len(r.matched):,} verified photos.")
    return "\n".join(lines)


def mark(src: Path, items: list[Item], album_name: str) -> int:
    """Open SOURCE in Photos and put `items` into a new album there. Returns count added."""
    import photoscript

    lib = photoscript.PhotosLibrary()
    lib.open(str(src))  # quits Photos and reopens it with SOURCE
    try:
        photoscript.Photo(items[0].uuid)
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"Photos didn't open “{src.stem}” (or it's still loading); "
                           "open it manually, then run --mark again.") from e
    name, n = album_name, 2
    while name in lib.album_names():
        name, n = f"{album_name} ({n})", n + 1
    album = lib.create_album(name)
    added = 0
    for i in range(0, len(items), BATCH):
        album.add([photoscript.Photo(it.uuid) for it in items[i:i + BATCH]])
        added += len(items[i:i + BATCH])
    album.spotlight()
    return added


# ---- automatic clean-up ------------------------------------------------------------
#
# Two safe ways to remove what was imported, without touching the database ourselves:
#  * everything imported → move the whole source library to the Trash (restorable);
#  * some imported       → delete those photos with PhotoKit, Apple's API, which only works
#                           on the System Photo Library, asks the user to confirm, and puts
#                           the photos in Recently Deleted for 30 days.

class CleanupError(Exception):
    """Refused for safety; the message says why and what to do."""


def all_verified(r: Result) -> bool:
    return r.total > 0 and not r.missing and not r.edit_lost


def system_library() -> Path | None:
    from osxphotos.utils import get_system_library_path
    p = get_system_library_path()
    return Path(p).resolve() if p else None


def photos_running() -> bool:
    from AppKit import NSRunningApplication
    return bool(NSRunningApplication.runningApplicationsWithBundleIdentifier_("com.apple.Photos"))


def trash_library(src: Path, r: Result) -> Path:
    """Move the whole SOURCE library to the Trash. Only when every photo was verified."""
    from Foundation import NSURL, NSFileManager

    if not all_verified(r):
        raise CleanupError("Not every photo is in the destination, so the library is kept.")
    if system_library() == src.resolve():
        raise CleanupError(f"“{src.stem}” is the System Photo Library. Choose another one in "
                           "Photos → Settings → General first.")
    if photos_running():
        raise CleanupError("Quit Photos first, so it isn’t using the library.")
    ok, trashed, err = NSFileManager.defaultManager().trashItemAtURL_resultingItemURL_error_(
        NSURL.fileURLWithPath_(str(src)), None, None)
    if not ok:
        raise CleanupError(f"Couldn’t move it to the Trash: {err}")
    return Path(trashed.path()) if trashed else src


def can_delete_with_photokit(src: Path) -> bool:
    return system_library() == src.resolve()


def _epoch(iso: str) -> float:
    from datetime import datetime
    return datetime.fromisoformat(iso).timestamp()


def delete_with_photokit(src: Path, items: list[Item], wait=None) -> int:
    """Delete `items` from SOURCE through PhotoKit. Returns how many were deleted.

    `wait(event, timeout)` waits for PhotoKit callbacks; the CLI passes one that keeps the
    main run loop turning (the confirmation dialog needs it), the app runs this on a thread.
    """
    import threading

    import Photos

    if not items:
        return 0
    if not can_delete_with_photokit(src):
        raise CleanupError(f"“{src.stem}” isn’t the System Photo Library, so Photos won’t "
                           "let other apps delete from it. Set it in Photos → Settings → "
                           "General → Use as System Photo Library, or use “Mark in Photos”.")
    wait = wait or (lambda ev, t: ev.wait(t))

    # 1. Permission (macOS asks the first time).
    done, status = threading.Event(), {}

    def on_auth(s):
        status["s"] = s
        done.set()

    Photos.PHPhotoLibrary.requestAuthorizationForAccessLevel_handler_(
        Photos.PHAccessLevelReadWrite, on_auth)
    wait(done, 120)
    if status.get("s") != Photos.PHAuthorizationStatusAuthorized:
        raise CleanupError("Photos access wasn’t granted (System Settings → Privacy & "
                           "Security → Photos).")

    # 2. Find exactly these photos, and check each one is the photo we verified.
    ids = [f"{it.uuid}/L0/001" for it in items]
    found = Photos.PHAsset.fetchAssetsWithLocalIdentifiers_options_(ids, None)
    if found.count() != len(items):
        raise CleanupError(f"Only {found.count()} of {len(items)} photos were found in the "
                           "System Photo Library; nothing was deleted.")
    expected = {it.uuid: _epoch(it.date) for it in items if it.date}
    for i in range(found.count()):
        asset = found.objectAtIndex_(i)
        uuid = str(asset.localIdentifier()).split("/")[0]
        when = asset.creationDate()
        if uuid in expected and when is not None and \
                abs(when.timeIntervalSince1970() - expected[uuid]) > 1.5:
            raise CleanupError(f"Photo {uuid} doesn’t match the one verified (different "
                               "date); nothing was deleted.")

    # 3. Delete (macOS shows its own confirmation; photos go to Recently Deleted).
    done, result = threading.Event(), {}

    def changes():
        Photos.PHAssetChangeRequest.deleteAssets_(found)

    def on_done(success, error):
        result.update(ok=bool(success), error=error)
        done.set()

    Photos.PHPhotoLibrary.sharedPhotoLibrary().performChanges_completionHandler_(changes, on_done)
    wait(done, 600)
    if not done.is_set():
        raise CleanupError("Timed out waiting for Photos.")
    if not result.get("ok"):
        err = result.get("error")
        raise CleanupError("Nothing was deleted" + (f": {err.localizedDescription()}" if err
                                                    else " (cancelled)."))
    return len(items)


def _wait_with_runloop(event, timeout: float) -> None:
    """Wait while letting the main run loop process events (e.g. the confirm dialog)."""
    import time

    from Foundation import NSDate, NSRunLoop
    end = time.monotonic() + timeout
    while not event.is_set() and time.monotonic() < end:
        NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.1))


def _confirm(question: str) -> bool:
    return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")


def thumbnail_map(library: Path) -> dict[str, str]:
    """uuid → path of a preview JPEG Photos already made (for the app's grids).

    Lists each derivatives folder once (not once per photo), preferring the small
    "masters" previews (~360 px), which are plenty for a grid and quick to load.
    """
    out: dict[str, str] = {}
    base = library / "resources" / "derivatives"
    for folder, preferred in ((base, False), (base / "masters", True)):
        for sub in "0123456789ABCDEF":
            d = folder / sub
            try:
                names = os.listdir(d)
            except FileNotFoundError:
                continue
            for name in names:
                if not name.lower().endswith((".jpg", ".jpeg")):
                    continue
                uuid = name.split("_", 1)[0]
                if preferred or uuid not in out:
                    out[uuid] = str(d / name)
    return out


def to_json(r: Result, src: Path, dst: Path) -> dict:
    src_thumbs, dst_thumbs = thumbnail_map(src), thumbnail_map(dst)
    system = system_library()

    def row(i: Item) -> dict:
        pair = r.pairs.get(i.uuid)
        return {"uuid": i.uuid, "name": i.filename, "date": i.date, "edited": i.edited,
                "thumb": src_thumbs.get(i.uuid),
                "dest": pair[0] if pair else None, "how": pair[1] if pair else None,
                "dest_thumb": dst_thumbs.get(pair[0]) if pair else None}

    return {"source": str(src), "dest": str(dst), "source_name": src.stem,
            "dest_name": dst.stem, "total": r.total, "all_verified": all_verified(r),
            "source_is_system": system == src, "dest_is_system": system == dst,
            "matched": [row(i) for i in r.matched],
            "edit_lost": [row(i) for i in r.edit_lost],
            "missing": [row(i) for i in r.missing]}


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(
        prog="photos-dedupe",
        description="After importing one Photos library into another, find which photos are "
                    "safe to delete from the source. Read-only unless an action flag is given.")
    ap.add_argument("source", type=Path, help="library you imported FROM")
    ap.add_argument("dest", type=Path, help="library you imported INTO")
    act = ap.add_mutually_exclusive_group()
    act.add_argument("--mark", action="store_true",
                     help="open SOURCE in Photos and put the verified photos in an album")
    act.add_argument("--delete", action="store_true",
                     help="delete the verified photos from SOURCE via PhotoKit (SOURCE must be "
                          "the System Photo Library; macOS asks to confirm)")
    act.add_argument("--trash-library", action="store_true",
                     help="move the whole SOURCE library to the Trash (only if every photo "
                          "is verified in DEST)")
    ap.add_argument("--album", default=None, help="album name (default: 'In <dest> – safe to delete')")
    ap.add_argument("--yes", action="store_true", help="don't ask for confirmation in the terminal")
    ap.add_argument("--json", action="store_true",
                    help="machine-readable output on stdout (for the Mac app); actions need --yes")
    args = ap.parse_args(argv)
    logging.getLogger("osxphotos").setLevel(logging.ERROR)
    acting = args.mark or args.delete or args.trash_library

    def fail(msg: str):
        if args.json:
            print(json.dumps({"error": msg}), flush=True)
            sys.exit(1)
        sys.exit(f"Error: {msg}")

    say = (lambda *a: print(*a, file=sys.stderr, flush=True)) if args.json else \
        (lambda *a: print(*a, flush=True))

    src, dst = args.source.expanduser().resolve(), args.dest.expanduser().resolve()
    for p in (src, dst):
        if p.suffix != ".photoslibrary" or not (p / "database" / "Photos.sqlite").exists():
            fail(f"not a Photos library: {p}")
    if src == dst:
        fail("source and destination are the same library.")
    if args.json and acting and not args.yes:
        fail("--json with an action needs --yes (confirm in the app first).")

    say("Reading both libraries… (a minute for big ones on an HDD)")
    try:
        r = match(load(src), load(dst))
    except Exception as e:  # noqa: BLE001
        fail(f"couldn’t read the libraries: {e}")
    if not args.json:
        say(report(r, src, dst))

    ask = (lambda q: True) if args.yes else _confirm
    outcome = None
    try:
        if args.trash_library:
            if not ask(f"\nMove the whole library “{src.stem}” to the Trash?"):
                sys.exit("Cancelled.")
            outcome = f"“{src.stem}” was moved to the Trash ({trash_library(src, r)})."
        elif args.delete:
            if not r.matched:
                raise CleanupError("Nothing verified, so nothing to delete.")
            if not ask(f"\nDelete {len(r.matched):,} verified photos from “{src.stem}”? "
                       "(macOS will ask too; they go to Recently Deleted for 30 days)"):
                sys.exit("Cancelled.")
            n = delete_with_photokit(src, r.matched, wait=_wait_with_runloop)
            outcome = (f"Deleted {n:,} photos from “{src.stem}”. They’re in Recently Deleted "
                       "for 30 days.")
        elif args.mark:
            if not r.matched:
                raise CleanupError("Nothing verified, so nothing to mark.")
            if not ask(f"\nPhotos will quit and reopen with “{src.stem}”, then an album with "
                       f"{len(r.matched):,} photos is created there. Continue?"):
                sys.exit("Cancelled.")
            album = args.album or f"In {dst.stem} – safe to delete"
            added = mark(src, r.matched, album)
            outcome = (f"Added {added:,} photos to the album “{album}”, now shown in Photos. "
                       "Review it, then ⌘A (select all), ⌘⌫ (delete) and confirm. They stay "
                       "in Recently Deleted for 30 days.")
    except (CleanupError, RuntimeError) as e:
        fail(str(e))

    if args.json:
        out = to_json(r, src, dst)
        out["outcome"] = outcome
        print(json.dumps(out), flush=True)
    elif outcome:
        say(outcome)
