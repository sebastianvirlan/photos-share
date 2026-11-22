import sys
import types
from datetime import datetime

import pytest

from photos_share import dedupe
from photos_share.dedupe import Item, match, report


def item(uuid, fp="fp-" , name=None, size=1000, date="2024-01-01T10:00:00+00:00", edited=False):
    return Item(uuid=uuid, fingerprint=None if fp is None else (fp + uuid if fp == "fp-" else fp),
                filename=name or f"img_{uuid}.heic", size=size, date=date, edited=edited)


def test_match_by_fingerprint_even_if_renamed():
    src = [item("A", fp="X", name="a.heic")]
    dst = [item("Z", fp="X", name="totally-different.heic")]
    r = match(src, dst)
    assert [i.uuid for i in r.matched] == ["A"] and r.matched_by_fallback == 0


def test_fallback_on_filename_size_and_date():
    src = [item("A", fp="X", name="IMG_1.HEIC".lower())]
    dst = [item("B", fp="Y", name="img_1.heic")]          # fingerprint differs, rest equal
    r = match(src, dst)
    assert [i.uuid for i in r.matched] == ["A"] and r.matched_by_fallback == 1


@pytest.mark.parametrize("change", [dict(size=999), dict(date="2024-01-01T10:00:01+00:00"),
                                    dict(name="other.heic")])
def test_fallback_needs_all_three(change):
    src = [item("A", fp="X", name="img.heic")]
    dst = [item("B", fp="Y", **{"name": "img.heic", **change})]
    assert [i.uuid for i in match(src, dst).missing] == ["A"]


def test_missing_and_no_fallback_without_size():
    src = [item("A", fp=None, size=None)]
    dst = [item("A2", fp=None, size=None, name="img_A.heic")]
    assert len(match(src, dst).missing) == 1


def test_edit_that_did_not_come_across_is_kept_out():
    src = [item("A", fp="X", edited=True), item("B", fp="Y", edited=True)]
    dst = [item("A2", fp="X", edited=False), item("B2", fp="Y", edited=True)]
    r = match(src, dst)
    assert [i.uuid for i in r.edit_lost] == ["A"]
    assert [i.uuid for i in r.matched] == ["B"]


def test_unedited_source_matches_edited_destination():
    r = match([item("A", fp="X")], [item("A2", fp="X", edited=True)])
    assert [i.uuid for i in r.matched] == ["A"]


def test_report_wording():
    from pathlib import Path
    all_in = match([item("A", fp="X")], [item("B", fp="X")])
    assert "whole source library can go to the Trash" in report(all_in, Path("S.photoslibrary"),
                                                                Path("D.photoslibrary"))
    some = match([item("A", fp="X"), item("C", fp="Q")], [item("B", fp="X")])
    text = report(some, Path("S.photoslibrary"), Path("D.photoslibrary"))
    assert "--mark" in text and "img_C.heic" in text and "Trash" not in text


def test_item_from_photo():
    p = types.SimpleNamespace(uuid="U", fingerprint="F", original_filename="IMG_9.HEIC",
                              original_filesize=42, date=datetime(2024, 5, 1, 10, 0, 0, 123456),
                              hasadjustments=1, hidden=False)
    i = Item.from_photo(p)
    assert (i.filename, i.size, i.date, i.edited) == ("img_9.heic", 42, "2024-05-01T10:00:00", True)


def test_mark_creates_unique_album_in_batches(monkeypatch, tmp_path):
    calls = {"opened": None, "added": [], "spotlit": False}

    class Album:
        def add(self, photos):
            calls["added"].append(len(photos))

        def spotlight(self):
            calls["spotlit"] = True

    class Library:
        def open(self, path):
            calls["opened"] = path

        def album_names(self):
            return ["Safe", "Safe (2)"]

        def create_album(self, name):
            calls["album"] = name
            return Album()

    fake = types.SimpleNamespace(PhotosLibrary=Library, Photo=lambda uuid: uuid)
    monkeypatch.setitem(sys.modules, "photoscript", fake)
    items = [item(str(i)) for i in range(450)]
    assert dedupe.mark(tmp_path / "S.photoslibrary", items, "Safe") == 450
    assert calls["album"] == "Safe (3)" and calls["added"] == [200, 200, 50] and calls["spotlit"]


