"""Spike: import a varied sample of photos with their edits, then check the results.

Sorts SOURCE's photos into kinds (crops, complex edits, edited Live Photos, RAW+JPEG,
edited videos, slo-mo, portrait, other apps' edits, and unedited Live Photos, RAW, videos,
photos), picks a few of each, and has the Mac app create them in the System Photo Library
from all their parts at once (original, Live video, RAW, edit recipe, edited versions).
Then reads the System Photo Library back and checks every photo against its source, and
prints what to check by hand in Photos.

Make a TEST library the System Photo Library first (Photos → Settings → General).

  uv run python scripts/spike_create_import.py SOURCE --list          what's there, by kind
  uv run python scripts/spike_create_import.py SOURCE [-n 2]          import N of each kind
  uv run python scripts/spike_create_import.py SOURCE --kinds crop,edited-live -n 3
  uv run python scripts/spike_create_import.py SOURCE --names IMG_1.HEIC,IMG_2.MOV
"""

import argparse
import glob
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

import osxphotos
from osxphotos.utils import get_system_library_path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))
from photos_share.importer import AUTOMATIC  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from spike_apply_edits import _built, newest_app  # noqa: E402

KINDS = {  # kind: description (order = priority when a photo fits several)
    "other-app-edit": "edited by another app (not Photos)",
    "edited-live": "edited Live Photo",
    "edited-raw": "edited RAW+JPEG pair",
    "slo-mo": "slo-mo video",
    "edited-video": "edited video (trim etc.)",
    "portrait": "portrait (depth effect)",
    "crop": "cropped / straightened",
    "complex": "4+ adjustments",
    "edited": "other edits",
    "live": "Live Photo, unedited",
    "raw": "RAW+JPEG pair, unedited",
    "video": "video, unedited",
    "photo": "photo, unedited",
}


# ---- reading the source ----------------------------------------------------------------

def ops(p) -> list[str]:
    adj = p.adjustments
    return [a.get("identifier", "?") for a in (adj.adjustments if adj else []) if isinstance(a, dict)]


def real_ops(p) -> list[str]:
    return [o for o in ops(p) if not any(k in o.lower() for k in AUTOMATIC)]


def recipe_format(p) -> str | None:
    return (p.adjustments.plist or {}).get("adjustmentFormatIdentifier") if p.adjustments else None


def edited_image(p) -> str | None:
    """The edited image/video Photos saved. osxphotos guesses its name from the original's type,
    which misses e.g. a HEIC whose edit was saved as JPEG, so look for it as well."""
    if p.path_edited and os.path.exists(p.path_edited):
        return p.path_edited
    lib = Path(p._db.library_path)
    pattern = f"{p.uuid}_2_0_a.*" if p.ismovie else f"{p.uuid}_1_201_a.*"
    found = sorted(glob.glob(str(lib / "resources" / "renders" / p.uuid[0] / pattern)))
    return found[0] if found else None


def edited_live_video(p) -> str | None:
    if p.path_edited_live_photo and os.path.exists(p.path_edited_live_photo):
        return p.path_edited_live_photo
    lib = Path(p._db.library_path)
    found = sorted(glob.glob(str(lib / "resources" / "renders" / p.uuid[0] / f"{p.uuid}_2_*_a.mov")))
    return found[0] if found else None


def kind_of(p) -> str:
    edited = bool(p.hasadjustments)
    real = real_ops(p)
    fmt = recipe_format(p)
    if edited and (p.external_edit or (fmt and fmt != "com.apple.photo" and not p.ismovie)):
        return "other-app-edit"
    if p.ismovie:
        if p.slow_mo:
            return "slo-mo"
        return "edited-video" if edited else "video"
    if edited and p.live_photo and real:
        return "edited-live"
    if edited and p.has_raw and real:
        return "edited-raw"
    if p.portrait and edited:
        return "portrait"
    if real and any("crop" in o.lower() or "straighten" in o.lower() for o in real):
        return "crop"
    if len(real) >= 4:
        return "complex"
    if real:
        return "edited"
    if p.live_photo:
        return "live"
    if p.has_raw:
        return "raw"
    return "photo"


def problems(p) -> list[str]:
    """Why a photo can't be used for the test."""
    out = []
    if not p.path or not os.path.exists(p.path):
        out.append("original file not in the library")
    if p.hasadjustments:
        if not p.adjustments_path or not os.path.exists(p.adjustments_path):
            out.append("no edit recipe file")
        if not edited_image(p):
            out.append("no edited image saved")
    if p.live_photo and not (p.path_live_photo and os.path.exists(p.path_live_photo)):
        out.append("Live video missing")
    if p.has_raw and not (p.path_raw and os.path.exists(p.path_raw)):
        out.append("RAW file missing")
    return out


