"""photos-duplicates: find duplicate photos within one Photos library, and resolve them.

  photos-duplicates LIB --scan [--hidden] --json      groups of duplicates (streams progress)
  photos-duplicates LIB --resolve FILE --json         merge details into the kept copies, then
                                                      put the others in an album, or (System
                                                      Photo Library) hand them to the Mac app
                                                      to delete

Exact copies share Photos' fingerprint of the original file. Near copies are the same picture
saved again (resized, recompressed, re-exported, a JPEG of a HEIC): found by comparing small
"perceptual hashes" of the previews Photos already keeps, and always left for you to confirm.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import dedupe

ALBUM = "Duplicates to delete"
NEAR_DHASH = 6      # of 64 bits: same picture, saved again
NEAR_AHASH = 10
ASPECT_TOLERANCE = 0.03
CHUNKS = 7          # NEAR_DHASH + 1: any two hashes within the limit share one chunk exactly


# ---- perceptual hashes -----------------------------------------------------------------

def _gray_pixels(path: str, w: int, h: int) -> bytes | None:
    """The image shrunk to w×h grayscale, via macOS' own image decoding."""
    import Quartz
    from Foundation import NSURL

    src = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(path), None)
    if src is None:
        return None
    img = Quartz.CGImageSourceCreateThumbnailAtIndex(src, 0, {
        Quartz.kCGImageSourceCreateThumbnailFromImageAlways: True,
        Quartz.kCGImageSourceCreateThumbnailWithTransform: True,
        Quartz.kCGImageSourceThumbnailMaxPixelSize: 64})
    if img is None:
        return None
    ctx = Quartz.CGBitmapContextCreate(None, w, h, 8, 0, Quartz.CGColorSpaceCreateDeviceGray(),
                                       Quartz.kCGImageAlphaNone)
    Quartz.CGContextSetInterpolationQuality(ctx, Quartz.kCGInterpolationHigh)
    Quartz.CGContextDrawImage(ctx, Quartz.CGRectMake(0, 0, w, h), img)
    out = Quartz.CGBitmapContextCreateImage(ctx)
    data = bytes(Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(out)))
    row = Quartz.CGImageGetBytesPerRow(out)
    return b"".join(data[y * row:y * row + w] for y in range(h))


def image_hashes(path: str) -> tuple[int, int, float] | None:
    """(dHash, aHash, aspect ratio) of an image, or None if it can't be read."""
    import Quartz
    from Foundation import NSURL

    d = _gray_pixels(path, 9, 8)
    a = _gray_pixels(path, 8, 8)
    if d is None or a is None:
        return None
    dhash = 0
    for y in range(8):
        for x in range(8):
            dhash = (dhash << 1) | (d[y * 9 + x] > d[y * 9 + x + 1])
    mean = sum(a) / 64
    ahash = 0
    for v in a:
        ahash = (ahash << 1) | (v > mean)
    src = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(path), None)
    props = Quartz.CGImageSourceCopyPropertiesAtIndex(src, 0, None) or {}
    w, h = props.get("PixelWidth") or 1, props.get("PixelHeight") or 1
    if (props.get("Orientation") or 1) >= 5:  # rotated 90°: width and height swap
        w, h = h, w
    return dhash, ahash, w / h


def distance(a: int, b: int) -> int:
    return (a ^ b).bit_count()


class HashCache:
    """Hashes by photo, kept between scans (recomputed when the preview file changes)."""

    def __init__(self, library: Path):
        key = hashlib.sha1(str(library.resolve()).encode()).hexdigest()[:16]
        self.path = Path.home() / "Library" / "Caches" / "photos-share" / f"duplicates-{key}.json"
        try:
            self.data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.data = {}

    def get(self, uuid: str, thumb: str) -> tuple[int, int, float] | None:
        hit = self.data.get(uuid)
        try:
            if hit and hit[0] == thumb and hit[1] == os.path.getmtime(thumb):
                return hit[2], hit[3], hit[4]
        except OSError:
            pass
        return None

    def put(self, uuid: str, thumb: str, h: tuple[int, int, float]) -> None:
        try:
            self.data[uuid] = [thumb, os.path.getmtime(thumb), *h]
        except OSError:
            pass

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data))
        tmp.replace(self.path)


# ---- scanning --------------------------------------------------------------------------

