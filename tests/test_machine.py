"""The JSON interfaces the Swift app relies on."""

import json
import os
import signal
import subprocess
import sys
import time

import pytest

from photos_share import dedupe
from photos_share.dedupe import Item

from conftest import build_library
from test_share import free_port


# ---- photos-share --machine ---------------------------------------------------------

def start_share(libs, *extra, env=None):
    cmd = [sys.executable, "-c", "import photos_share; photos_share.main()", str(libs),
           "--machine", "--no-keep-awake", "--refresh", "0", *extra]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            env={**os.environ, **(env or {})})


def next_event(proc, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        line = proc.stdout.readline()
        if line:
            return json.loads(line)
        if proc.poll() is not None:
            break
    raise AssertionError("no event; stderr: " + proc.stderr.read())


def test_machine_ready_then_stopped(libs_dir, cache_root):
    port = free_port()
    p = start_share(libs_dir, "--port", str(port), env={"HOME": str(cache_root.parent)})
    try:
        ev = next_event(p)
        assert ev == {"event": "ready", "url": f"http://127.0.0.1:{port}", "libraries": 2}
        p.send_signal(signal.SIGTERM)
        assert next_event(p) == {"event": "stopped"}
        assert p.wait(10) == 0
    finally:
        p.kill()


def test_machine_reports_errors(libs_dir, tmp_path, cache_root):
    p = start_share(tmp_path / "nope")
    assert next_event(p)["event"] == "error" and p.wait(10) == 1
    p = start_share(libs_dir, "--password", env={"PHOTOS_SHARE_PASSWORD": ""})
    ev = next_event(p)
    assert ev["event"] == "error" and "password" in ev["message"]


def test_machine_port_in_use(libs_dir, cache_root):
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        s.listen()
        port = s.getsockname()[1]
        p = start_share(libs_dir, "--port", str(port), env={"HOME": str(cache_root.parent)})
        events = [next_event(p), next_event(p)]
    assert events[0]["event"] == "error" and "port" in events[0]["message"]
    assert events[1] == {"event": "stopped"} and p.wait(10) == 1


# ---- photos-dedupe --json -------------------------------------------------------------

def item(uuid, fp, edited=False):
    return Item(uuid=uuid, fingerprint=fp, filename=f"{uuid.lower()}.heic", size=10,
                date="2024-01-01T10:00:00+00:00", edited=edited)


@pytest.fixture
def two_libs(tmp_path, monkeypatch):
    src = build_library(tmp_path / "Src.photoslibrary", assets=[], write_index=False)
    dst = build_library(tmp_path / "Dst.photoslibrary", assets=[], write_index=False)
    for lib, uuid in ((src, "A"), (dst, "E9")):
        d = lib / "resources" / "derivatives" / "masters" / uuid[0]
        d.mkdir(parents=True)
        (d / f"{uuid}_4_5005_c.jpeg").write_bytes(b"jpg")
    data = {src: [item("A", "f1"), item("B", "f2", edited=True), item("C", "f3")],
            dst: [item("E9", "f1"), item("E8", "f2")]}
    monkeypatch.setattr(dedupe, "load", lambda p: data[p])
    monkeypatch.setattr(dedupe, "system_library", lambda: None)
    return src, dst


def test_dedupe_json(two_libs, capsys):
    src, dst = two_libs
    dedupe.main([str(src), str(dst), "--json"])
    out = json.loads(capsys.readouterr().out)
    assert (out["source_name"], out["dest_name"], out["total"]) == ("Src", "Dst", 3)
    assert out["all_verified"] is False and out["source_is_system"] is False
    a = out["matched"][0]
    assert (a["uuid"], a["dest"], a["how"]) == ("A", "E9", "fingerprint")
    assert a["thumb"].endswith("A_4_5005_c.jpeg") and a["dest_thumb"].endswith("E9_4_5005_c.jpeg")
    assert [i["uuid"] for i in out["edit_lost"]] == ["B"]
    assert [i["uuid"] for i in out["missing"]] == ["C"] and out["missing"][0]["dest"] is None
    assert out["outcome"] is None


def test_dedupe_json_errors_are_json(two_libs, capsys):
    src, dst = two_libs
    with pytest.raises(SystemExit):
        dedupe.main([str(src), str(src), "--json"])
    assert "same library" in json.loads(capsys.readouterr().out)["error"]
    with pytest.raises(SystemExit):
        dedupe.main([str(src), str(dst), "--json", "--delete"])   # no --yes
    assert "--yes" in json.loads(capsys.readouterr().out)["error"]
    with pytest.raises(SystemExit):                                # refused action
        dedupe.main([str(src), str(dst), "--json", "--trash-library", "--yes"])
    assert "Not every photo" in json.loads(capsys.readouterr().out)["error"]


def test_thumbnail_map_prefers_small_previews(tmp_path):
    lib = tmp_path / "L.photoslibrary"
    (lib / "resources/derivatives/A").mkdir(parents=True)
    (lib / "resources/derivatives/masters/A").mkdir(parents=True)
    (lib / "resources/derivatives/A/AB_1_105_c.jpeg").write_bytes(b"x")
    (lib / "resources/derivatives/A/AC_1_105_c.jpeg").write_bytes(b"x")
    (lib / "resources/derivatives/masters/A/AB_4_5005_c.jpeg").write_bytes(b"x")
    m = dedupe.thumbnail_map(lib)
    assert m["AB"].endswith("masters/A/AB_4_5005_c.jpeg") and m["AC"].endswith("AC_1_105_c.jpeg")