def resources(p) -> list[dict]:
    """The parts to create the photo from. The first one is the main original."""
    r = []
    if p.ismovie:
        r.append({"type": "video", "path": p.path})
    elif p.has_raw and p.path_raw:
        main, alt = (p.path_raw, p.path) if p.raw_original else (p.path, p.path_raw)
        r += [{"type": "photo", "path": main}, {"type": "alternatePhoto", "path": alt}]
    else:
        r.append({"type": "photo", "path": p.path})
    if p.live_photo and p.path_live_photo:
        r.append({"type": "pairedVideo", "path": p.path_live_photo})
    if p.hasadjustments:
        r.append({"type": "adjustmentData", "path": p.adjustments_path})
        r.append({"type": "fullSizeVideo" if p.ismovie else "fullSizePhoto", "path": edited_image(p)})
        if p.live_photo and (v := edited_live_video(p)):
            r.append({"type": "fullSizePairedVideo", "path": v, "optional": True})
    return [{**x, "path": str(x["path"])} for x in r]  # osxphotos gives some paths as Path


# ---- checking the result ---------------------------------------------------------------

def sha(path) -> str | None:
    if not path or not os.path.exists(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check(src, dst) -> list[tuple[str, bool, str]]:
    """(check, passed, detail) for an imported photo against its source."""
    c = []
    c.append(("original identical", sha(src.path) == sha(dst.path) if not src.raw_original else True,
              "byte-for-byte same file"))
    c.append(("date", abs(src.date.timestamp() - dst.date.timestamp()) < 1.5,
              f"{src.date:%Y-%m-%d %H:%M:%S} → {dst.date:%Y-%m-%d %H:%M:%S}"))
    sl, dl = src.location or (None, None), dst.location or (None, None)
    if sl[0] is not None:
        ok = dl[0] is not None and abs(sl[0] - dl[0]) < 1e-4 and abs(sl[1] - dl[1]) < 1e-4
        c.append(("location", ok, f"{sl} → {dl}"))
    c.append(("favourite", bool(src.favorite) == bool(dst.favorite), f"{src.favorite} → {dst.favorite}"))
    c.append(("size", (src.width, src.height) == (dst.width, dst.height),
              f"{src.width}×{src.height} → {dst.width}×{dst.height}"))
    if src.live_photo:
        c.append(("Live Photo", bool(dst.live_photo and dst.path_live_photo
                                     and os.path.exists(dst.path_live_photo)), "has its video"))
    if src.has_raw:
        c.append(("RAW pair", bool(dst.has_raw), "has the RAW"))
    if src.hasadjustments:
        c.append(("edited", bool(dst.hasadjustments), "Photos sees an edit"))
        c.append(("edit format", recipe_format(dst) == recipe_format(src),
                  f"{recipe_format(src)} → {recipe_format(dst)}"))
        c.append(("same adjustments", ops(dst) == ops(src),
                  ", ".join(ops(src)) + ("" if ops(dst) == ops(src) else f" → {', '.join(ops(dst))}")))
        c.append(("edited image", edited_image(dst) is not None, "saved in the library"))
        if src.live_photo and edited_live_video(src):
            c.append(("edited Live video", edited_live_video(dst) is not None, "saved in the library"))
    return c


MANUAL = {
    "crop": "Edit → Crop: the crop is there AND you can drag it back out to the full photo.",
    "complex": "Edit: each slider/section you used is at its value (Light, Color, B&W, etc.).",
    "edited": "Edit: the adjustments are at their values.",
    "edited-live": "Plays as a Live Photo (press and hold), the edit applies to the motion too; Edit keeps values.",
    "edited-raw": "Edit: values kept; Image → Use RAW as Original works.",
    "portrait": "Edit → Portrait: depth effect and lighting can be changed / turned off.",
    "slo-mo": "Plays slow in the middle; Edit shows the slow section and it can be changed.",
    "edited-video": "Edit: trim handles are where you left them and can be moved back.",
    "other-app-edit": "Looks edited; Revert to Original works (sliders won’t apply to another app’s edit).",
    "live": "Plays as a Live Photo.",
    "raw": "Info shows RAW+JPEG; Image → Use RAW as Original works.",
    "video": "Plays, with sound.",
    "photo": "Looks the same as in the source.",
}
COMMON = "Looks identical to the source, sharp, zooms smoothly (Cmd +); Image → Revert to Original if edited."


# ---- main ------------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source", type=Path)
    ap.add_argument("--list", action="store_true", help="show the kinds of photos in SOURCE")
    ap.add_argument("-n", type=int, default=2, help="photos per kind (default 2)")
    ap.add_argument("--kinds", help=f"only these kinds: {','.join(KINDS)}")
    ap.add_argument("--names", help="comma-separated original filenames instead of picking")
    ap.add_argument("--app", type=Path)
    args = ap.parse_args()

    src_path = args.source.resolve()
    print(f"Reading “{src_path.stem}”…")
    db = osxphotos.PhotosDB(dbfile=str(src_path))
    photos = [p for p in db.photos() if not p.hidden and not p.intrash]
    by_kind: dict[str, list] = {k: [] for k in KINDS}
    for p in sorted(photos, key=lambda p: p.date, reverse=True):
        by_kind[kind_of(p)].append(p)

    if args.list:
        for k, desc in KINDS.items():
            ps = by_kind[k]
            usable = [p for p in ps if not problems(p)]
            print(f"\n{k:15} {desc}: {len(ps):,} ({len(usable):,} usable)")
            for p in usable[:5]:
                print(f"   {p.original_filename:28} {p.date:%Y-%m-%d}  {', '.join(real_ops(p) or ops(p))}")
            bad = [p for p in ps if problems(p)]
            if bad:
                print(f"   + {len(bad):,} not usable, e.g. {bad[0].original_filename}: {'; '.join(problems(bad[0]))}")
        return

    if args.names:
        wanted = {n.strip().lower() for n in args.names.split(",")}
        chosen = [p for p in photos if (p.original_filename or "").lower() in wanted]
    else:
        kinds = [k.strip() for k in args.kinds.split(",")] if args.kinds else list(KINDS)
        unknown = set(kinds) - set(KINDS)
        if unknown:
            sys.exit(f"Unknown kinds: {', '.join(sorted(unknown))}. Use: {', '.join(KINDS)}")
        chosen = [p for k in kinds for p in [q for q in by_kind[k] if not problems(q)][: args.n]]
    for p in chosen:
        if problems(p):
            print(f"- {p.original_filename}: skipped ({'; '.join(problems(p))})")
    chosen = [p for p in chosen if not problems(p)]
    if not chosen:
        sys.exit("Nothing to import.")

    print(f"\nPicked {len(chosen)}:")
    for p in chosen:
        print(f"  [{kind_of(p)}] {p.original_filename} {p.date:%Y-%m-%d}  {', '.join(real_ops(p) or ops(p))}")

    system = Path(get_system_library_path() or "")
    if system == src_path:
        sys.exit("SOURCE is the System Photo Library; make the test library the system one first.")
    print(f"\nThis adds {len(chosen)} NEW photos (in a new album) to the System Photo Library: “{system.stem}”.")
    if input("Is that your TEST library? Continue? [y/N] ").strip().lower() != "y":
        sys.exit("Cancelled.")

    staging = Path(tempfile.mkdtemp(prefix="create-spike-"))
    entries = []
    for p in chosen:
        lat, lon = p.location if p.location else (None, None)
        entries.append({"source_uuid": p.uuid, "name": p.original_filename, "kind": kind_of(p),
                        "date": p.date.timestamp(), "lat": lat, "lon": lon,
                        "favorite": bool(p.favorite), "resources": resources(p)})
    manifest = staging / "manifest.json"
    manifest.write_text(json.dumps(entries, indent=1))

    app = args.app or newest_app()
    print(f"Using {app} (built {datetime.fromtimestamp(_built(app)):%Y-%m-%d %H:%M})")
    print("Allow Photos access if asked.\n")
    log = manifest.with_suffix(".json.log")
    proc = subprocess.Popen(["open", "-n", "-W", "-a", str(app), "--args", "--create-import", str(manifest)])
    shown, lines = 0, []
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
    results_file = staging / "results.json"
    if not results_file.exists():
        sys.exit(f"The app didn’t finish (no results in {staging}).")
    results = json.loads(results_file.read_text())

    # ---- check -------------------------------------------------------------------------
    print("\nChecking the imported photos against the source…")
    time.sleep(5)  # let Photos finish writing
    dst_db = osxphotos.PhotosDB(dbfile=str(system))
    report = [f"Import test {datetime.now():%Y-%m-%d %H:%M}: {src_path.stem} → {system.stem}\n"]
    passed_all = 0
    src_by_uuid = {p.uuid: p for p in chosen}
    for r in results:
        s = src_by_uuid[r["source_uuid"]]
        head = f"[{kind_of(s)}] {s.original_filename}"
        if not r.get("created"):
            report.append(f"✗ {head}: NOT CREATED — {' | '.join(r['errors'])}")
            continue
        d = dst_db.get_photo(r["created"].split("/")[0])
        if d is None:
            report.append(f"? {head}: created, but not found when reading “{system.stem}” (Photos may "
                          "still be saving; re-run the check later)")
            continue
        checks = check(s, d)
        ok = all(c[1] for c in checks)
        passed_all += ok
        note = "" if r["attempt"] == "all parts" else f" (only {r['attempt']}: {' | '.join(r['errors'])})"
        report.append(f"{'✓' if ok else '✗'} {head}{note}")
        for name, good, detail in checks:
            report.append(f"     {'ok ' if good else 'BAD'} {name}: {detail}")
        report.append(f"     → by hand: {MANUAL[kind_of(s)]}")
    report.append(f"\n{passed_all} of {len(results)} passed every automatic check.")
    report.append(f"By hand, for every photo: {COMMON}")
    text = "\n".join(report)
    print("\n" + text)
    out = REPO / f"import-test-{datetime.now():%Y%m%d-%H%M}.txt"
    out.write_text(text)
    print(f"\nSaved to {out}")


if __name__ == "__main__":
    main()