@dataclass
class Copy:
    uuid: str
    name: str | None
    date: str
    added: str
    thumb: str | None
    original: str | None
    width: int
    height: int
    size: int
    movie: bool
    live: bool
    edited: bool
    favorite: bool
    hidden: bool
    albums: list[str]
    keywords: list[str]
    title: str | None
    description: str | None
    has_location: bool
    distance: int = 0          # how different it looks from the suggested keeper (0-64)


@dataclass
class Group:
    kind: str                  # "exact" or "near"
    keep: str                  # suggested copy to keep
    copies: list[Copy] = field(default_factory=list)


def _copy(p, thumb: str | None) -> Copy:
    lat, lon = p.location if p.location else (None, None)
    return Copy(
        uuid=p.uuid, name=p.original_filename,
        date=p.date.replace(microsecond=0).isoformat() if p.date else "",
        added=p.date_added.replace(microsecond=0).isoformat() if p.date_added else "",
        thumb=thumb, original=str(p.path) if p.path else None,
        width=int(p.width or 0), height=int(p.height or 0), size=int(p.original_filesize or 0),
        movie=bool(p.ismovie), live=bool(p.live_photo), edited=bool(p.hasadjustments),
        favorite=bool(p.favorite), hidden=bool(p.hidden),
        albums=[a for a in p.albums if a], keywords=list(p.keywords or []),
        title=p.title or None, description=p.description or None,
        has_location=lat is not None and lon is not None)


def keeper(copies: list[Copy]) -> Copy:
    """The copy to keep: biggest, then edited, favourite, in most albums, has a place,
    has a title/caption/keywords, then the one added first."""
    return max(copies, key=lambda c: (
        c.width * c.height, c.edited, c.favorite, len(c.albums), c.has_location,
        bool(c.title or c.description or c.keywords),
        -(_ts(c.added) or 0)))


def _ts(iso: str) -> float | None:
    from datetime import datetime
    try:
        return datetime.fromisoformat(iso).timestamp()
    except ValueError:
        return None


class _Union:
    def __init__(self):
        self.parent: dict[str, str] = {}

    def find(self, x: str) -> str:
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def join(self, a: str, b: str) -> None:
        self.parent[self.find(a)] = self.find(b)


def _chunks(h: int) -> list[tuple[int, int]]:
    out, start = [], 0
    for i in range(CHUNKS):
        width = 64 // CHUNKS + (1 if i < 64 % CHUNKS else 0)
        out.append((i, (h >> start) & ((1 << width) - 1)))
        start += width
    return out


def near_pairs(hashes: dict[str, tuple[int, int, float]], skip=lambda a, b: False):
    """Pairs of photos that look the same: dHash and aHash close, same shape."""
    buckets: dict[tuple[int, int], list[str]] = {}
    for uuid, (d, _, _) in hashes.items():
        if d in (0, (1 << 64) - 1):   # blank/flat images look like everything
            continue
        for key in _chunks(d):
            buckets.setdefault(key, []).append(uuid)
    seen = set()
    for members in buckets.values():
        for i, a in enumerate(members):
            da, aa, ra = hashes[a]
            for b in members[i + 1:]:
                pair = (a, b) if a < b else (b, a)
                if pair in seen:
                    continue
                seen.add(pair)
                db, ab, rb = hashes[b]
                if (distance(da, db) <= NEAR_DHASH and distance(aa, ab) <= NEAR_AHASH
                        and abs(ra - rb) <= ASPECT_TOLERANCE * max(ra, rb) and not skip(a, b)):
                    yield pair


def _photos(path: Path):
    import osxphotos
    return osxphotos.PhotosDB(dbfile=str(path), _skip_searchinfo=True).photos()


