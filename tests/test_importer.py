import json
import sys
import types
from datetime import datetime, timezone
from pathlib import Path

import pytest

from photos_share import importer


def adj(*ops):
    return types.SimpleNamespace(adjustments=[{"identifier": o} for o in ops])


def photo(uuid, name=None, edited_ops=None, **kw):
    base = dict(uuid=uuid, original_filename=name or f"IMG_{uuid}.HEIC",
                hasadjustments=edited_ops is not None, adjustments=adj(*(edited_ops or [])),
                date=datetime(2024, 5, 1, 10, 0, tzinfo=timezone.utc), ismovie=False,
                live_photo=False, favorite=False, hidden=False, albums=[], title=None,
                description=None, keywords=[], location=(None, None), fingerprint=f"fp-{uuid}",
                original_filesize=100, path=f"/lib/{uuid}.heic", path_live_photo=None,
                has_raw=False, path_raw=None)
    return types.SimpleNamespace(**{**base, **kw})


# ---- what counts as an edit ------------------------------------------------------------

@pytest.mark.parametrize("ops,real", [
    (None, False), (["DepthEffect"], False), (["PortraitEffect", "Orientation"], False),
    (["Crop"], True), (["DepthEffect", "SmartTone"], True), ([], True),  # undecoded → real
])
def test_has_real_edit(ops, real):
    assert importer.has_real_edit(photo("A", edited_ops=ops)) is real


# ---- batching ------------------------------------------------------------------------

def test_batches_respect_size_and_unique_filenames():
    ps = [photo(str(i)) for i in range(120)]
    assert [len(b) for b in importer.batches(ps, 50)] == [50, 50, 20]
    dup = [photo("1", "IMG_1.HEIC"), photo("2", "img_1.heic"), photo("3", "IMG_3.HEIC")]
    assert [[p.uuid for p in b] for b in importer.batches(dup)] == [["1"], ["2", "3"]]


# ---- exporting -----------------------------------------------------------------------

@pytest.fixture
def exports(monkeypatch, tmp_path):
    calls = []

    class Exporter:
        def __init__(self, p):
            self.p = p

        def export(self, folder, options):
            calls.append((self.p.uuid, options.edited, options.live_photo, options.raw_photo,
                          options.export_aae))
            stem = f"{self.p.uuid}{'_edited' if options.edited else ''}"
            return types.SimpleNamespace(exported=[f"{folder}/{stem}.heic", f"{folder}/{stem}.AAE"])

    import osxphotos.photoexporter as pe
    monkeypatch.setattr(pe, "PhotoExporter", Exporter)
    return calls


@pytest.mark.parametrize("mode,expect", [
    ("skip", []), ("flatten", [True]), ("both", [False, True])])
def test_export_modes_for_edited_photos(exports, tmp_path, mode, expect):
    files = importer.export_photo(photo("E", edited_ops=["Crop"]), tmp_path, mode)
    assert [c[1] for c in exports] == expect
    assert all(c[2] and c[3] and not c[4] for c in exports)  # live+raw on, never AAE
    assert not any(f.suffix.lower() == ".aae" for f in files)


def test_unedited_photo_exports_original_only(exports, tmp_path):
    importer.export_photo(photo("U", edited_ops=["DepthEffect"]), tmp_path, "flatten")
    assert [c[1] for c in exports] == [False]


# ---- carrying details across -----------------------------------------------------------

class Imported:
    def __init__(self, name="IMG_A.HEIC", **kw):
        self.filename, self.favorite, self.title, self.description = name, False, None, None
        self.keywords, self.location = [], (None, None)
        self.date = datetime(2024, 5, 1, 12, 0)
        self.__dict__.update(kw)


class FakeAlbum:
    def __init__(self, name):
        self.name, self.added = name, []

    def add(self, photos):
        self.added += photos


class FakeLibrary:
    def __init__(self, existing=()):
        self.albums = {n: FakeAlbum(n) for n in existing}
        self.created = []

    def album(self, name, top_level=False):
        return self.albums.get(name)

    def create_album(self, name):
        self.created.append(name)
        self.albums[name] = FakeAlbum(name)
        return self.albums[name]


