"""photos-import: copy photos from one Photos library into another, through Photos.

Only Photos can add photos to a library safely, so the actual adding uses Photos' own
scripting `import`. Everything around it is ours: a fast selection (`--plan`), skipping
what's already in the destination, batching, and carrying the details across.

  photos-import SRC DST --plan [--hidden] --json      what could be imported
  photos-import SRC DST --uuids-file F [--edited skip|flatten|both] [--json] [--yes]

Edits made in Photos can't come across editable (Photos ignores .AAE recipes on import, and
importing them breaks previews), so edited photos are skipped by default and listed, to be
brought across with Photos' own import. `flatten` imports how they look now instead.
"""

from __future__ import annotations

import argparse
import json
import logging
import shutil
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from . import dedupe

BATCH = 50
EDITED_MODES = ("skip", "flatten", "both")
# Adjustments the camera/Photos stores by itself; a photo with only these isn't "edited".
AUTOMATIC = ("depth", "portrait", "semantic", "orientation", "rawnoise", "smartstyle")


def has_real_edit(p) -> bool:
    if not p.hasadjustments:
        return False
    adj = p.adjustments
    ops = [a.get("identifier", "") for a in (adj.adjustments if adj else []) if isinstance(a, dict)]
    if not ops:
        return True  # couldn't decode the edit: treat it as real, to be safe
    return any(not any(k in op.lower() for k in AUTOMATIC) for op in ops)


@dataclass
class Candidate:
    uuid: str
    name: str | None
    date: str
    thumb: str | None
    movie: bool
    live: bool
    favorite: bool
    edited: bool
    hidden: bool
    albums: list[str]
    in_dest: bool = False


@dataclass
class Plan:
    source: Path
    dest: Path
    items: list[Candidate] = field(default_factory=list)

    def to_json(self) -> dict:
        albums = sorted({a for c in self.items for a in c.albums}, key=str.lower)
        return {"source": str(self.source), "dest": str(self.dest),
                "source_name": self.source.stem, "dest_name": self.dest.stem,
                "albums": albums, "items": [c.__dict__ for c in self.items]}


def _photos(path: Path):
    import osxphotos
    return osxphotos.PhotosDB(dbfile=str(path), _skip_searchinfo=True).photos()


def plan(src: Path, dst: Path, include_hidden: bool = False) -> Plan:
    """Everything in SRC that could be imported, marking what DST already has."""
    src_photos = [p for p in _photos(src) if include_hidden or not p.hidden]
    in_dest = dedupe.match([dedupe.Item.from_photo(p) for p in src_photos],
                           [dedupe.Item.from_photo(p) for p in _photos(dst)]).pairs
    thumbs = dedupe.thumbnail_map(src)
    out = Plan(src, dst)
    for p in sorted(src_photos, key=lambda p: p.date, reverse=True):
        out.items.append(Candidate(
            uuid=p.uuid, name=p.original_filename,
            date=p.date.replace(microsecond=0).isoformat() if p.date else "",
            thumb=thumbs.get(p.uuid), movie=bool(p.ismovie), live=bool(p.live_photo),
            favorite=bool(p.favorite), edited=has_real_edit(p), hidden=bool(p.hidden),
            albums=[a for a in p.albums if a], in_dest=p.uuid in in_dest))
    return out


# ---- importing -------------------------------------------------------------------------

@dataclass
class Staged:
    """Files exported for one source photo, ready for Photos to import."""
    photo: object                 # osxphotos PhotoInfo
    files: list[Path]


def export_photo(p, folder: Path, edited_mode: str) -> list[Path]:
    """Export what should be imported for `p` (never .AAE files)."""
    from osxphotos.photoexporter import ExportOptions, PhotoExporter

    want_edited = has_real_edit(p) and edited_mode in ("flatten", "both")
    want_original = not has_real_edit(p) or edited_mode == "both"
    files: list[Path] = []
    for edited in ([False] if want_original else []) + ([True] if want_edited else []):
        opts = ExportOptions(edited=edited, live_photo=True, raw_photo=True, export_aae=False)
        files += [Path(f) for f in PhotoExporter(p).export(str(folder), options=opts).exported]
    return [f for f in files if f.suffix.lower() != ".aae"]