def scan(lib: Path, include_hidden: bool = False, emit=lambda *a, **k: None) -> list[Group]:
    emit("progress", phase="reading", done=0, total=0)
    photos = [p for p in _photos(lib) if include_hidden or not p.hidden]
    by_uuid = {p.uuid: p for p in photos}
    thumbs = dedupe.thumbnail_map(lib)
    union = _Union()

    # exact: same original file
    by_print: dict[tuple, list[str]] = {}
    for p in photos:
        if p.fingerprint:
            by_print.setdefault((p.fingerprint, p.original_filesize), []).append(p.uuid)
    for members in by_print.values():
        for other in members[1:]:
            union.join(members[0], other)

    # near: same picture saved again (photos only)
    stills = [p for p in photos if not p.ismovie and thumbs.get(p.uuid)]
    cache = HashCache(lib)
    hashes: dict[str, tuple[int, int, float]] = {}
    todo = []
    for p in stills:
        hit = cache.get(p.uuid, thumbs[p.uuid])
        if hit:
            hashes[p.uuid] = hit
        else:
            todo.append(p.uuid)
    total = len(stills)
    done = total - len(todo)
    emit("progress", phase="comparing", done=done, total=total)
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as pool:
        for uuid, h in zip(todo, pool.map(lambda u: image_hashes(thumbs[u]), todo)):
            done += 1
            if h:
                hashes[uuid] = h
                cache.put(uuid, thumbs[uuid], h)
            if done % 200 == 0:
                emit("progress", phase="comparing", done=done, total=total)
                cache.save()
    cache.save()
    emit("progress", phase="comparing", done=total, total=total)

    def same_burst(a: str, b: str) -> bool:  # burst shots look alike but aren't copies
        ba = getattr(by_uuid[a], "_info", {}).get("burstUUID")
        return bool(ba) and ba == getattr(by_uuid[b], "_info", {}).get("burstUUID")

    for a, b in near_pairs(hashes, skip=same_burst):
        union.join(a, b)

    members: dict[str, list[str]] = {}
    for uuid in list(union.parent):
        members.setdefault(union.find(uuid), []).append(uuid)
    groups = []
    for uuids in members.values():
        if len(uuids) < 2:
            continue
        copies = [_copy(by_uuid[u], thumbs.get(u)) for u in uuids]
        prints = {(by_uuid[u].fingerprint, by_uuid[u].original_filesize) for u in uuids}
        exact = len(prints) == 1 and next(iter(prints))[0] is not None
        keep = keeper(copies)
        for c in copies:
            if c.uuid in hashes and keep.uuid in hashes:
                c.distance = distance(hashes[c.uuid][0], hashes[keep.uuid][0])
        copies.sort(key=lambda c: (c.uuid != keep.uuid, c.date))
        groups.append(Group("exact" if exact else "near", keep.uuid, copies))
    groups.sort(key=lambda g: (g.kind != "exact", g.copies[0].date))
    return groups


# ---- resolving -------------------------------------------------------------------------

def merge_plan(keep, removed: list) -> dict:
    """What the kept copy needs from the others so nothing is lost."""
    plan: dict = {}
    if not keep.favorite and any(r.favorite for r in removed):
        plan["favorite"] = True
    have = set(a for a in keep.albums if a)
    albums = sorted({a for r in removed for a in r.albums if a and a not in have})
    if albums:
        plan["albums"] = albums
    words = list(keep.keywords or [])
    extra = [w for r in removed for w in (r.keywords or []) if w not in words]
    if extra:
        plan["keywords"] = words + list(dict.fromkeys(extra))
    for attr in ("title", "description"):
        if not getattr(keep, attr):
            donor = next((getattr(r, attr) for r in removed if getattr(r, attr)), None)
            if donor:
                plan[attr] = donor
    if not (keep.location and keep.location[0] is not None):
        donor = next((r.location for r in removed if r.location and r.location[0] is not None), None)
        if donor:
            plan["location"] = donor
    return plan