def test_apply_details():
    src = photo("A", favorite=True, title="Beach", description="Day one", keywords=["sea"],
                location=(44.4, 26.1), albums=["Trip", "Best"])
    imp = Imported()
    lib = FakeLibrary(existing=["Best"])
    importer.apply_details(imp, src, {}, lib)
    assert (imp.favorite, imp.title, imp.description, imp.keywords) == (True, "Beach", "Day one", ["sea"])
    assert imp.location == (44.4, 26.1)
    assert imp.date == src.date.astimezone().replace(tzinfo=None)  # adjusted date carried
    assert lib.created == ["Trip"]                                  # only missing albums made
    assert lib.albums["Trip"].added == [imp] and lib.albums["Best"].added == [imp]


def test_apply_details_leaves_matching_values_alone():
    src = photo("A")
    imp = Imported(date=src.date.astimezone().replace(tzinfo=None))
    before = dict(imp.__dict__)
    importer.apply_details(imp, src, {}, FakeLibrary())
    assert imp.__dict__ == before


# ---- a whole run, with Photos and osxphotos faked ---------------------------------------

def test_run_import(monkeypatch, tmp_path):
    src_photos = [photo("A", favorite=True), photo("B"), photo("E", edited_ops=["Crop"]),
                  photo("M"), photo("X")]
    monkeypatch.setattr(importer, "_photos", lambda p: src_photos)
    monkeypatch.setattr(importer, "_wait_for_library", lambda p: None)

    def fake_export(p, folder, mode):
        if p.uuid == "M":
            return []  # original missing
        f = folder / p.original_filename
        f.write_bytes(b"x")
        return [f]
    monkeypatch.setattr(importer, "export_photo", fake_export)

    staged_dirs, opened = [], []

    class Lib(FakeLibrary):
        def open(self, path):
            opened.append(path)

        def import_photos(self, paths, skip_duplicate_check=False):
            assert skip_duplicate_check is True     # a duplicate dialog would hang scripting
            staged_dirs.append(Path(paths[0]).parent)
            return [Imported(Path(x).name) for x in paths]

    monkeypatch.setitem(sys.modules, "photoscript", types.SimpleNamespace(PhotosLibrary=Lib))
    events = []
    out = importer.run_import(Path("/s.photoslibrary"), Path("/d.photoslibrary"),
                              ["A", "B", "E", "M"], "skip",
                              emit=lambda e, **d: events.append((e, d)))
    assert out["imported"] == 2 and out["requested"] == 3
    assert [s["uuid"] for s in out["skipped_edited"]] == ["E"]
    assert out["failed"] == [{"uuid": "M", "name": "IMG_M.HEIC", "reason": "the original file is missing"}]
    assert opened == ["/d.photoslibrary"]
    assert all(not d.exists() for d in staged_dirs)           # temp files removed
    assert events[0] == ("start", {"total": 3, "skipped_edited": 1})
    assert events[-1][0] == "done"


def test_plan(monkeypatch, tmp_path):
    from photos_share import dedupe
    src = [photo("A"), photo("B", edited_ops=["Crop"]), photo("H", hidden=True),
           photo("P", edited_ops=["DepthEffect"], albums=["Trip"])]
    dst = [photo("Z", fingerprint="fp-A")]  # A was imported already
    monkeypatch.setattr(importer, "_photos", lambda p: src if p.name == "s.photoslibrary" else dst)
    monkeypatch.setattr(dedupe, "thumbnail_map", lambda p: {"A": "/t/a.jpg"})
    out = importer.plan(Path("s.photoslibrary"), Path("d.photoslibrary")).to_json()
    items = {i["uuid"]: i for i in out["items"]}
    assert set(items) == {"A", "B", "P"}                      # hidden left out by default
    assert items["A"]["in_dest"] and not items["B"]["in_dest"]
    assert items["B"]["edited"] and not items["P"]["edited"]  # portrait effect isn't an edit
    assert items["A"]["thumb"] == "/t/a.jpg" and out["albums"] == ["Trip"]
    assert items["A"]["original"] == "/lib/A.heic"            # for the large preview
    with_hidden = importer.plan(Path("s.photoslibrary"), Path("d.photoslibrary"), True)
    assert "H" in {c.uuid for c in with_hidden.items}


