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
INDEX_VERSION = 1
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
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def __post_init__(self):
        self.id = hashlib.sha1(str(self.path).encode()).hexdigest()[:10]
        self.cache_dir = CACHE_ROOT / self.id

    @property
    def name(self) -> str:
        return self.path.stem

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
            if self.state in ("ready", "opening"):
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

    def _build_index(self) -> dict:
        import osxphotos

        log.info("indexing %s", self.path)
        fingerprint = self._fingerprint()  # before reading, so a concurrent change re-indexes
        db = osxphotos.PhotosDB(dbfile=str(self.path), _skip_searchinfo=True)
        rel = self._relative
        assets = []
        for p in db.photos():  # excludes Recently Deleted
            if p.hidden:
                continue
            assets.append({
                "uuid": p.uuid,
                "date": p.date.isoformat(),
                "width": p.width or 0,
                "height": p.height or 0,
                "is_movie": bool(p.ismovie),
                "is_screenshot": bool(p.screenshot or p.screen_recording),
                "original": rel(p.path),
                "edited": rel(p.path_edited),
                "live": rel(p.path_live_photo) if p.live_photo else None,
            })
        albums = [
            {"title": a.title, "uuids": [p.uuid for p in a.photos]}
            for a in db.album_info if a.title
        ]
        data = {"version": INDEX_VERSION, "fingerprint": fingerprint,
                "assets": assets, "albums": albums}
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
        all_assets = [Asset(**a) for a in data["assets"]]
        visible = [a for a in all_assets
                   if self.options.show_screenshots or not a.is_screenshot]
        visible.sort(key=lambda a: a.date, reverse=True)
        by_uuid = {a.uuid: a for a in visible}
        albums = []
        for al in data["albums"]:
            uuids = [u for u in al["uuids"] if u in by_uuid]
            if uuids:
                albums.append({"title": al["title"], "uuids": uuids})
        self.assets, self.by_uuid, self.albums = visible, by_uuid, albums
        self.state = "ready"

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
