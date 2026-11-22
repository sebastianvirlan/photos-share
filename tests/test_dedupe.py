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