def batches(photos: list, size: int = BATCH) -> list[list]:
    """Groups of photos whose original filenames are unique within the group, so each
    imported item can be matched back to its source photo by filename."""
    out, current, names = [], [], set()
    for p in photos:
        name = (p.original_filename or p.uuid).lower()
        if len(current) >= size or name in names:
            out.append(current)
            current, names = [], set()
        current.append(p)
        names.add(name)
    if current:
        out.append(current)
    return out


def apply_details(imported, src, albums_cache: dict, lib) -> None:
    """Carry favourite, title, caption, keywords, location, date and albums across."""
    if src.favorite and not imported.favorite:
        imported.favorite = True
    if src.title and imported.title != src.title:
        imported.title = src.title
    if src.description and imported.description != src.description:
        imported.description = src.description
    if src.keywords and sorted(imported.keywords or []) != sorted(src.keywords):
        imported.keywords = list(src.keywords)
    lat, lon = src.location if src.location else (None, None)
    if lat is not None and lon is not None and (lat or lon):
        cur = imported.location or (None, None)
        if cur[0] is None or abs(cur[0] - lat) > 1e-5 or abs(cur[1] - lon) > 1e-5:
            imported.location = (lat, lon)
    if src.date:
        want = src.date.astimezone().replace(tzinfo=None)
        have = imported.date
        if have is None or abs((have - want).total_seconds()) > 1:
            imported.date = want
    for title in src.albums or []:
        if title not in albums_cache:
            albums_cache[title] = lib.album(title) or lib.create_album(title)  # reuse, even in folders
        albums_cache[title].add([imported])


def run_import(src: Path, dst: Path, uuids: list[str], edited_mode: str = "skip",
               emit=lambda *a, **k: None) -> dict:
    import photoscript

    wanted = set(uuids)
    photos = [p for p in _photos(src) if p.uuid in wanted]
    skipped = [p for p in photos if has_real_edit(p) and edited_mode == "skip"]
    todo = [p for p in photos if p not in skipped]
    total = len(todo)
    emit("start", total=total, skipped_edited=len(skipped))

    emit("progress", phase="opening", done=0, total=total)
    lib = photoscript.PhotosLibrary()
    if total:
        lib.open(str(dst))
        _wait_for_library(dst)

    staging = Path(tempfile.mkdtemp(prefix="photos-import-"))
    done, failed, imported_count, albums_cache = 0, [], 0, {}
    try:
        for group in batches(todo):
            folder = staging / f"batch-{done}"
            folder.mkdir()
            by_name: dict[str, object] = {}
            paths: list[str] = []
            for p in group:
                try:
                    files = export_photo(p, folder, edited_mode)
                except Exception as e:  # noqa: BLE001
                    failed.append({"uuid": p.uuid, "name": p.original_filename,
                                   "reason": f"couldn’t export: {e}"})
                    continue
                if not files:
                    failed.append({"uuid": p.uuid, "name": p.original_filename,
                                   "reason": "the original file is missing"})
                    continue
                for f in files:
                    by_name[f.name.lower()] = p
                paths += [str(f) for f in files]
            emit("progress", phase="importing", done=done, total=total)
            if paths:
                result = lib.import_photos(paths, skip_duplicate_check=True)
                for item in result:
                    p = by_name.get((item.filename or "").lower())
                    imported_count += 1
                    if p is None:
                        continue
                    try:
                        apply_details(item, p, albums_cache, lib)
                    except Exception as e:  # noqa: BLE001
                        failed.append({"uuid": p.uuid, "name": p.original_filename,
                                       "reason": f"imported, but details weren’t set: {e}"})
            shutil.rmtree(folder, ignore_errors=True)
            done += len(group)
            emit("progress", phase="importing", done=done, total=total)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    summary = {"imported": imported_count, "requested": total, "failed": failed,
               "skipped_edited": [{"uuid": p.uuid, "name": p.original_filename}
                                  for p in skipped]}
    emit("done", **summary)
    return summary


