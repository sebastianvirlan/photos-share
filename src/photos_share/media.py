"""Web-friendly renditions (cached; never written into the library)."""

from __future__ import annotations

import subprocess
import threading
from collections import defaultdict
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path

from .library import Asset, Library

THUMB_PX = 640
FULL_PX = 2048
VIDEO_EXT = {".mov", ".mp4", ".m4v"}

# Limit concurrent sips runs so a fast scroll doesn't thrash the HDD. Background work
# (preparing every thumbnail ahead of time) gets its own single, low-priority slot.
_sips_slots = threading.Semaphore(4)
_background_slots = threading.Semaphore(1)
_out_locks: defaultdict[Path, threading.Lock] = defaultdict(threading.Lock)
_background = ThreadPoolExecutor(max_workers=1, thread_name_prefix="thumbs")
_queued: set[Path] = set()
_queued_lock = threading.Lock()
_warmed: dict[str, int] = {}   # library id → rev whose thumbnails are being prepared


def _thumb_path(lib: Library, asset: Asset) -> Path:
    return lib.cache_dir / "thumb" / f"{asset.uuid}.jpg"


def thumbnail(lib: Library, asset: Asset, background: bool = False) -> Path | None:
    sources = lib.derivatives(asset.uuid)
    if not asset.is_movie:
        sources += [p for p in (lib.abs(asset.edited), lib.abs(asset.original)) if p]
    return _render(sources, _thumb_path(lib, asset), THUMB_PX, background)


def thumbnail_now(lib: Library, asset: Asset) -> tuple[Path | None, bool]:
    """A thumbnail without waiting: (path, final). When the proper one isn't made yet,
    Photos' own smallest preview is sent as is (final=False, so browsers don't keep it)
    and the proper one is made in the background for next time."""
    out = _thumb_path(lib, asset)
    if out.exists():
        return out, True
    previews = lib.derivatives(asset.uuid)
    if previews:
        _queue(out, lambda: thumbnail(lib, asset, background=True))
        return previews[-1], False      # smallest
    return thumbnail(lib, asset), True


def _queue(out: Path, job) -> None:
    with _queued_lock:
        if out in _queued:
            return
        _queued.add(out)

    def run():
        try:
            job()
        finally:
            with _queued_lock:
                _queued.discard(out)
    _background.submit(run)


def prepare_thumbnails(lib: Library) -> None:
    """Make every thumbnail ahead of time (newest first), once per version of the library,
    so later visits load instantly. Low priority; on-demand requests go first."""
    if _warmed.get(lib.id) == lib.rev:
        return
    _warmed[lib.id] = rev = lib.rev
    assets = list(lib.assets)

    def run():
        for a in assets:
            if lib.rev != rev:       # the library changed: a newer pass takes over
                return
            if not _thumb_path(lib, a).exists():
                thumbnail(lib, a, background=True)
    threading.Thread(target=run, daemon=True, name=f"prepare-{lib.name}").start()


def full_image(lib: Library, asset: Asset) -> Path | None:
    sources = [p for p in (lib.abs(asset.edited), lib.abs(asset.original)) if p]
    sources = [p for p in sources if p.suffix.lower() not in VIDEO_EXT]
    sources += lib.derivatives(asset.uuid)  # fallback if the original is missing
    return _render(sources, lib.cache_dir / "full" / f"{asset.uuid}.jpg", FULL_PX)


def _render(sources: list[Path], out: Path, max_px: int, background: bool = False) -> Path | None:
    if out.exists():
        return out
    with _out_locks[out]:
        if out.exists():
            return out
        out.parent.mkdir(parents=True, exist_ok=True)
        for src in sources:
            if src.suffix.lower() in VIDEO_EXT:
                continue
            tmp = out.with_suffix(".tmp.jpg")
            nice = ["nice", "-n", "15"] if background else []
            with _background_slots if background else _sips_slots:
                r = subprocess.run(
                    nice + ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82",
                            "-Z", str(max_px), str(src), "--out", str(tmp)],
                    capture_output=True,
                )
            if r.returncode == 0 and tmp.exists():
                tmp.replace(out)
                return out
            tmp.unlink(missing_ok=True)
    return None


def video_source(lib: Library, asset: Asset) -> Path | None:
    return lib.abs(asset.edited) or lib.abs(asset.original)


class VideoConverter:
    """Converts videos to 1080p H.264 with macOS's avconvert, one at a time."""

    def __init__(self):
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="avconvert")
        self._jobs: dict[Path, Future] = {}
        self._lock = threading.Lock()

    def status(self, lib: Library, asset: Asset) -> tuple[str, Path | None]:
        """Returns ("ready", path) | ("preparing", None) | ("error", None)."""
        out = lib.cache_dir / "video" / f"{asset.uuid}.mp4"
        if out.exists():
            return "ready", out
        src = video_source(lib, asset)
        if src is None:
            return "error", None
        with self._lock:
            job = self._jobs.get(out)
            if job is None:  # a failed job stays failed until restart; no retry loop
                job = self._pool.submit(self._convert, src, out)
                self._jobs[out] = job
        if job.done():
            return ("ready", out) if out.exists() else ("error", None)
        return "preparing", None

    @staticmethod
    def _convert(src: Path, out: Path) -> None:
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".tmp.mp4")
        subprocess.run(["avconvert", "-s", str(src), "-p", "Preset1920x1080",
                        "-o", str(tmp), "--replace"], capture_output=True, check=True)
        tmp.replace(out)
