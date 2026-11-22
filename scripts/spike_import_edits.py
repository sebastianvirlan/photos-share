"""Spike: do edits survive if we import original + .AAE into another library?

Takes a few EDITED photos from SOURCE, exports each original plus its edit recipe (.AAE)
with osxphotos, imports them into DEST through Photos, then checks whether Photos applied
the recipe (the imported photo has an edit).

DEST gets new photos added, so use a throwaway test library for it.
Run:  uv run python scripts/spike_import_edits.py SOURCE.photoslibrary DEST.photoslibrary [N]
"""

import sys
import tempfile
import time
from pathlib import Path

import osxphotos
import photoscript
from osxphotos.photoexporter import ExportOptions, PhotoExporter


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    from osxphotos.utils import get_system_library_path
    if str(dst) == get_system_library_path():
        sys.exit("Refusing: DEST is your System Photo Library. Use a throwaway test library.")
    if input(f"This adds up to {n} photos to “{dst.stem}”. Continue? [y/N] ").lower() != "y":
        sys.exit("Cancelled.")

    edited = [p for p in osxphotos.PhotosDB(dbfile=str(src)).photos()
              if p.hasadjustments and not p.ismovie and p.path][:n]
    if not edited:
        sys.exit("No edited photos found in SOURCE.")

    tmp = Path(tempfile.mkdtemp(prefix="aae-spike-"))
    batch = []
    for p in edited:
        res = PhotoExporter(p).export(str(tmp), options=ExportOptions(export_aae=True))
        files = [Path(f) for f in res.exported]
        aae = [f for f in files if f.suffix.lower() == ".aae"]
        print(f"- {p.original_filename}: edit type {p.adjustment_type!r}, exported "
              f"{[f.name for f in files]}{'' if aae else '  (no .AAE produced!)'}")
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
              + (f" ({info.adjustment_type})" if info and has else ""))
    print(f"\nResult: {ok}/{len(imported)} imported photos have the edit applied.")
    print("Open the album in Photos: an edited photo shows the edited look, and Edit → "
          "Revert to Original is available if the edit stayed editable.")


if __name__ == "__main__":
    main()
