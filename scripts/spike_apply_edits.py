"""Spike, step 2: put the edits back onto photos imported by spike_import_edits.py.

For each edited photo in SOURCE, collects Photos' edit recipe (what the .AAE holds) and the
edited image Photos rendered, then has the Mac app save both as an edit on the matching
imported original in the System Photo Library (via PhotoKit, the only way apps can edit).

Make the TEST library the System Photo Library first (Photos → Settings → General).

  uv run python scripts/spike_apply_edits.py SOURCE              same 3 photos as step 1
  uv run python scripts/spike_apply_edits.py SOURCE --names IMG_1.HEIC,IMG_2.JPG
  uv run python scripts/spike_apply_edits.py SOURCE --album "Edit test"
  uv run python scripts/spike_apply_edits.py SOURCE --names … --create
        make NEW photos from original + recipe + edited image (no import needed first)
"""

import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

import osxphotos
from osxphotos.utils import get_system_library_path

from spike_import_edits import is_real_edit

APPS = [Path("/Applications/Photos Share.app"), Path.home() / "Applications/Photos Share.app"]


REPO = Path(__file__).resolve().parent.parent


def _built(a: Path) -> float:
    return (a / "Contents/MacOS/PhotosShare").stat().st_mtime


def newest_app() -> Path:
    """The newest built app, rebuilt first if the Swift code changed since (e.g. after a pull)."""
    found = [a for a in APPS if a.exists()]
    newest_source = max(f.stat().st_mtime for f in (REPO / "mac").rglob("*.swift")
                        if ".build" not in f.parts)
    if not found or max(map(_built, found)) < newest_source:
        print("The Mac app is older than its code: rebuilding it (takes a minute)…")
        subprocess.run([str(REPO / "scripts/build-app.sh")], check=True,
                       env={**os.environ, "NO_REVEAL": "1"})
        found = [a for a in APPS if a.exists()]
    return max(found, key=_built)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source", type=Path)
    ap.add_argument("-n", type=int, default=3)
    ap.add_argument("--names")
    ap.add_argument("--album")
    ap.add_argument("--app", type=Path, default=None)
    ap.add_argument("--create", action="store_true",
                    help="create NEW photos from original + edit recipe + edited image, instead "
                         "of editing already-imported ones")
    args = ap.parse_args()

    src = args.source.resolve()
    system = Path(get_system_library_path() or "")
    if system == src:
        sys.exit("SOURCE is the System Photo Library; make the test library the system one first.")
    photos = [p for p in osxphotos.PhotosDB(dbfile=str(src)).photos()
              if p.hasadjustments and not p.ismovie and p.path]
    if args.names:
        wanted = {n.strip().lower() for n in args.names.split(",")}
        chosen = [p for p in photos if (p.original_filename or "").lower() in wanted]
    elif args.album:
        chosen = [p for p in photos if args.album in p.albums]
    else:
        chosen = sorted([p for p in photos if is_real_edit(p)], key=lambda p: p.portrait)[: args.n]
    if not chosen:
        sys.exit("No matching edited photos.")

    staging = Path(tempfile.mkdtemp(prefix="edit-spike-"))
    entries = []
    for p in chosen:
        plist = p.adjustments.plist if p.adjustments else {}
        if not plist.get("adjustmentData") or not p.path_edited:
            why = [w for w, bad in (("no edit recipe", not plist.get("adjustmentData")),
                                    ("Photos hasn’t saved an edited image for it", not p.path_edited))
                   if bad]
            print(f"- {p.original_filename}: skipped ({'; '.join(why)} in SOURCE)")
            continue
        entries.append({"name": p.original_filename, "date": p.date.timestamp(),
                        "format_id": plist.get("adjustmentFormatIdentifier", "com.apple.photo"),
                        "format_version": str(plist.get("adjustmentFormatVersion", "1.0")),
                        "data": base64.b64encode(plist["adjustmentData"]).decode(),
                        "rendered": p.path_edited})
        if args.create:
            aae = staging / f"{Path(p.original_filename).stem}.AAE"
            aae.write_bytes(plistlib.dumps(plist))
            entries[-1].update(original=p.path, aae=str(aae))
        print(f"- {p.original_filename}: {plist.get('adjustmentFormatIdentifier')} "
              f"{plist.get('adjustmentFormatVersion')}, {len(plist['adjustmentData'])} bytes")
    if not entries:
        sys.exit("Nothing to apply.")

    what = ("adds NEW photos (in a new album)" if args.create
            else "edits matching photos (replacing any edit they have)")
    print(f"\nThis {what} in the System Photo Library: “{system.stem}”.")
    if input("Is that your TEST library? Continue? [y/N] ").strip().lower() != "y":
        sys.exit("Cancelled.")

    manifest = staging / "manifest.json"
    manifest.write_text(json.dumps(entries))
    log = manifest.with_suffix(".json.log")
    app = args.app or newest_app()
    built = datetime.fromtimestamp(_built(app))
    print(f"Using {app} (built {built:%Y-%m-%d %H:%M})")
    print("Running Photos Share. It comes to the front: allow Photos access, and allow the edits "
          "if macOS asks (check behind other windows too).\n")
    proc = subprocess.Popen(["open", "-n", "-W", "-a", str(app), "--args", "--apply-edits",
                             str(manifest)])
    shown = 0
    while True:
        finished = proc.poll() is not None
        lines = log.read_text().splitlines() if log.exists() else []
        for line in lines[shown:]:
            if line != "DONE":
                print(line, flush=True)
        shown = len(lines)
        if finished or "DONE" in lines:
            break
        time.sleep(0.5)
    if not lines:
        print(f"The app didn’t start the spike (no log at {log}). Is {app} the new build?")

if __name__ == "__main__":
    main()
