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
