"""Why does the importer think a photo isn't in the destination yet?

Read-only. For every photo in SOURCE that the importer would list as new, but whose filename
also exists in DEST, prints both sides' fingerprint, size and date, so you can see which one
differs.

    uv run python scripts/check_match.py SOURCE.photoslibrary DEST.photoslibrary [NAME ...]

Give filenames (e.g. IMG_1234) to look only at those.
"""

import logging
import sys
from collections import defaultdict
from pathlib import Path

from photos_share import dedupe, importer


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = Path(sys.argv[1]).expanduser().resolve(), Path(sys.argv[2]).expanduser().resolve()
    names = [n.lower() for n in sys.argv[3:]]
    logging.getLogger("osxphotos").setLevel(logging.ERROR)

    print(f"Reading “{src.stem}”…", flush=True)
    s_items = [dedupe.Item.from_photo(p) for p in importer._photos(src)]
    print(f"Reading “{dst.stem}”…", flush=True)
    d_items = [dedupe.Item.from_photo(p) for p in importer._photos(dst)]
    pairs = dedupe.match(s_items, d_items).pairs

    by_name = defaultdict(list)
    for d in d_items:
        if d.filename:
            by_name[d.filename].append(d)

    new = [s for s in s_items if s.uuid not in pairs]
    print(f"\n{len(s_items):,} in “{src.stem}”, {len(new):,} would show as new.")
    shown = 0
    for s in new:
        stem = (s.filename or "").rsplit(".", 1)[0]
        if names and not any(n in (s.filename or "") for n in names):
            continue
        same_name = by_name.get(s.filename or "", [])
        if not same_name and not names:
            continue
        shown += 1
        print(f"\n{s.filename}  (source {s.uuid})")
        print(f"  source:  fingerprint {s.fingerprint}  size {s.size}  date {s.date}")
        if not same_name:
            print(f"  nothing named {stem} in “{dst.stem}”")
        for d in same_name:
            diff = [k for k, a, b in (("fingerprint", s.fingerprint, d.fingerprint),
                                      ("size", s.size, d.size),
                                      ("date", dedupe._instant(s.date), dedupe._instant(d.date)))
                    if a != b]
            print(f"  dest:    fingerprint {d.fingerprint}  size {d.size}  date {d.date}  ({d.uuid})")
            print(f"           differs: {', '.join(diff) or 'nothing?'}")
    if not shown:
        print("None of them has a photo with the same filename in the destination.")


if __name__ == "__main__":
    main()