def resolve(lib: Path, decisions: list[dict], emit=lambda *a, **k: None) -> dict:
    """decisions: [{"keep": uuid, "remove": [uuid, ...]}]. Checks everything again first."""
    photos = {p.uuid: p for p in _photos(lib)}
    system = dedupe.system_library() == lib.resolve()
    failed, work = [], []
    for d in decisions:
        keep, remove = photos.get(d["keep"]), [photos.get(u) for u in d.get("remove", [])]
        if keep is None or any(r is None for r in remove):
            failed.append({"uuid": d["keep"], "reason": "a photo in this group isn’t in the library any more"})
        elif not remove or d["keep"] in d["remove"]:
            failed.append({"uuid": d["keep"], "reason": "nothing to remove, or the kept copy was also chosen for removal"})
        else:
            work.append((keep, remove))

    plans = [(k, r, merge_plan(k, r)) for k, r in work]
    needs_photos = any(plan for _, _, plan in plans) or (not system and work)
    merged, marked, delete = 0, 0, []
    if needs_photos:
        import photoscript
        emit("progress", phase="opening", done=0, total=len(plans))
        photoscript.PhotosLibrary().open(str(lib))
        _wait_for_library(lib)
        lib_ = photoscript.PhotosLibrary()
        albums: dict[str, object] = {}

        def album(name):
            if name not in albums:
                albums[name] = lib_.album(name) or lib_.create_album(name)
            return albums[name]

        for i, (keep, remove, plan) in enumerate(plans, 1):
            try:
                if plan:
                    k = photoscript.Photo(keep.uuid)
                    if plan.get("favorite"):
                        k.favorite = True
                    if "keywords" in plan:
                        k.keywords = plan["keywords"]
                    for attr in ("title", "description"):
                        if attr in plan:
                            setattr(k, attr, plan[attr])
                    if "location" in plan:
                        k.location = tuple(plan["location"])
                    for name in plan.get("albums", []):
                        album(name).add([k])
                    merged += 1
            except Exception as e:  # noqa: BLE001  (don't remove copies whose details weren't saved)
                failed.append({"uuid": keep.uuid, "name": keep.original_filename,
                               "reason": f"couldn’t copy details onto the kept photo, so its copies were left alone: {e}"})
                continue
            if system:
                delete += [{"uuid": r.uuid, "date": r.date.replace(microsecond=0).isoformat()} for r in remove]
            else:
                album(ALBUM).add([photoscript.Photo(r.uuid) for r in remove])
                marked += len(remove)
            emit("progress", phase="merging", done=i, total=len(plans))
    else:  # system library, nothing to merge: the app deletes straight away
        for keep, remove, _ in plans:
            delete += [{"uuid": r.uuid, "date": r.date.replace(microsecond=0).isoformat()} for r in remove]

    out = {"system": system, "merged": merged, "marked": marked, "album": ALBUM,
           "delete": delete, "failed": failed}
    emit("done", **out)
    return out


def _wait_for_library(lib: Path) -> None:
    from .importer import _wait_for_library as wait
    wait(lib)


# ---- command line ----------------------------------------------------------------------

def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="photos-duplicates", description=__doc__.split("\n")[0])
    ap.add_argument("library", type=Path)
    ap.add_argument("--scan", action="store_true", help="find duplicates")
    ap.add_argument("--hidden", action="store_true", help="include hidden photos")
    ap.add_argument("--resolve", type=Path, metavar="FILE",
                    help='JSON [{"keep": uuid, "remove": [uuid, ...]}, ...]')
    ap.add_argument("--json", action="store_true", help="JSON lines for the Mac app")
    args = ap.parse_args(argv)
    logging.getLogger("osxphotos").setLevel(logging.ERROR)

    def emit(event: str, **data) -> None:
        if args.json:
            print(json.dumps({"event": event, **data}), flush=True)
        elif event == "progress" and data.get("total"):
            print(f"\r{data['phase'].capitalize()}… {data['done']:,}/{data['total']:,}", end="", flush=True)

    def fail(msg: str):
        if args.json:
            print(json.dumps({"event": "error", "message": msg}), flush=True)
            sys.exit(1)
        sys.exit(f"Error: {msg}")

    lib = args.library.expanduser().resolve()
    if lib.suffix != ".photoslibrary" or not (lib / "database" / "Photos.sqlite").exists():
        fail(f"not a Photos library: {lib}")

    if args.scan:
        try:
            groups = scan(lib, args.hidden, emit)
        except Exception as e:  # noqa: BLE001
            fail(f"couldn’t read “{lib.stem}”: {e}")
        if args.json:
            emit("result", groups=[asdict(g) for g in groups], library_name=lib.stem,
                 system=dedupe.system_library() == lib)
        else:
            print()
            for g in groups:
                print(f"[{g.kind}] " + ", ".join(
                    f"{c.name}{' (keep)' if c.uuid == g.keep else ''}" for c in g.copies))
            exact = [g for g in groups if g.kind == "exact"]
            print(f"\n{len(exact):,} groups of exact copies, {len(groups) - len(exact):,} of look-alikes.")
        return

    if args.resolve:
        try:
            out = resolve(lib, json.loads(args.resolve.read_text()), emit)
        except Exception as e:  # noqa: BLE001
            fail(str(e))
        if not args.json:
            print(f"\nMerged {out['merged']}, marked {out['marked']}, "
                  f"{len(out['delete'])} for deletion, {len(out['failed'])} problems.")
        return
    fail("give --scan or --resolve FILE")
