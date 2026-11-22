"""Spike: do edits survive if we import original + .AAE into another library?

Takes a few EDITED photos from SOURCE, exports each original plus its edit recipe (.AAE)
with osxphotos, imports them into DEST through Photos, then checks whether Photos applied
the recipe (the imported photo has an edit).

DEST gets new photos added, so use a throwaway test library for it.

  uv run python scripts/spike_import_edits.py SOURCE --list
        show edited photos and what each edit contains (nothing is imported)
  uv run python scripts/spike_import_edits.py SOURCE DEST [-n 3]
        pick real edits automatically (portrait depth effect alone doesn't count)
  uv run python scripts/spike_import_edits.py SOURCE DEST --names IMG_1.HEIC,IMG_2.JPG
  uv run python scripts/spike_import_edits.py SOURCE DEST --album "Edit test"
"""

import argparse
import sys
import tempfile
import time
from pathlib import Path

import osxphotos

# Stored as "edits" by the camera/Photos itself, not by you.
AUTOMATIC = ("depth", "portrait", "semantic", "orientation", "rawnoise", "smartstyle")


def operations(p) -> list[str]:
    adj = p.adjustments
    ops = [a.get("identifier", "?") for a in (adj.adjustments if adj else [])
           if isinstance(a, dict)]
    return ops or ([f"(undecoded: {p.adjustment_type or 'unknown'})"] if p.hasadjustments else [])


def is_real_edit(p) -> bool:
    ops = operations(p)
    return any(not any(k in op.lower() for k in AUTOMATIC) for op in ops)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source", type=Path)
    ap.add_argument("dest", type=Path, nargs="?")
    ap.add_argument("--list", action="store_true", help="list edited photos and their edits")
    ap.add_argument("-n", type=int, default=3, help="how many photos to test (default 3)")
    ap.add_argument("--names", help="comma-separated original filenames to test")
    ap.add_argument("--album", help="test the edited photos in this album")
    args = ap.parse_args()
    src = args.source.resolve()
    photos = [p for p in osxphotos.PhotosDB(dbfile=str(src)).photos()
              if p.hasadjustments and not p.ismovie and p.path]

    if args.list:
        for p in sorted(photos, key=lambda p: p.date, reverse=True):
            tag = "real edit" if is_real_edit(p) else "automatic only"
            print(f"{p.original_filename:28} {p.date:%Y-%m-%d}  {tag:15} {', '.join(operations(p))}")
        print(f"\n{len(photos)} edited photos, {sum(map(is_real_edit, photos))} with real edits.")
        return
    if not args.dest:
        sys.exit("Give a DEST library, or use --list.")

    if args.names:
        wanted = {n.strip().lower() for n in args.names.split(",")}
        chosen = [p for p in photos if (p.original_filename or "").lower() in wanted]
        missing = wanted - {(p.original_filename or "").lower() for p in chosen}
        if missing:
            print(f"Not found among edited photos: {', '.join(sorted(missing))}")
    elif args.album:
        chosen = [p for p in photos if args.album in p.albums]
    else:
        real = [p for p in photos if is_real_edit(p)]
        chosen = sorted(real, key=lambda p: p.portrait)[: args.n]  # non-portrait first
    if not chosen:
        sys.exit("No matching edited photos. Try --list to see what's there.")

    dst = args.dest.resolve()
    from osxphotos.utils import get_system_library_path
    if str(dst) == get_system_library_path():
        sys.exit("Refusing: DEST is your System Photo Library. Use a throwaway test library.")
    if input(f"This adds {len(chosen)} photos to “{dst.stem}”. Continue? [y/N] ").lower() != "y":
        sys.exit("Cancelled.")

    import photoscript
    from osxphotos.photoexporter import ExportOptions, PhotoExporter

    tmp = Path(tempfile.mkdtemp(prefix="aae-spike-"))
    batch = []
    for p in chosen:
        res = PhotoExporter(p).export(str(tmp), options=ExportOptions(export_aae=True))
        files = [Path(f) for f in res.exported]
        has_aae = any(f.suffix.lower() == ".aae" for f in files)
        print(f"- {p.original_filename}: edits [{', '.join(operations(p))}] → exported "
              f"{[f.name for f in files]}{'' if has_aae else '  (no .AAE produced!)'}")
        batch += [str(f) for f in files]

    print(f"\nOpening “{dst.stem}” in Photos and importing {len(batch)} files…")
    lib = photoscript.PhotosLibrary()
    lib.open(str(dst))
    time.sleep(5)
    album = lib.create_album(f"AAE spike {time.strftime('%H:%M:%S')}")
    imported = lib.import_photos(batch, album=album, skip_duplicate_check=True)
    print(f"Photos imported {len(imported)} items into album “{album.name}”. Waiting for Photos "
          "to save…")
    time.sleep(10)

    db = osxphotos.PhotosDB(dbfile=str(dst))
    ok = 0
    for ph in imported:
        info = db.get_photo(ph.uuid)
        has = bool(info and info.hasadjustments)
        ok += has
        print(f"  {ph.filename}: {'EDIT KEPT' if has else 'no edit'}"
              + (f" [{', '.join(operations(info))}]" if info and has else ""))
    print(f"\nResult: {ok}/{len(imported)} imported photos have the edit applied.")
    print("Check in Photos: the photos should look edited, and Image → Revert to Original "
          "should be available if the edit stayed editable.")


if __name__ == "__main__":
    main()
