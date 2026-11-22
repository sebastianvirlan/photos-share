"""Fixtures: a fake .photoslibrary with a pre-built index, so tests need no real library.

The index (what osxphotos would produce) is written straight into the cache, with the
fingerprint of the fake Photos.sqlite, so Library.load_cached() accepts it.
"""

from __future__ import annotations

import json
import struct
import subprocess
import zlib
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import photos_share.auth as auth_mod
import photos_share.library as library_mod
from photos_share.library import INDEX_VERSION, Collection, Library, Options
from photos_share.server import create_app


def _png(path: Path, w: int = 64, h: int = 48) -> None:
    # Each row: filter byte 0, then RGB pixels (a simple gradient).
    raw = b"".join(
        b"\x00" + b"".join(bytes([(x * 4) % 256, (y * 5) % 256, 128]) for x in range(w))
        for y in range(h))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def _jpeg(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    png = path.with_suffix(".png")
    _png(png)
    subprocess.run(["sips", "-s", "format", "jpeg", str(png), "--out", str(path)],
                   capture_output=True, check=True)
    png.unlink()


def asset(uuid, date, **kw):
    base = dict(uuid=uuid, date=date, width=64, height=48, is_movie=False, is_screenshot=False,
                original=None, edited=None, live=None, filename=None, favorite=False, kinds="",
                lat=None, lon=None, place=None, persons=[])
    return {**base, **kw}


ASSETS = [
    asset("P1", "2024-05-01T10:00:00+01:00", original="originals/P/P1.jpeg", filename="IMG_0001.JPG",
          favorite=True, kinds="s", lat=44.43, lon=26.1, place="Bucharest, Romania", persons=[0]),
    asset("P2", "2023-02-01T09:30:00+00:00", original="originals/P/P2.jpeg",
          edited="resources/renders/P/P2_edited.jpeg"),
    asset("SS", "2023-01-15T12:00:00+00:00", original="originals/S/SS.jpeg", is_screenshot=True,
          persons=[1]),
    asset("MV", "2022-07-04T18:00:00+02:00", original="originals/M/MV.mov", is_movie=True,
          filename="IMG_0002.MOV"),
    asset("LV", "2022-06-01T08:00:00+02:00", original="originals/L/LV.jpeg",
          live="originals/L/LV_live.mov"),
]
ALBUMS = [{"title": "Trip", "uuids": ["P1", "SS"]}, {"title": "OnlyShots", "uuids": ["SS"]}]
PEOPLE = [{"name": "Ana", "face": {"u": "P1", "x": 0.5, "y": 0.4, "s": 0.2}},
          {"name": "Screenshot Person", "face": {"u": "SS", "x": 0.5, "y": 0.5, "s": 0.2}}]
MOVIE_BYTES = b"\x00\x00\x00\x18ftypmp42" + bytes(range(256)) * 40


@pytest.fixture(autouse=True)
def cache_root(tmp_path, monkeypatch):
    """Keep every test away from the real ~/Library/Caches/photos-share."""
    root = tmp_path / "cache"
    monkeypatch.setattr(library_mod, "CACHE_ROOT", root)
    monkeypatch.setattr(auth_mod, "CACHE_ROOT", root)
    return root


def build_library(path: Path, assets=ASSETS, albums=ALBUMS, people=PEOPLE, write_index=True) -> Path:
    path = path.resolve()
    (path / "database").mkdir(parents=True)
    (path / "database" / "Photos.sqlite").write_bytes(b"not really sqlite")
    for a in assets:
        for key in ("original", "edited", "live"):
            rel = a.get(key)
            if not rel:
                continue
            f = path / rel
            if f.suffix == ".mov":
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(MOVIE_BYTES)
            else:
                _jpeg(f)
    if write_index:
        lib = Library(path, Options())
        lib.cache_dir.mkdir(parents=True, exist_ok=True)
        (lib.cache_dir / "index.json").write_text(json.dumps({
            "version": INDEX_VERSION, "fingerprint": lib._fingerprint(),
            "assets": assets, "albums": albums, "people": people}))
    return path


@pytest.fixture
def libs_dir(tmp_path):
    """A folder with an indexed library ('Fake') and an un-indexed one ('Second')."""
    root = tmp_path / "libs"
    build_library(root / "Fake.photoslibrary")
    build_library(root / "Second.photoslibrary", assets=[], write_index=False)
    return root.resolve()


@pytest.fixture
def make_client(libs_dir):
    def make(screenshots=False, downloads=False, video="original", auth=None, only=None):
        col = Collection(libs_dir, Options(show_screenshots=screenshots), only)
        return TestClient(create_app(col, video, downloads, auth)), col
    return make


@pytest.fixture
def client(make_client):
    c, col = make_client()
    return c


@pytest.fixture
def fake_id(libs_dir):
    return Library((libs_dir / "Fake.photoslibrary").resolve(), Options()).id
