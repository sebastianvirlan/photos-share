import json
import os

import pytest

from photos_share.library import Collection, Library, Options

from conftest import build_library


def test_folder_lists_all_libraries_and_loads_cached_index(libs_dir):
    col = Collection(libs_dir, Options())
    by_name = {lib.name: lib for lib in col.libraries.values()}
    assert set(by_name) == {"Fake", "Second"}
    assert by_name["Fake"].state == "ready"      # pre-built index accepted
    assert by_name["Second"].state == "closed"   # no index yet; opens on demand


def test_single_library_path(libs_dir):
    col = Collection(libs_dir / "Fake.photoslibrary", Options())
    assert [lib.name for lib in col.libraries.values()] == ["Fake"]


def test_only_filter_and_missing_names(libs_dir):
    col = Collection(libs_dir, Options(), include=["fake"])  # case-insensitive
    assert [lib.name for lib in col.libraries.values()] == ["Fake"]
    with pytest.raises(ValueError, match="Libraries not found: nope"):
        Collection(libs_dir, Options(), include=["Fake", "Nope"])


def test_bad_paths(tmp_path):
    with pytest.raises(ValueError, match="Not found"):
        Collection(tmp_path / "missing", Options())
    (tmp_path / "empty").mkdir()
    with pytest.raises(ValueError, match="No Photos libraries"):
        Collection(tmp_path / "empty", Options())


def test_assets_sorted_newest_first_and_screenshots_hidden(libs_dir):
    lib = Library((libs_dir / "Fake.photoslibrary"), Options())
    assert lib.load_cached()
    assert [a.uuid for a in lib.assets] == ["P1", "P2", "MV", "LV"]
    assert "SS" not in lib.by_uuid


def test_screenshots_shown_when_enabled(libs_dir):
    lib = Library((libs_dir / "Fake.photoslibrary"), Options(show_screenshots=True))
    assert lib.load_cached()
    assert "SS" in lib.by_uuid


def test_albums_keep_only_visible_photos_and_drop_empty_ones(libs_dir):
    lib = Library((libs_dir / "Fake.photoslibrary"), Options())
    lib.load_cached()
    assert lib.albums == [{"title": "Trip", "uuids": ["P1"]}]


def test_person_avatar_dropped_when_its_photo_is_hidden(libs_dir):
    lib = Library((libs_dir / "Fake.photoslibrary"), Options())
    lib.load_cached()
    assert lib.people[0]["face"]["u"] == "P1"
    assert lib.people[1]["face"] is None  # its face photo is a hidden screenshot


def test_index_invalidated_when_database_changes(libs_dir):
    db = libs_dir / "Fake.photoslibrary" / "database" / "Photos.sqlite"
    db.write_bytes(b"changed by Photos")
    lib = Library((libs_dir / "Fake.photoslibrary"), Options())
    assert not lib.load_cached()


def test_index_invalidated_by_version_bump(libs_dir):
    lib = Library((libs_dir / "Fake.photoslibrary"), Options())
    index = lib.cache_dir / "index.json"
    data = json.loads(index.read_text())
    data["version"] = 0
    index.write_text(json.dumps(data))
    assert not lib.load_cached()


def test_available_follows_the_drive(libs_dir):
    path = libs_dir / "Fake.photoslibrary"
    lib = Library(path, Options())
    assert lib.available
    os.rename(path, libs_dir / "unplugged")
    assert not lib.available
    lib.ensure_open()  # must not try to index a missing library
    assert lib.state == "closed"


def test_relative_paths_stay_inside_library(tmp_path):
    path = build_library(tmp_path / "L.photoslibrary", assets=[], write_index=False)
    lib = Library(path, Options())
    assert lib._relative(str(path / "originals" / "A" / "x.jpg")) == "originals/A/x.jpg"
    assert lib.abs("originals/A/does-not-exist.jpg") is None
    assert lib.abs(None) is None


# ---- picking up changes made in Photos while sharing ---------------------------------

def _wait(cond, timeout=5.0):
    import time
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


