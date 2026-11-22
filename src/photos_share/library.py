"""Read-only access to one or more .photoslibrary bundles.

Each library is indexed once with osxphotos (slow on a cold HDD) and the index is
cached as JSON under ~/Library/Caches/photos-share/. The cache is invalidated when
Photos.sqlite changes. Nothing is ever written inside a library.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import threading
from dataclasses import dataclass, field
from pathlib import Path

CACHE_ROOT = Path.home() / "Library" / "Caches" / "photos-share"
INDEX_VERSION = 3
log = logging.getLogger("photos_share")

# Opening a library reads a large DB from a spinning disk; do one at a time.
_open_lock = threading.Lock()


@dataclass(frozen=True)
class Asset:
    uuid: str
    date: str  # ISO 8601 with the photo's own UTC offset
    width: int
    height: int
    is_movie: bool
    is_screenshot: bool  # screenshots and screen recordings
    original: str | None  # paths relative to the library root; never sent to clients
    edited: str | None
    live: str | None  # paired video of a Live Photo
    filename: str | None  # original filename, e.g. IMG_1234.HEIC
    favorite: bool = False
    kinds: str = ""  # media-type letters, see KINDS
    lat: float | None = None
    lon: float | None = None
    place: str | None = None  # e.g. "Bucharest, Romania"
    persons: tuple[int, ...] = ()  # indexes into Library.people


# One letter per media type, so the per-asset payload stays small.
KINDS = {"s": "selfie", "n": "panorama", "p": "portrait", "o": "slow_mo", "t": "time_lapse"}


@dataclass
class Options:
    show_screenshots: bool = False


@dataclass
class Library:
    path: Path
    options: Options
    id: str = ""
    state: str = "closed"  # closed | opening | ready | error
    error: str | None = None
    assets: list[Asset] = field(default_factory=list)  # visible only, newest first
    by_uuid: dict[str, Asset] = field(default_factory=dict)
    albums: list[dict] = field(default_factory=list)
    people: list[dict] = field(default_factory=list)
    rev: int = 0  # bumps each time a new index is applied; lets the page spot updates
    _lock: threading.Lock = field(default_factory=threading.Lock)
    _loaded_fp: list | None = None    # fingerprint of the index currently in memory
    _pending_fp: list | None = None   # a newer fingerprint seen once, waiting to settle
    _refreshing: bool = False

    def __post_init__(self):
        self.id = hashlib.sha1(str(self.path).encode()).hexdigest()[:10]
        self.cache_dir = CACHE_ROOT / self.id

    @property
    def name(self) -> str:
        return self.path.stem

    @property
    def available(self) -> bool:
        """False when the drive holding the library is unplugged."""
        return (self.path / "database").is_dir()

    # ---- loading -----------------------------------------------------------

    def _fingerprint(self) -> list:
        db = self.path / "database"
        out = []
        for name in ("Photos.sqlite", "Photos.sqlite-wal"):
            try:
                st = (db / name).stat()
                out.append([name, st.st_size, st.st_mtime_ns])
            except FileNotFoundError:
                pass
        return out

    def load_cached(self) -> bool:
        """Load the index from cache if it is still valid. Fast; safe at startup."""
        try:
            data = json.loads((self.cache_dir / "index.json").read_text())
        except (FileNotFoundError, ValueError):
            return False
        if data.get("version") != INDEX_VERSION or data.get("fingerprint") != self._fingerprint():
            return False
        self._apply(data)
        return True

    def ensure_open(self) -> None:
        """Start indexing in the background if needed. Returns immediately."""
        with self._lock:
            if self.state in ("ready", "opening") or not self.available:
                return
            self.state, self.error = "opening", None
        threading.Thread(target=self._open, daemon=True, name=f"open-{self.name}").start()

    def _open(self) -> None:
        try:
            with _open_lock:
                if not self.load_cached():
                    self._apply(self._build_index())
        except Exception as e:  # noqa: BLE001 - surfaced to the UI
            log.exception("failed to open %s", self.path)
            self.state, self.error = "error", str(e)

    def refresh_if_changed(self) -> bool:
        """Re-index in the background if Photos changed the library. Call periodically.

        A change must look the same on two consecutive calls before re-indexing, so a
        library that Photos is still busy writing isn't re-read on every check.
        Returns True if a refresh was started.
        """
        if self.state != "ready" or self._refreshing or not self.available:
            return False
        fp = self._fingerprint()
        if fp == self._loaded_fp:
            self._pending_fp = None
            return False
        if fp != self._pending_fp:
            self._pending_fp = fp  # changed (or still changing): look again next time
            return False
        self._refreshing = True
        threading.Thread(target=self._refresh, daemon=True, name=f"refresh-{self.name}").start()
        return True

    def _refresh(self) -> None:
        try:
            with _open_lock:
                log.info("library changed, re-indexing %s", self.name)
                self._apply(self._build_index())
        except Exception:  # noqa: BLE001 - keep serving the previous index
            log.exception("re-indexing %s failed; keeping the previous index", self.path)
        finally:
            self._pending_fp = None
            self._refreshing = False

    def _build_index(self) -> dict:
        import osxphotos

        log.info("indexing %s", self.path)
        fingerprint = self._fingerprint()  # before reading, so a concurrent change re-indexes
        db = osxphotos.PhotosDB(dbfile=str(self.path), _skip_searchinfo=True)
        rel = self._relative

        # Named people, most photographed first, each with a face to use as their avatar.
        people, person_index = [], {}
        named = [pi for pi in db.person_info
                 if pi.name and not pi.name.startswith("_UNKNOWN") and pi.facecount]
        for pi in sorted(named, key=lambda pi: (not pi.favorite, -pi.facecount)):
            person_index[pi.uuid] = len(people)
            people.append({"name": pi.name, "face": _avatar(pi)})

        assets = []
        for p in db.photos():  # excludes Recently Deleted
            if p.hidden:
                continue
            lat, lon = p.location if p.location else (None, None)
            persons = sorted({person_index[f.person_info.uuid] for f in p.face_info
                              if f.person_info and f.person_info.uuid in person_index})
            assets.append({
                "favorite": bool(p.favorite),
                "kinds": "".join(k for k, attr in KINDS.items() if getattr(p, attr, False)),
                "lat": lat, "lon": lon,
                "place": _place_name(p.place),
                "persons": persons,
                "uuid": p.uuid,
                "date": p.date.isoformat(),
                "width": p.width or 0,
                "height": p.height or 0,
                "is_movie": bool(p.ismovie),
                "is_screenshot": bool(p.screenshot or p.screen_recording),
                "original": rel(p.path),
                "edited": rel(p.path_edited),
                "live": rel(p.path_live_photo) if p.live_photo else None,
                "filename": p.original_filename,
            })
        albums = [
            {"title": a.title, "uuids": [p.uuid for p in a.photos]}
            for a in db.album_info if a.title
        ]
        data = {"version": INDEX_VERSION, "fingerprint": fingerprint,
                "assets": assets, "albums": albums, "people": people}
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        tmp = self.cache_dir / "index.json.tmp"
        tmp.write_text(json.dumps(data))
        tmp.replace(self.cache_dir / "index.json")
        return data

    def _relative(self, p: str | None) -> str | None:
        if not p:
            return None
        try:
            return str(Path(p).relative_to(self.path))
        except ValueError:
            return p  # referenced file outside the library

    def _apply(self, data: dict) -> None:
        all_assets = [Asset(**{**a, "persons": tuple(a.get("persons", ()))})
                      for a in data["assets"]]
        visible = [a for a in all_assets
                   if self.options.show_screenshots or not a.is_screenshot]
        visible.sort(key=lambda a: a.date, reverse=True)
        by_uuid = {a.uuid: a for a in visible}
        albums = []
        for al in data["albums"]:
            uuids = [u for u in al["uuids"] if u in by_uuid]
            if uuids:
                albums.append({"title": al["title"], "uuids": uuids})
        # Keep every person (indexes in assets refer to this list); the UI hides people
        # with no visible photos, and avatars on hidden photos are dropped here.
        people = [dict(p, face=p["face"] if p["face"] and p["face"]["u"] in by_uuid else None)
                  for p in data.get("people", [])]
        self._drop_stale_renditions(by_uuid)
        self.assets, self.by_uuid, self.albums, self.people = visible, by_uuid, albums, people
        self._loaded_fp = data.get("fingerprint")
        self.rev += 1
        self.state = "ready"

    def _drop_stale_renditions(self, new: dict[str, Asset]) -> None:
        """Photos edited (or replaced) since the last index get fresh previews."""
        for uuid, old in self.by_uuid.items():
            cur = new.get(uuid)
            if cur and (cur.edited, cur.original) == (old.edited, old.original):
                continue
            for sub, ext in (("thumb", "jpg"), ("full", "jpg"), ("video", "mp4")):
                (self.cache_dir / sub / f"{uuid}.{ext}").unlink(missing_ok=True)

    # ---- file lookup (server-side only) ------------------------------------

    def abs(self, rel: str | None) -> Path | None:
        if not rel:
            return None
        p = self.path / rel
        return p if p.exists() else None

    def derivatives(self, uuid: str) -> list[Path]:
        """Preview JPEGs Photos already generated, largest first."""
        found = []
        for sub in (Path("resources/derivatives") / uuid[0],
                    Path("resources/derivatives/masters") / uuid[0]):
            d = self.path / sub
            try:
                found += [d / n for n in os.listdir(d) if n.startswith(uuid + "_")
                          and n.lower().endswith((".jpg", ".jpeg"))]
            except FileNotFoundError:
                continue
        return sorted(found, key=lambda p: p.stat().st_size, reverse=True)


def _avatar(person) -> dict | None:
    """The person's key face as {u: photo uuid, x, y: centre, s: size}, normalised to 0–1.

    x/y are fractions of the photo's displayed width/height; s is the face diameter as a
    fraction of the photo's longer side. The browser crops with CSS, so no image work here.
    """
    candidates = []
    if person.keyphoto:
        candidates += [f for f in person.keyphoto.face_info
                       if f.person_info and f.person_info.uuid == person.uuid]
    candidates += person.face_info[:20]
    for face in candidates:
        photo = face.photo
        w, h = photo.width, photo.height
        if not (w and h) or photo.hidden or photo.intrash:
            continue
        (x0, y0), (x1, y1) = face.face_rect
        return {"u": photo.uuid, "x": round((x0 + x1) / 2 / w, 4),
                "y": round((y0 + y1) / 2 / h, 4), "s": round(face.size, 4)}
    return None


def _place_name(place) -> str | None:
    """Short, human place name: 'City, Country' when available."""
    if not place:
        return None
    try:
        names = place.names
        city = (names.city or names.sub_administrative_area or names.additional_city_info
                or names.state_province or [None])[0]
        country = (names.country or [None])[0]
        parts = [p for p in (city, country) if p]
        if parts:
            return ", ".join(dict.fromkeys(parts))
    except AttributeError:
        pass
    return place.name


class Collection:
    """A single library, or every .photoslibrary inside a folder."""

    def __init__(self, root: Path, options: Options, include: list[str] | None = None):
        root = root.expanduser().resolve()
        if root.suffix == ".photoslibrary":
            paths = [root]
        elif root.is_dir():
            paths = sorted(root.glob("*.photoslibrary"), key=lambda p: p.name.lower())
        else:
            raise ValueError(f"Not found: {root}")
        if include:
            wanted = {n.lower().removesuffix(".photoslibrary") for n in include}
            paths = [p for p in paths if p.stem.lower() in wanted]
            missing = wanted - {p.stem.lower() for p in paths}
            if missing:
                raise ValueError(f"Libraries not found: {', '.join(sorted(missing))}")
        paths = [p for p in paths if (p / "database" / "Photos.sqlite").exists()]
        if not paths:
            raise ValueError(f"No Photos libraries found at {root}")
        self.libraries = {lib.id: lib for lib in (Library(p, options) for p in paths)}
        for lib in self.libraries.values():
            lib.load_cached()

    def get(self, lib_id: str) -> Library | None:
        return self.libraries.get(lib_id)

    def watch(self, interval: float) -> threading.Event:
        """Check opened libraries for changes every `interval` seconds. Set the returned
        event to stop."""
        stop = threading.Event()

        def loop():
            while not stop.wait(interval):
                for lib in self.libraries.values():
                    try:
                        lib.refresh_if_changed()
                    except OSError:
                        pass  # drive went away mid-check; try again next time

        threading.Thread(target=loop, daemon=True, name="watch").start()
        return stop
