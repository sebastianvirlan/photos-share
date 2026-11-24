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
import time
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
    path: str | None = None     # original file on disk (None if Photos says it's missing)
    live: str | None = None     # video half of a Live Photo
    raw: str | None = None      # RAW file of a RAW+JPEG pair

    @classmethod
    def from_photo(cls, p) -> "Item":
        return cls(uuid=p.uuid, fingerprint=p.fingerprint,
                   filename=(p.original_filename or "").lower() or None,
                   size=p.original_filesize or None,
                   date=p.date.replace(microsecond=0).isoformat() if p.date else "",
                   edited=bool(p.hasadjustments), hidden=bool(p.hidden),
                   path=p.path, live=p.path_live_photo if p.live_photo else None,
                   raw=p.path_raw if p.has_raw else None)

    @property
    def fallback_key(self):
        # The moment, not its text: the same instant can be stored with different time zones.
        if self.filename and self.size:
            return (self.filename, self.size, _instant(self.date))
        return None


def _instant(date: str):
    from datetime import datetime
    try:
        return int(datetime.fromisoformat(date).timestamp())
    except ValueError:
        return date


@dataclass
class Result:
    matched: list[Item] = field(default_factory=list)            # safe to delete from source
    matched_by_fallback: int = 0                                 # of `matched`, not by fingerprint
    edit_lost: list[Item] = field(default_factory=list)          # in DEST, but without the edit
    missing: list[Item] = field(default_factory=list)            # not in DEST at all
    pairs: dict[str, tuple[str, str]] = field(default_factory=dict)  # src uuid → (dest uuid, how)
    needs_review: list[Item] = field(default_factory=list)       # matched, but a file check failed
    reasons: dict[str, str] = field(default_factory=dict)        # src uuid → why it needs a look

    @property
    def total(self) -> int:
        return (len(self.matched) + len(self.edit_lost) + len(self.missing)
                + len(self.needs_review))


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


def _size(path: str | None) -> int | None:
    try:
        return os.stat(path).st_size if path else None
    except OSError:
        return None