def test_mark_refuses_when_wrong_library_open(monkeypatch, tmp_path):
    def missing(uuid):
        raise ValueError("no such photo")

    lib = types.SimpleNamespace(open=lambda p: None)
    monkeypatch.setitem(sys.modules, "photoscript",
                        types.SimpleNamespace(PhotosLibrary=lambda: lib, Photo=missing))
    with pytest.raises(RuntimeError, match="didn't open"):
        dedupe.mark(tmp_path / "S.photoslibrary", [item("A")], "Safe")


def test_cli_rejects_same_or_bad_libraries(tmp_path, capsys):
    with pytest.raises(SystemExit, match="not a Photos library"):
        dedupe.main([str(tmp_path / "a"), str(tmp_path / "b")])
    lib = tmp_path / "L.photoslibrary" / "database"
    lib.mkdir(parents=True)
    (lib / "Photos.sqlite").write_bytes(b"x")
    with pytest.raises(SystemExit, match="same library"):
        dedupe.main([str(tmp_path / "L.photoslibrary"), str(tmp_path / "L.photoslibrary")])


# ---- automatic clean-up: every refusal path, with PhotoKit / Finder faked ------------

from photos_share.dedupe import CleanupError, Result  # noqa: E402


def verified(*uuids):
    return Result(matched=[item(u, date="2024-01-01T10:00:00+00:00") for u in uuids])


class FakeAsset:
    def __init__(self, uuid, epoch):
        self.uuid, self.epoch = uuid, epoch

    def localIdentifier(self):
        return f"{self.uuid}/L0/001"

    def creationDate(self):
        return types.SimpleNamespace(timeIntervalSince1970=lambda: self.epoch)


class FakeFetch:
    def __init__(self, assets):
        self.assets = assets

    def count(self):
        return len(self.assets)

    def objectAtIndex_(self, i):
        return self.assets[i]


def fake_photos(monkeypatch, *, auth=3, assets=(), succeed=True):
    """Install a fake `Photos` (PhotoKit) module; returns a log of what was asked of it."""
    log = {"deleted": None, "requested": None}

    class Lib:
        @staticmethod
        def requestAuthorizationForAccessLevel_handler_(level, handler):
            handler(auth)

        @staticmethod
        def sharedPhotoLibrary():
            return Lib

        @staticmethod
        def performChanges_completionHandler_(changes, done):
            changes()
            done(succeed, None)

    class Asset:
        @staticmethod
        def fetchAssetsWithLocalIdentifiers_options_(ids, _):
            log["requested"] = ids
            return FakeFetch([a for a in assets if f"{a.uuid}/L0/001" in ids])

    class ChangeRequest:
        @staticmethod
        def deleteAssets_(fetch):
            log["deleted"] = [a.uuid for a in fetch.assets]

    monkeypatch.setitem(sys.modules, "Photos", types.SimpleNamespace(
        PHPhotoLibrary=Lib, PHAsset=Asset, PHAssetChangeRequest=ChangeRequest,
        PHAccessLevelReadWrite=2, PHAuthorizationStatusAuthorized=3))
    return log


SRC = None
JAN1 = 1704103200.0  # 2024-01-01T10:00:00Z


@pytest.fixture
def src(tmp_path, monkeypatch):
    path = (tmp_path / "Source.photoslibrary").resolve()
    path.mkdir()
    monkeypatch.setattr(dedupe, "system_library", lambda: path)  # source IS the system library
    return path


def test_delete_refused_unless_source_is_system_library(src, monkeypatch):
    log = fake_photos(monkeypatch, assets=[FakeAsset("A", JAN1)])
    monkeypatch.setattr(dedupe, "system_library", lambda: src.parent / "Other.photoslibrary")
    with pytest.raises(CleanupError, match="isn’t the System Photo Library"):
        dedupe.delete_with_photokit(src, verified("A").matched)
    assert log["requested"] is None and log["deleted"] is None


