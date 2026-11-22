import os

import pytest


def test_index_and_static(client):
    assert client.get("/").status_code == 200
    r = client.get("/static/app.js")
    assert r.status_code == 200
    assert r.headers["cache-control"] == "no-cache"


def test_libraries_list(client):
    libs = {lib["name"]: lib for lib in client.get("/api/libraries").json()}
    assert libs["Fake"]["state"] == "ready" and libs["Fake"]["count"] == 4
    assert libs["Fake"]["cover"] == "P1" and libs["Fake"]["available"] is True
    assert libs["Fake"]["rev"] == 1
    assert libs["Second"]["state"] == "closed"


def test_library_payload(client, fake_id):
    data = client.get(f"/api/libraries/{fake_id}").json()
    assets = {a["u"]: a for a in data["assets"]}
    assert list(assets) == ["P1", "P2", "MV", "LV"]
    p1 = assets["P1"]
    assert p1["f"] is True and p1["k"] == "s" and p1["g"] == [44.43, 26.1]
    assert p1["pl"] == "Bucharest, Romania" and p1["p"] == [0]
    assert assets["P2"]["e"] is True and "f" not in assets["P2"]   # empty keys omitted
    assert assets["MV"]["m"] is True and assets["LV"]["l"] is True
    assert data["people"][0] == {"name": "Ana", "face": {"u": "P1", "x": 0.5, "y": 0.4, "s": 0.2},
                                 "count": 1}
    assert data["people"][1]["count"] == 0  # only appears on a hidden screenshot
    assert data["albums"] == [{"title": "Trip", "uuids": ["P1"]}]
    assert data["downloads"] is False and data["rev"] == 1


def test_unknown_library(client):
    assert client.get("/api/libraries/nope").status_code == 404


@pytest.mark.parametrize("kind", ["thumb", "photo"])
def test_images_are_jpeg(client, fake_id, kind):
    r = client.get(f"/{kind}/{fake_id}/P1")
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/jpeg"
    assert r.content[:2] == b"\xff\xd8"


def test_edited_version_is_used_for_full_photo(client, fake_id, libs_dir):
    client.get(f"/photo/{fake_id}/P2")
    # The rendition came from the edited file: removing the original changes nothing.
    os.remove(libs_dir / "Fake.photoslibrary" / "originals" / "P" / "P2.jpeg")
    assert client.get(f"/photo/{fake_id}/P2").status_code == 200


@pytest.mark.parametrize("path", [
    "/thumb/{id}/nope", "/photo/{id}/SS",                 # unknown, hidden screenshot
    "/thumb/{id}/..%2F..%2Fdatabase%2FPhotos.sqlite",     # traversal attempts
    "/static/..%2Flibrary.py", "/static/../library.py",
    "/video/{id}/P1",                                     # not a video
    "/live/{id}/P1",                                      # not a Live Photo
])
def test_not_found(client, fake_id, path):
    assert client.get(path.format(id=fake_id)).status_code == 404


def test_video_original_supports_range_requests(client, fake_id):
    assert client.get(f"/video-status/{fake_id}/MV").json() == {"state": "ready"}
    r = client.get(f"/video/{fake_id}/MV", headers={"Range": "bytes=0-99"})
    assert r.status_code == 206 and len(r.content) == 100


def test_live_photo_motion(client, fake_id):
    r = client.get(f"/live/{fake_id}/LV")
    assert r.status_code == 200 and r.content[4:8] == b"ftyp"


def test_downloads_off_by_default(client, fake_id):
    assert client.get(f"/original/{fake_id}/P1").status_code == 404


def test_downloads_use_original_filename(make_client, fake_id):
    client, _ = make_client(downloads=True)
    r = client.get(f"/original/{fake_id}/P1")
    assert r.status_code == 200
    assert 'filename="IMG_0001.JPG"' in r.headers["content-disposition"]


def test_download_gives_the_edited_version_when_there_is_one(make_client, fake_id):
    client, _ = make_client(downloads=True)
    r = client.get(f"/download/{fake_id}/P2")           # edited
    assert r.status_code == 200
    from urllib.parse import unquote
    assert unquote(r.headers["content-disposition"]).endswith("P2_edited (edited).jpeg")
    r = client.get(f"/download/{fake_id}/P1")           # not edited: the original
    assert 'filename="IMG_0001.JPG"' in r.headers["content-disposition"]
    off, _ = make_client()
    assert off.get(f"/download/{fake_id}/P1").status_code == 404


def test_screenshots_option(make_client, fake_id):
    client, _ = make_client(screenshots=True)
    assert client.get(f"/thumb/{fake_id}/SS").status_code == 200


def test_unplugged_drive(client, fake_id, libs_dir):
    assert client.get(f"/thumb/{fake_id}/P1").status_code == 200   # now cached
    os.rename(libs_dir / "Fake.photoslibrary", libs_dir / "away")
    os.rename(libs_dir / "Second.photoslibrary", libs_dir / "away2")
    libs = {lib["name"]: lib for lib in client.get("/api/libraries").json()}
    assert libs["Fake"]["available"] is False
    assert client.get(f"/api/libraries/{fake_id}").json()["available"] is False
    assert client.get(f"/thumb/{fake_id}/P1").status_code == 200   # served from cache
    assert client.get(f"/photo/{fake_id}/P2").status_code == 404   # never cached
    second = libs["Second"]["id"]
    r = client.get(f"/api/libraries/{second}")
    assert r.status_code == 503 and r.json()["state"] == "unavailable"
    os.rename(libs_dir / "away", libs_dir / "Fake.photoslibrary")
    assert client.get(f"/photo/{fake_id}/P2").status_code == 200   # back once plugged in


def test_hidden_photos_flagged_and_kept_out_of_people_counts(make_client, fake_id):
    client, _ = make_client(hidden=True)
    data = client.get(f"/api/libraries/{fake_id}").json()
    hd = next(a for a in data["assets"] if a["u"] == "HD")
    assert hd["hd"] is True
    assert all("hd" not in a for a in data["assets"] if a["u"] != "HD")
    assert data["people"][0]["count"] == 1      # Ana: P1 only, not the hidden HD
    assert client.get(f"/thumb/{fake_id}/HD").status_code == 200


def test_hidden_photos_unreachable_without_option(client, fake_id):
    assert client.get(f"/thumb/{fake_id}/HD").status_code == 404