def test_cli_plan_json(monkeypatch, tmp_path, capsys):
    from conftest import build_library
    s = build_library(tmp_path / "S.photoslibrary", assets=[], write_index=False)
    d = build_library(tmp_path / "D.photoslibrary", assets=[], write_index=False)
    monkeypatch.setattr(importer, "plan", lambda a, b, include_hidden=False: importer.Plan(a, b))
    importer.main([str(s), str(d), "--plan", "--json"])
    out = json.loads(capsys.readouterr().out)
    assert (out["source_name"], out["dest_name"], out["items"]) == ("S", "D", [])
    with pytest.raises(SystemExit):
        importer.main([str(s), str(s), "--plan", "--json"])
    assert "same library" in json.loads(capsys.readouterr().out)["message"]


# ---- keeping edits: parts, checks, finishing ----------------------------------------------

@pytest.fixture
def lib(tmp_path):
    root = tmp_path / "S.photoslibrary"
    (root / "resources" / "renders" / "A").mkdir(parents=True)
    return root


def files_photo(lib, uuid="A1", edited=False, live=False, movie=False, render_ext=None, **kw):
    """A fake photo whose files exist on disk, like a real library."""
    def make(name):
        f = lib / "originals" / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b"x" * 10)
        return str(f)
    p = photo(uuid, edited_ops=["Crop"] if edited else None, ismovie=movie,
              path=make(f"{uuid}.{'mov' if movie else 'heic'}"),
              live_photo=live, path_live_photo=make(f"{uuid}_live.mov") if live else None,
              path_edited=None, path_edited_live_photo=None, adjustments_path=None,
              _db=types.SimpleNamespace(library_path=str(lib)), **kw)
    if edited:
        p.adjustments_path = Path(make(f"{uuid}.plist"))  # osxphotos gives a Path here
        render = lib / "resources" / "renders" / uuid[0] / f"{uuid}_{'2_0' if movie else '1_201'}_a.{render_ext or ('mov' if movie else 'heic')}"
        render.write_bytes(b"e")
        if live:
            (lib / "resources" / "renders" / uuid[0] / f"{uuid}_2_100_a.mov").write_bytes(b"l")
    return p


def test_parts_unedited_and_live(lib):
    files, why = importer.parts(files_photo(lib, live=True))
    assert why is None and [f["type"] for f in files] == ["photo", "pairedVideo"]


def test_parts_edited_live_finds_renders_osxphotos_misses(lib):
    # HEIC original whose edit Photos saved as JPEG: osxphotos' path_edited is None
    p = files_photo(lib, edited=True, live=True, render_ext="jpeg")
    files, why = importer.parts(p)
    assert why is None
    assert [f["type"] for f in files] == ["photo", "pairedVideo", "adjustmentData",
                                          "fullSizePhoto", "fullSizePairedVideo"]
    assert files[3]["path"].endswith("_1_201_a.jpeg")
    assert files[4].get("optional") is True
    assert all(isinstance(f["path"], str) for f in files)  # JSON-safe


def test_parts_edited_video(lib):
    files, _ = importer.parts(files_photo(lib, edited=True, movie=True))
    assert [f["type"] for f in files] == ["video", "adjustmentData", "fullSizeVideo"]


def test_parts_reasons(lib):
    p = files_photo(lib, edited=True)
    for f in (lib / "resources" / "renders" / "A").iterdir():
        f.unlink()
    assert importer.parts(p) == ([], "Photos hasn’t saved its edited version (open it in Edit and click Done)")
    p.path = "/missing.heic"
    assert importer.parts(p)[1] == "the original file isn’t in the library"