def _sha256(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_pair(s: Item, d: Item, how: str) -> str | None:
    """File-level checks for a matched pair. Returns why it needs a look, or None if fine."""
    d_size = _size(d.path)
    if d_size is None:
        return "The original file is missing from the destination library."
    s_size = _size(s.path) or s.size
    if s_size and d_size != s_size:
        return f"The destination file is a different size ({d_size:,} vs {s_size:,} bytes)."
    if _size(s.live) is not None and _size(d.live) is None:
        return "The Live Photo’s video is missing from the destination."
    if _size(s.raw) is not None and _size(d.raw) is None:
        return "The RAW file of this RAW+JPEG pair is missing from the destination."
    if how != "fingerprint":
        if _size(s.path) is None:
            return "Matched by name, size and date, but the source file can’t be read to confirm."
        if _sha256(s.path) != _sha256(d.path):
            return "Same name, size and date, but the file contents differ."
    return None


class Progress:
    """Calls `report(phase, done, total, library)` at most a few times a second."""

    def __init__(self, report=None, every: float = 0.25):
        self.report, self.every, self.last = report, every, 0.0

    def __call__(self, phase: str, done: int = 0, total: int = 0, library: str = "",
                 force: bool = False) -> None:
        now = time.monotonic()
        if self.report and (force or done == total or now - self.last >= self.every):
            self.last = now
            self.report(phase, done, total, library)


def verify(r: Result, source: list[Item], dest: list[Item], progress=None) -> Result:
    """Move matched photos whose files don't check out into `needs_review`."""
    progress = progress or Progress()
    by_dest = {d.uuid: d for d in dest}
    keep = []
    n = len(r.matched)
    progress("checking", 0, n, force=True)
    for i, s in enumerate(r.matched):
        progress("checking", i, n)
        d_uuid, how = r.pairs[s.uuid]
        reason = check_pair(s, by_dest[d_uuid], how)
        if reason:
            r.needs_review.append(s)
            r.reasons[s.uuid] = reason
            r.matched_by_fallback -= how != "fingerprint"
        else:
            keep.append(s)
    r.matched = keep
    progress("checking", n, n, force=True)
    return r


def compare(src: Path, dst: Path, progress=None) -> Result:
    """Read both libraries, match, then check the files of every match."""
    progress = progress or Progress()
    s_items, d_items = load(src, progress), load(dst, progress)
    progress("matching", force=True)
    return verify(match(s_items, d_items), s_items, d_items, progress)


def load(path: Path, progress=None) -> list[Item]:
    import osxphotos
    progress = progress or Progress()
    progress("opening", library=path.stem, force=True)
    db = osxphotos.PhotosDB(dbfile=str(path), _skip_searchinfo=True)
    photos = db.photos()  # excludes Recently Deleted
    out = []
    for i, p in enumerate(photos):
        progress("reading", i, len(photos), path.stem)
        out.append(Item.from_photo(p))
    progress("reading", len(photos), len(photos), path.stem, force=True)
    return out


def report(r: Result, src: Path, dst: Path) -> str:
    lines = [
        f"Source:      {src.stem}  ({r.total:,} items)",
        f"Destination: {dst.stem}",
        "",
        f"  ✓ In destination:            {len(r.matched):,}"
        + (f"  ({r.matched_by_fallback:,} matched by filename+size+date)"
           if r.matched_by_fallback else ""),
        f"  ! In destination, edit lost: {len(r.edit_lost):,}  (kept out of the delete album)",
        f"  ? Needs a look:              {len(r.needs_review):,}  (a file check failed; kept)",
        f"  ✗ Not in destination:        {len(r.missing):,}",
    ]
    if r.needs_review:
        lines += ["", "Needs a look (first few):"]
        lines += [f"  {i.filename or i.uuid}: {r.reasons[i.uuid]}" for i in r.needs_review[:SAMPLE]]
    if r.missing:
        lines += ["", "Not imported (first few):"]
        lines += [f"  {i.filename or i.uuid}  {i.date[:10]}" for i in r.missing[:SAMPLE]]
    lines.append("")
    if all_verified(r):
        lines.append(f"Everything in “{src.stem}” is in “{dst.stem}”. After a final look, the "
                     "whole source library can go to the Trash (--trash-library).")
    elif r.matched:
        lines.append(f"Run again with --delete (if the source is the System Photo Library) or "
                     f"--mark to clean up the {len(r.matched):,} verified photos.")
    return "\n".join(lines)


AUTOMATION_HELP = ("macOS didn’t allow controlling Photos. Open System Settings → Privacy & "
                   "Security → Automation, find Photos Share (or your Terminal), and turn on "
                   "Photos. Then try again.")


def _not_permitted(e: Exception) -> bool:
    text = str(e)
    return "-1743" in text or "Not authorized to send Apple events" in text


def mark(src: Path, items: list[Item], album_name: str, wait: float = 180) -> int:
    """Open SOURCE in Photos and put `items` into a new album there. Returns count added.

    Waits (up to `wait` seconds) for Photos to finish loading the library, since a big
    library on an HDD takes a while, and reports a missing Automation permission clearly.
    """
    import time

    import photoscript

    lib = photoscript.PhotosLibrary()
    lib.open(str(src))  # quits Photos and reopens it with SOURCE (shell command, no permission)
    deadline = time.monotonic() + wait
    while True:
        try:
            photoscript.Photo(items[0].uuid)   # first Apple Event: needs Automation permission
            break
        except Exception as e:  # noqa: BLE001
            if _not_permitted(e):
                raise RuntimeError(AUTOMATION_HELP) from e
            if time.monotonic() > deadline:
                raise RuntimeError(
                    f"Photos didn’t finish opening “{src.stem}” within {int(wait)} seconds, or "
                    f"it opened a different library. ({e})") from e
            time.sleep(3)
    try:
        name, n = album_name, 2
        while name in lib.album_names():
            name, n = f"{album_name} ({n})", n + 1
        album = lib.create_album(name)
        added = 0
        for i in range(0, len(items), BATCH):
            added += len(album.add([photoscript.Photo(it.uuid) for it in items[i:i + BATCH]]))
        album.spotlight()
    except Exception as e:  # noqa: BLE001
        if _not_permitted(e):
            raise RuntimeError(AUTOMATION_HELP) from e
        raise RuntimeError(f"Photos couldn’t create or fill the album: {e}") from e
    if added != len(items):
        raise RuntimeError(f"Only {added} of {len(items)} photos were added to “{name}”. Check "
                           "the album before deleting anything.")
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
    return r.total > 0 and not r.missing and not r.edit_lost and not r.needs_review


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
                "dest_thumb": dst_thumbs.get(pair[0]) if pair else None,
                "reason": r.reasons.get(i.uuid)}

    return {"source": str(src), "dest": str(dst), "source_name": src.stem,
            "dest_name": dst.stem, "total": r.total, "all_verified": all_verified(r),
            "source_is_system": system == src, "dest_is_system": system == dst,
            "matched": [row(i) for i in r.matched],
            "edit_lost": [row(i) for i in r.edit_lost],
            "missing": [row(i) for i in r.missing],
            "needs_review": [row(i) for i in r.needs_review]}


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
    ap.add_argument("--progress", action="store_true",
                    help="with --json: progress lines ({\"event\": \"progress\", ...}) before the result")
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

    def show(phase, done, total, library):
        if args.json and args.progress:
            print(json.dumps({"event": "progress", "phase": phase, "done": done,
                              "total": total, "library": library}), flush=True)
        elif not args.json:
            text = {"opening": f"Opening “{library}”…", "matching": "Matching…",
                    "reading": f"Reading “{library}”… {done:,}/{total:,}",
                    "checking": f"Checking files… {done:,}/{total:,}",
                    "thumbnails": "Finding previews…"}.get(phase, phase)
            print(f"\r\033[K{text}", end="" if phase in ("reading", "checking") else "\n",
                  file=sys.stderr, flush=True)

    progress = Progress(show, every=0.25 if args.json else 0.1)
    try:
        r = compare(src, dst, progress=progress)
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
        progress("thumbnails", force=True)
        out = to_json(r, src, dst)
        out["outcome"] = outcome
        print(json.dumps(out), flush=True)
    elif outcome:
        say(outcome)