def test_delete_refused_without_permission(src, monkeypatch):
    log = fake_photos(monkeypatch, auth=2, assets=[FakeAsset("A", JAN1)])
    with pytest.raises(CleanupError, match="access wasn’t granted"):
        dedupe.delete_with_photokit(src, verified("A").matched)
    assert log["deleted"] is None


def test_delete_refused_when_any_photo_is_missing(src, monkeypatch):
    log = fake_photos(monkeypatch, assets=[FakeAsset("A", JAN1)])
    with pytest.raises(CleanupError, match="Only 1 of 2"):
        dedupe.delete_with_photokit(src, verified("A", "B").matched)
    assert log["deleted"] is None


def test_delete_refused_when_a_photo_does_not_match(src, monkeypatch):
    log = fake_photos(monkeypatch, assets=[FakeAsset("A", JAN1), FakeAsset("B", JAN1 + 3600)])
    with pytest.raises(CleanupError, match="doesn’t match"):
        dedupe.delete_with_photokit(src, verified("A", "B").matched)
    assert log["deleted"] is None


def test_delete_exactly_the_verified_photos(src, monkeypatch):
    log = fake_photos(monkeypatch, assets=[FakeAsset("A", JAN1), FakeAsset("B", JAN1),
                                           FakeAsset("C", JAN1)])
    assert dedupe.delete_with_photokit(src, verified("A", "B").matched) == 2
    assert log["requested"] == ["A/L0/001", "B/L0/001"] and log["deleted"] == ["A", "B"]


def test_delete_cancelled_in_macos_dialog(src, monkeypatch):
    fake_photos(monkeypatch, assets=[FakeAsset("A", JAN1)], succeed=False)
    with pytest.raises(CleanupError, match="cancelled"):
        dedupe.delete_with_photokit(src, verified("A").matched)


class FakeFileManager:
    trashed = []

    @classmethod
    def defaultManager(cls):
        return cls

    @classmethod
    def trashItemAtURL_resultingItemURL_error_(cls, url, _, __):
        cls.trashed.append(url)
        return True, types.SimpleNamespace(path=lambda: "/Users/x/.Trash/Source.photoslibrary"), None


@pytest.fixture
def finder(monkeypatch):
    import Foundation
    FakeFileManager.trashed = []
    monkeypatch.setattr(Foundation, "NSFileManager", FakeFileManager)
    monkeypatch.setattr(dedupe, "photos_running", lambda: False)
    return FakeFileManager


def test_trash_refused_unless_everything_verified(src, finder, monkeypatch):
    monkeypatch.setattr(dedupe, "system_library", lambda: None)
    partial = Result(matched=[item("A")], missing=[item("B")])
    with pytest.raises(CleanupError, match="Not every photo"):
        dedupe.trash_library(src, partial)
    edits = Result(matched=[item("A")], edit_lost=[item("B")])
    with pytest.raises(CleanupError, match="Not every photo"):
        dedupe.trash_library(src, edits)
    assert finder.trashed == []


def test_trash_refused_for_system_library_or_while_photos_runs(src, finder, monkeypatch):
    with pytest.raises(CleanupError, match="System Photo Library"):
        dedupe.trash_library(src, verified("A"))
    monkeypatch.setattr(dedupe, "system_library", lambda: None)
    monkeypatch.setattr(dedupe, "photos_running", lambda: True)
    with pytest.raises(CleanupError, match="Quit Photos"):
        dedupe.trash_library(src, verified("A"))
    assert finder.trashed == []


def test_trash_moves_library(src, finder, monkeypatch):
    monkeypatch.setattr(dedupe, "system_library", lambda: None)
    where = dedupe.trash_library(src, verified("A"))
    assert len(finder.trashed) == 1 and where.name == "Source.photoslibrary"


def test_real_system_library_lookup_is_a_path():
    p = dedupe.system_library()
    assert p is None or p.suffix == ".photoslibrary"