def _wait_for_library(dst: Path, wait: float = 180) -> None:
    """After switching libraries, wait until Photos answers scripting, with a clear error
    if macOS blocks it (same rules as Clean Up's Mark in Photos)."""
    import time

    import photoscript
    deadline = time.monotonic() + wait
    while True:
        try:
            photoscript.PhotosLibrary().album_names()
            return
        except Exception as e:  # noqa: BLE001
            if dedupe._not_permitted(e):
                raise RuntimeError(dedupe.AUTOMATION_HELP) from e
            if time.monotonic() > deadline:
                raise RuntimeError(f"Photos didn’t finish opening “{dst.stem}”. ({e})") from e
            time.sleep(3)


# ---- command line ----------------------------------------------------------------------

def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="photos-import", description=__doc__.split("\n")[0])
    ap.add_argument("source", type=Path, help="library to import FROM")
    ap.add_argument("dest", type=Path, help="library to import INTO")
    ap.add_argument("--plan", action="store_true", help="list what could be imported")
    ap.add_argument("--hidden", action="store_true", help="include hidden photos in the plan")
    ap.add_argument("--uuids-file", type=Path, help="file with one source photo id per line")
    ap.add_argument("--edited", choices=EDITED_MODES, default="skip",
                    help="edited photos: skip (default), flatten (as they look now), or both")
    ap.add_argument("--json", action="store_true", help="JSON output for the Mac app")
    ap.add_argument("--yes", action="store_true", help="don't ask before switching Photos' library")
    args = ap.parse_args(argv)
    logging.getLogger("osxphotos").setLevel(logging.ERROR)

    def emit(event: str, **data) -> None:
        if args.json:
            print(json.dumps({"event": event, **data}), flush=True)
        elif event == "progress":
            print(f"\r{data['phase'].capitalize()}… {data['done']:,}/{data['total']:,}",
                  end="", flush=True)

    def fail(msg: str):
        if args.json:
            print(json.dumps({"event": "error", "message": msg}), flush=True)
            sys.exit(1)
        sys.exit(f"Error: {msg}")

    src, dst = args.source.expanduser().resolve(), args.dest.expanduser().resolve()
    for p in (src, dst):
        if p.suffix != ".photoslibrary" or not (p / "database" / "Photos.sqlite").exists():
            fail(f"not a Photos library: {p}")
    if src == dst:
        fail("source and destination are the same library.")

    if args.plan:
        try:
            result = plan(src, dst, include_hidden=args.hidden).to_json()
        except Exception as e:  # noqa: BLE001
            fail(f"couldn’t read the libraries: {e}")
        if args.json:
            print(json.dumps(result), flush=True)
        else:
            items = result["items"]
            new = [i for i in items if not i["in_dest"]]
            print(f"{len(items):,} in “{src.stem}”, {len(new):,} not yet in “{dst.stem}” "
                  f"({sum(i['edited'] for i in new):,} of those edited).")
        return

    if not args.uuids_file:
        fail("give --plan, or --uuids-file with the photos to import.")
    uuids = [u.strip() for u in args.uuids_file.read_text().splitlines() if u.strip()]
    if not args.json and not args.yes:
        if input(f"Photos will quit and reopen with “{dst.stem}” to import {len(uuids):,} "
                 "photos. Continue? [y/N] ").strip().lower() not in ("y", "yes"):
            sys.exit("Cancelled.")
    try:
        summary = run_import(src, dst, uuids, args.edited, emit)
    except KeyboardInterrupt:
        emit("cancelled")
        sys.exit(130)
    except Exception as e:  # noqa: BLE001
        fail(str(e))
    if not args.json:
        print(f"\nImported {summary['imported']:,} of {summary['requested']:,}. "
              f"Skipped {len(summary['skipped_edited']):,} edited, "
              f"{len(summary['failed']):,} problems.")
