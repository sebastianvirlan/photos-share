"""photos-dedupe: after File → Import from another library, find what's safe to delete.

Read-only by default: reports which photos of SOURCE are already in DEST. With --mark, it
opens SOURCE in Photos and collects exactly the verified photos in an album, so you can
review them and delete with ⌘A, ⌘⌫. It never deletes anything itself (Photos doesn't allow
scripted deletion of photos, and that's a decision worth making by eye anyway).
"""

from __future__ import annotations

import argparse
import logging
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
        elif s.edited and not any(d.edited for d in hits):
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
                     "whole source library can go to the Trash.")
    elif r.matched:
        lines.append(f"Run again with --mark to collect the {len(r.matched):,} verified photos "
                     "in an album in the source library, ready to delete.")
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


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(
        prog="photos-dedupe",
        description="After importing one Photos library into another, find which photos are "
                    "safe to delete from the source. Read-only unless --mark is given.")
    ap.add_argument("source", type=Path, help="library you imported FROM")
    ap.add_argument("dest", type=Path, help="library you imported INTO")
    ap.add_argument("--mark", action="store_true",
                    help="open SOURCE in Photos and put the verified photos in an album")
    ap.add_argument("--album", default=None, help="album name (default: 'In <dest> – safe to delete')")
    ap.add_argument("--yes", action="store_true", help="don't ask before switching Photos' library")
    args = ap.parse_args(argv)
    logging.getLogger("osxphotos").setLevel(logging.ERROR)

    src, dst = args.source.expanduser().resolve(), args.dest.expanduser().resolve()
    for p in (src, dst):
        if p.suffix != ".photoslibrary" or not (p / "database" / "Photos.sqlite").exists():
            sys.exit(f"Error: not a Photos library: {p}")
    if src == dst:
        sys.exit("Error: source and destination are the same library.")

    print("Reading both libraries… (a minute for big ones on an HDD)", flush=True)
    r = match(load(src), load(dst))
    print(report(r, src, dst))

    if not args.mark:
        return
    if not r.matched:
        sys.exit("Nothing verified, so nothing to mark.")
    if not args.yes:
        answer = input(f"\nPhotos will quit and reopen with “{src.stem}”, then an album with "
                       f"{len(r.matched):,} photos is created there. Continue? [y/N] ")
        if answer.strip().lower() not in ("y", "yes"):
            sys.exit("Cancelled.")
    name = args.album or f"In {dst.stem} – safe to delete"
    try:
        added = mark(src, r.matched, name)
    except RuntimeError as e:
        sys.exit(f"Error: {e}")
    print(f"\nAdded {added:,} photos to the album shown in Photos.\n"
          "Review it, then: ⌘A (select all) → ⌘⌫ (delete from library) → confirm.\n"
          "They stay in Recently Deleted for 30 days if you change your mind.")
