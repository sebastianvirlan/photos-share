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

# Limit concurrent sips runs so a fast scroll doesn't thrash the HDD.
_sips_slots = threading.Semaphore(3)
_out_locks: defaultdict[Path, threading.Lock] = defaultdict(threading.Lock)


def thumbnail(lib: Library, asset: Asset) -> Path | None:
    sources = lib.derivatives(asset.uuid)
    if not asset.is_movie:
        sources += [p for p in (lib.abs(asset.edited), lib.abs(asset.original)) if p]
    return _render(sources, lib.cache_dir / "thumb" / f"{asset.uuid}.jpg", THUMB_PX)


def full_image(lib: Library, asset: Asset) -> Path | None:
    sources = [p for p in (lib.abs(asset.edited), lib.abs(asset.original)) if p]
    sources = [p for p in sources if p.suffix.lower() not in VIDEO_EXT]
    sources += lib.derivatives(asset.uuid)  # fallback if the original is missing
    return _render(sources, lib.cache_dir / "full" / f"{asset.uuid}.jpg", FULL_PX)


def _render(sources: list[Path], out: Path, max_px: int) -> Path | None:
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
            with _sips_slots:
                r = subprocess.run(
                    ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82",
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