@pytest.fixture
def opened(libs_dir, monkeypatch):
    """The Fake library loaded from cache, with osxphotos replaced by a stub index."""
    from conftest import ALBUMS, ASSETS, PEOPLE, asset
    lib = Library(libs_dir / "Fake.photoslibrary", Options())
    assert lib.load_cached()
    calls = []

    def fake_build():
        calls.append(1)
        new = [dict(a) for a in ASSETS] + [asset("NEW", "2025-01-01T10:00:00+00:00",
                                                 original="originals/P/P1.jpeg")]
        new[0]["edited"] = "resources/renders/P/P2_edited.jpeg"  # P1 was edited in Photos
        return {"fingerprint": lib._fingerprint(), "assets": new, "albums": ALBUMS,
                "people": PEOPLE}

    monkeypatch.setattr(lib, "_build_index", fake_build)
    return lib, calls


def _touch_db(lib):
    db = lib.path / "database" / "Photos.sqlite"
    db.write_bytes(db.read_bytes() + b"+")


def test_no_refresh_when_unchanged(opened):
    lib, calls = opened
    assert not lib.refresh_if_changed() and not lib.refresh_if_changed()
    assert calls == []


def test_refresh_waits_for_change_to_settle_then_reindexes(opened):
    lib, calls = opened
    rev = lib.rev
    for sub in ("thumb", "full"):  # cached previews of P1 from before the edit
        (lib.cache_dir / sub).mkdir(parents=True, exist_ok=True)
        (lib.cache_dir / sub / "P1.jpg").write_bytes(b"old")
        (lib.cache_dir / sub / "P2.jpg").write_bytes(b"unchanged")
    _touch_db(lib)
    assert not lib.refresh_if_changed()      # first sighting: wait
    _touch_db(lib)
    assert not lib.refresh_if_changed()      # still changing: wait again
    assert lib.refresh_if_changed()          # same as last check: re-index
    assert _wait(lambda: lib.rev == rev + 1 and not lib._refreshing)
    assert calls == [1]
    assert lib.assets[0].uuid == "NEW"       # newest first
    assert not (lib.cache_dir / "thumb" / "P1.jpg").exists()   # edited: preview dropped
    assert not (lib.cache_dir / "full" / "P1.jpg").exists()
    assert (lib.cache_dir / "thumb" / "P2.jpg").exists()       # untouched photo keeps it
    assert not lib.refresh_if_changed()      # now up to date


def test_failed_refresh_keeps_previous_index(opened, monkeypatch):
    lib, _ = opened
    before = [a.uuid for a in lib.assets]

    def boom():
        raise RuntimeError("database locked")

    monkeypatch.setattr(lib, "_build_index", boom)
    _touch_db(lib)
    lib.refresh_if_changed()
    assert lib.refresh_if_changed()
    assert _wait(lambda: not lib._refreshing)
    assert [a.uuid for a in lib.assets] == before and lib.state == "ready"


def test_unopened_or_unplugged_libraries_are_not_refreshed(opened, libs_dir):
    lib, calls = opened
    closed = Library(libs_dir / "Second.photoslibrary", Options())
    assert not closed.refresh_if_changed()
    os.rename(lib.path, libs_dir / "away")
    assert not lib.refresh_if_changed()
    assert calls == []


def test_collection_watch_thread(libs_dir, monkeypatch):
    col = Collection(libs_dir, Options())
    seen = []
    for lib in col.libraries.values():
        monkeypatch.setattr(lib, "refresh_if_changed", lambda lib=lib: seen.append(lib.name))
    stop = col.watch(0.05)
    assert _wait(lambda: {"Fake", "Second"} <= set(seen))
    stop.set()


def test_hidden_excluded_by_default_and_included_on_request(libs_dir):
    lib = Library(libs_dir / "Fake.photoslibrary", Options())
    lib.load_cached()
    assert "HD" not in lib.by_uuid
    assert lib.albums == [{"title": "Trip", "uuids": ["P1"]}]
    lib = Library(libs_dir / "Fake.photoslibrary", Options(show_hidden=True))
    lib.load_cached()
    assert lib.by_uuid["HD"].is_hidden and lib.assets[-1].uuid == "HD"