def test_manifest(monkeypatch, lib):
    ok = files_photo(lib, "A1", favorite=True, albums=["Trip", None], location=(1.0, 2.0))
    broken = files_photo(lib, "A2", edited=True)
    for f in (lib / "resources" / "renders" / "A").iterdir():
        f.unlink()
    monkeypatch.setattr(importer, "_photos", lambda p: [ok, broken, files_photo(lib, "A3")])
    out = importer.manifest(lib, ["A1", "A2"])
    assert [i["source_uuid"] for i in out["items"]] == ["A1"]
    item = out["items"][0]
    assert (item["favorite"], item["albums"], item["lat"], item["lon"]) == (True, ["Trip"], 1.0, 2.0)
    assert [p["uuid"] for p in out["problems"]] == ["A2"]
    json.dumps(out)


def test_compare(lib):
    s = files_photo(lib, "A1", edited=True, live=True)
    same = types.SimpleNamespace(**{**s.__dict__})
    assert importer.compare(s, same) == []
    lost = types.SimpleNamespace(**{**s.__dict__, "hasadjustments": False, "live_photo": False})
    assert importer.compare(s, lost) == ["Live Photo video", "the edit"]


def test_finish(monkeypatch, lib):
    a = files_photo(lib, "A1", title="Beach", keywords=["sea"])
    b = files_photo(lib, "A2", edited=True)
    made_a = types.SimpleNamespace(**{**a.__dict__, "uuid": "D1"})
    made_b = types.SimpleNamespace(**{**b.__dict__, "uuid": "D2", "hasadjustments": False})
    monkeypatch.setattr(importer, "_photos",
                        lambda p: [a, b] if p.name == "S.photoslibrary" else [made_a, made_b])
    monkeypatch.setattr(importer, "_wait_for_library", lambda p: None)
    set_on = {}

    class Photo:
        def __init__(self, uuid):
            self.uuid = uuid

        def __setattr__(self, k, v):
            set_on.setdefault(self.__dict__.get("uuid"), {})[k] = v
            object.__setattr__(self, k, v)

    opened = []
    monkeypatch.setitem(sys.modules, "photoscript", types.SimpleNamespace(
        Photo=Photo, PhotosLibrary=lambda: types.SimpleNamespace(open=opened.append)))
    run = {"requested": 3,
           "created": [{"source_uuid": "A1", "created": "D1/L0/001"},
                       {"source_uuid": "A2", "created": "D2/L0/001"}],
           "failed": [{"uuid": "A3", "name": "IMG_A3.HEIC", "reason": "Photos refused it"}]}
    events = []
    out = importer.finish(lib, lib.with_name("D.photoslibrary"), run,
                          emit=lambda e, **d: events.append((e, d)))
    assert out["imported"] == 2 and out["requested"] == 3
    reasons = {f["uuid"]: f["reason"] for f in out["failed"]}
    assert reasons == {"A3": "Photos refused it", "A2": "imported, but differs: the edit"}
    assert set_on["D1"] == {"title": "Beach", "keywords": ["sea"]}
    assert opened == [str(lib.with_name("D.photoslibrary"))]
    assert events[-1][0] == "done"


def test_finish_without_details_never_opens_photos(monkeypatch, lib):
    a = files_photo(lib, "A1")
    monkeypatch.setattr(importer, "_photos", lambda p: [a] if p.name == "S.photoslibrary"
                        else [types.SimpleNamespace(**{**a.__dict__, "uuid": "D1"})])
    monkeypatch.setitem(sys.modules, "photoscript", None)  # importing it would fail
    out = importer.finish(lib, lib.with_name("D.photoslibrary"),
                          {"created": [{"source_uuid": "A1", "created": "D1/L0/001"}]})
    assert out["failed"] == [] and out["imported"] == 1


def test_plan_says_whether_dest_is_system(monkeypatch, tmp_path):
    from photos_share import dedupe
    monkeypatch.setattr(dedupe, "system_library", lambda: (tmp_path / "D.photoslibrary").resolve())
    assert importer.Plan(tmp_path / "S.photoslibrary", tmp_path / "D.photoslibrary").to_json()["dest_is_system"]
    assert not importer.Plan(tmp_path / "D.photoslibrary", tmp_path / "S.photoslibrary").to_json()["dest_is_system"]
