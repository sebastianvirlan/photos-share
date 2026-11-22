import json
import sys
import types
from datetime import datetime, timezone
from pathlib import Path

import pytest

from photos_share import dedupe, duplicates


# ---- real images, made with macOS' own drawing ----------------------------------------

def make_jpeg(path: Path, w: int, h: int, pattern: str, quality=0.9) -> str:
    import Quartz
    from Foundation import NSURL
    ctx = Quartz.CGBitmapContextCreate(None, w, h, 8, 0, Quartz.CGColorSpaceCreateDeviceRGB(),
                                       Quartz.kCGImageAlphaPremultipliedLast)
    if pattern == "sunset":   # warm gradient with a dark band and a "sun"
        for y in range(0, h, max(1, h // 64)):
            t = y / h
            Quartz.CGContextSetRGBFillColor(ctx, 1.0, 0.3 + 0.6 * t, 0.2 + 0.3 * t, 1)
            Quartz.CGContextFillRect(ctx, Quartz.CGRectMake(0, y, w, h // 64 + 1))
        Quartz.CGContextSetRGBFillColor(ctx, 0.1, 0.1, 0.2, 1)
        Quartz.CGContextFillRect(ctx, Quartz.CGRectMake(0, 0, w, h * 0.3))
        Quartz.CGContextSetRGBFillColor(ctx, 1, 1, 0.8, 1)
        Quartz.CGContextFillEllipseInRect(ctx, Quartz.CGRectMake(w * 0.6, h * 0.5, w * 0.2, w * 0.2))
    else:                     # checkerboard-ish blocks
        for i in range(8):
            for j in range(8):
                v = ((i * 3 + j * 5) % 7) / 7
                Quartz.CGContextSetRGBFillColor(ctx, v, 1 - v, (i % 2) * 0.8, 1)
                Quartz.CGContextFillRect(ctx, Quartz.CGRectMake(i * w / 8, j * h / 8, w / 8 + 1, h / 8 + 1))
    img = Quartz.CGBitmapContextCreateImage(ctx)
    dest = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(str(path)), "public.jpeg", 1, None)
    Quartz.CGImageDestinationAddImage(dest, img, {Quartz.kCGImageDestinationLossyCompressionQuality: quality})
    assert Quartz.CGImageDestinationFinalize(dest)
    return str(path)


def test_hashes_match_resaved_copies_and_not_other_pictures(tmp_path):
    big = duplicates.image_hashes(make_jpeg(tmp_path / "a.jpg", 1200, 900, "sunset"))
    small = duplicates.image_hashes(make_jpeg(tmp_path / "b.jpg", 400, 300, "sunset", quality=0.4))
    other = duplicates.image_hashes(make_jpeg(tmp_path / "c.jpg", 1200, 900, "blocks"))
    assert duplicates.distance(big[0], small[0]) <= duplicates.NEAR_DHASH
    assert duplicates.distance(big[1], small[1]) <= duplicates.NEAR_AHASH
    assert duplicates.distance(big[0], other[0]) > duplicates.NEAR_DHASH
    assert big[2] == pytest.approx(4 / 3, rel=0.01)
    assert duplicates.image_hashes(str(tmp_path / "missing.jpg")) is None


def test_near_pairs():
    h = {"a": (0b1011 << 40 | 0xF0F0, 0xFF00, 1.33), "b": (0b1011 << 40 | 0xF0F1, 0xFF01, 1.33),
         "c": (0b1011 << 40 | 0xF0F1, 0xFF01, 0.75),        # same look, other shape
         "d": (0x0F0F0F0F0F0F0F0F, 0x00FF, 1.33),            # different picture
         "e": (0, 0, 1.33), "f": (0, 0, 1.33)}               # blank: never matched
    assert set(duplicates.near_pairs(h)) == {("a", "b")}
    assert set(duplicates.near_pairs(h, skip=lambda a, b: True)) == set()


# ---- choosing what to keep, and what to carry over --------------------------------------

def copy(uuid, **kw):
    base = dict(uuid=uuid, name=f"IMG_{uuid}.HEIC", date="2024-05-01T10:00:00", added="2024-05-02T10:00:00",
                thumb=None, original=None, width=4032, height=3024, size=100, movie=False, live=False,
                edited=False, favorite=False, hidden=False, albums=[], keywords=[], title=None,
                description=None, has_location=False)
    return duplicates.Copy(**{**base, **kw})


def test_keeper_prefers_bigger_then_edited_then_details_then_first_added():
    assert duplicates.keeper([copy("a", width=1280, height=960), copy("b")]).uuid == "b"
    assert duplicates.keeper([copy("a"), copy("b", edited=True)]).uuid == "b"
    assert duplicates.keeper([copy("a"), copy("b", albums=["Trip"])]).uuid == "b"
    assert duplicates.keeper([copy("a", added="2024-06-01T00:00:00"), copy("b")]).uuid == "b"


def ph(uuid, **kw):
    base = dict(uuid=uuid, favorite=False, albums=[], keywords=[], title=None, description=None,
                location=(None, None), original_filename=f"IMG_{uuid}.HEIC",
                date=datetime(2024, 5, 1, 10, 0, 0, 250000, tzinfo=timezone.utc))
    return types.SimpleNamespace(**{**base, **kw})


def test_merge_plan():
    keep = ph("k", albums=["Trip"], keywords=["sea"])
    rem = [ph("r1", favorite=True, albums=["Trip", "Best"], keywords=["sea", "sun"], title="Beach",
              location=(44.4, 26.1)),
           ph("r2", description="Day one", keywords=["sun", "sand"])]
    assert duplicates.merge_plan(keep, rem) == {
        "favorite": True, "albums": ["Best"], "keywords": ["sea", "sun", "sand"],
        "title": "Beach", "description": "Day one", "location": (44.4, 26.1)}
    assert duplicates.merge_plan(ph("k", favorite=True, title="Mine"), [ph("r", title="Theirs")]) == {}


# ---- a whole scan, with the library faked ----------------------------------------------

def lib_photo(uuid, fp=None, size=100, **kw):
    base = dict(uuid=uuid, original_filename=f"IMG_{uuid}.HEIC", fingerprint=fp, original_filesize=size,
                date=datetime(2024, 5, 1, 10, 0, tzinfo=timezone.utc),
                date_added=datetime(2024, 5, 2, 10, 0, tzinfo=timezone.utc),
                path=f"/lib/{uuid}.heic", width=4032, height=3024, ismovie=False, live_photo=False,
                hasadjustments=False, favorite=False, hidden=False, albums=[], keywords=[], title=None,
                description=None, location=(None, None), _info={})
    return types.SimpleNamespace(**{**base, **kw})


def test_scan(monkeypatch, tmp_path):
    photos = [
        lib_photo("A1", "fp-1"), lib_photo("A2", "fp-1", favorite=True),        # exact pair
        lib_photo("B1", "fp-2"), lib_photo("B2", "fp-3", width=1280, height=960),  # look alike
        lib_photo("C1", "fp-4", _info={"burstUUID": "x"}),
        lib_photo("C2", "fp-5", _info={"burstUUID": "x"}),                         # burst: not copies
        lib_photo("D1", "fp-6"), lib_photo("H1", "fp-6", hidden=True),             # hidden copy
        lib_photo("V1", "fp-7", ismovie=True), lib_photo("V2", "fp-7", ismovie=True),  # exact videos
    ]
    monkeypatch.setattr(duplicates, "_photos", lambda p: photos)
    thumbs = {p.uuid: str(tmp_path / f"{p.uuid}.jpg") for p in photos if not p.ismovie}
    for t in thumbs.values():
        Path(t).write_bytes(b"x")
    monkeypatch.setattr(dedupe, "thumbnail_map", lambda p: thumbs)
    look = {"A1": 1, "A2": 1, "B1": 0xABCDEF, "B2": 0xABCDEE, "C1": 0x123456, "C2": 0x123456,
            "D1": 0xF00F00, "H1": 0xF00F00}
    monkeypatch.setattr(duplicates, "image_hashes",
                        lambda path: (look[Path(path).stem] << 20, look[Path(path).stem], 1.33))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)   # hash cache goes in tmp

    groups = duplicates.scan(tmp_path / "L.photoslibrary")
    found = {frozenset(c.uuid for c in g.copies): g for g in groups}
    assert set(found) == {frozenset({"A1", "A2"}), frozenset({"B1", "B2"}), frozenset({"V1", "V2"})}
    assert found[frozenset({"A1", "A2"})].kind == "exact"
    assert found[frozenset({"A1", "A2"})].keep == "A2"        # the favourite
    assert found[frozenset({"B1", "B2"})].kind == "near"
    assert found[frozenset({"B1", "B2"})].keep == "B1"        # the bigger one
    assert [g.kind for g in groups][-1] == "near"             # exact groups first
    assert found[frozenset({"B1", "B2"})].copies[0].uuid == "B1"   # keeper listed first

    with_hidden = duplicates.scan(tmp_path / "L.photoslibrary", include_hidden=True)
    assert frozenset({"D1", "H1"}) in {frozenset(c.uuid for c in g.copies) for g in with_hidden}

    # hashes are cached: scanning again computes none
    monkeypatch.setattr(duplicates, "image_hashes", lambda path: pytest.fail("not cached"))
    assert len(duplicates.scan(tmp_path / "L.photoslibrary")) == 3
    with_hidden = duplicates.scan(tmp_path / "L.photoslibrary", include_hidden=True)
    assert frozenset({"D1", "H1"}) in {frozenset(c.uuid for c in g.copies) for g in with_hidden}


# ---- resolving, with Photos faked ------------------------------------------------------

@pytest.fixture
def fake_photos(monkeypatch):
    log = {"set": {}, "albums": {}, "opened": []}

    class Photo:
        def __init__(self, uuid):
            object.__setattr__(self, "uuid", uuid)

        def __setattr__(self, k, v):
            log["set"].setdefault(self.uuid, {})[k] = v

    class Album:
        def __init__(self, name):
            self.name = name

        def add(self, photos):
            log["albums"].setdefault(self.name, []).extend(p.uuid for p in photos)

    class Library:
        def open(self, path):
            log["opened"].append(path)

        def album(self, name):
            return Album(name) if name == "Trip" else None

        def create_album(self, name):
            return Album(name)

    monkeypatch.setitem(sys.modules, "photoscript", types.SimpleNamespace(Photo=Photo, PhotosLibrary=Library))
    monkeypatch.setattr(duplicates, "_wait_for_library", lambda p: None)
    return log


def test_resolve_not_system_library_merges_then_marks(monkeypatch, tmp_path, fake_photos):
    photos = [ph("k"), ph("r1", favorite=True, albums=["Trip"]), ph("r2"), ph("x")]
    monkeypatch.setattr(duplicates, "_photos", lambda p: photos)
    monkeypatch.setattr(dedupe, "system_library", lambda: None)
    out = duplicates.resolve(tmp_path / "L.photoslibrary",
                             [{"keep": "k", "remove": ["r1", "r2"]},
                              {"keep": "x", "remove": ["gone"]},
                              {"keep": "x", "remove": ["x"]}])
    assert fake_photos["set"]["k"] == {"favorite": True}
    assert fake_photos["albums"] == {"Trip": ["k"], duplicates.ALBUM: ["r1", "r2"]}
    assert (out["merged"], out["marked"], out["delete"]) == (1, 2, [])
    assert len(out["failed"]) == 2       # missing photo; keeper chosen for removal


def test_resolve_system_library_hands_copies_to_the_app(monkeypatch, tmp_path, fake_photos):
    lib = tmp_path / "L.photoslibrary"
    photos = [ph("k"), ph("r"), ph("k2"), ph("r2", keywords=["sun"])]
    monkeypatch.setattr(duplicates, "_photos", lambda p: photos)
    monkeypatch.setattr(dedupe, "system_library", lambda: lib.resolve())
    out = duplicates.resolve(lib, [{"keep": "k", "remove": ["r"]}, {"keep": "k2", "remove": ["r2"]}])
    assert out["system"] and out["marked"] == 0
    assert [d["uuid"] for d in out["delete"]] == ["r", "r2"]
    assert out["delete"][0]["date"] == "2024-05-01T10:00:00+00:00"
    assert fake_photos["set"] == {"k2": {"keywords": ["sun"]}}   # merged before deleting


def test_resolve_keeps_copies_when_merging_fails(monkeypatch, tmp_path, fake_photos):
    lib = tmp_path / "L.photoslibrary"
    photos = [ph("k"), ph("r", favorite=True)]
    monkeypatch.setattr(duplicates, "_photos", lambda p: photos)
    monkeypatch.setattr(dedupe, "system_library", lambda: lib.resolve())

    class Broken:
        def __init__(self, uuid):
            raise RuntimeError("Photos said no")
    monkeypatch.setattr(sys.modules["photoscript"], "Photo", Broken)
    out = duplicates.resolve(lib, [{"keep": "k", "remove": ["r"]}])
    assert out["delete"] == [] and "left alone" in out["failed"][0]["reason"]


def test_resolve_system_library_nothing_to_merge_never_opens_photos(monkeypatch, tmp_path):
    lib = tmp_path / "L.photoslibrary"
    monkeypatch.setattr(duplicates, "_photos", lambda p: [ph("k"), ph("r")])
    monkeypatch.setattr(dedupe, "system_library", lambda: lib.resolve())
    monkeypatch.setitem(sys.modules, "photoscript", None)
    out = duplicates.resolve(lib, [{"keep": "k", "remove": ["r"]}])
    assert [d["uuid"] for d in out["delete"]] == ["r"]


def test_cli_scan_json(monkeypatch, tmp_path, capsys):
    from conftest import build_library
    lib = build_library(tmp_path / "L.photoslibrary", assets=[], write_index=False)
    monkeypatch.setattr(duplicates, "scan", lambda p, hidden=False, emit=None: [
        duplicates.Group("exact", "a", [copy("a"), copy("b")])])
    monkeypatch.setattr(dedupe, "system_library", lambda: None)
    duplicates.main([str(lib), "--scan", "--json"])
    out = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert out["event"] == "result" and out["library_name"] == "L" and out["system"] is False
    assert [c["uuid"] for c in out["groups"][0]["copies"]] == ["a", "b"]
