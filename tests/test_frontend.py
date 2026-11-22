"""Runs static/app.js under macOS's JavaScriptCore with a tiny DOM shim (no browser needed)."""

import json
import subprocess
from pathlib import Path

import pytest

JSC = Path("/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc")
HERE = Path(__file__).parent / "frontend"
APP_JS = Path(__file__).parents[1] / "src" / "photos_share" / "static" / "app.js"

pytestmark = pytest.mark.skipif(not JSC.exists(), reason="JavaScriptCore jsc not available")


def a(u, d, **kw):
    return {"u": u, "d": d, "w": 4032, "h": 3024, "m": False, "l": False, "e": False, **kw}


LIBRARY = {
    "id": "abc", "name": "Test", "state": "ready", "available": True, "downloads": True, "rev": 1,
    "assets": [
        a("U1", "2024-05-02T10:00:00+01:00", f=True, g=[44.4, 26.1], pl="Bucharest, Romania", p=[0]),
        a("U2", "2024-05-01T09:00:00+01:00", k="s", p=[0]),
        a("U3", "2024-04-10T09:00:00+01:00", m=True),
        a("U4", "2023-12-24T20:00:00+01:00", l=True, f=True),
        a("U5", "2023-08-01T12:00:00+01:00", e=True),
        a("U6", "2023-08-02T12:00:00+01:00"),
        a("H1", "2023-08-03T12:00:00+01:00", hd=True, f=True, p=[0]),
    ],
    "albums": [{"title": "Trip", "uuids": ["U1", "U2", "H1"]}],
    "people": [{"name": "Ana", "face": {"u": "U1", "x": 0.5, "y": 0.4, "s": 0.1}, "count": 2},
               {"name": "Nobody", "face": None, "count": 0}],
}
# rev 2 > the library's rev 1: the page should offer "New photos".
LIBRARIES = [{"id": "abc", "name": "Test", "state": "ready", "available": True, "count": 6, "rev": 2,
              "cover": "U1", "first": "2023-08-01", "last": "2024-05-02"},
             {"id": "x", "name": "Other", "state": "closed", "available": False}]


def test_app_js_scenarios(tmp_path):
    (tmp_path / "libs.json").write_text(json.dumps(LIBRARIES))
    (tmp_path / "lib.json").write_text(json.dumps(LIBRARY))
    script = tmp_path / "run.js"
    script.write_text("\n".join(p.read_text() for p in
                                (HERE / "dom_shim.js", APP_JS, HERE / "scenario.js")))
    out = subprocess.run([str(JSC), str(script), "--", str(tmp_path / "libs.json"),
                          str(tmp_path / "lib.json")], capture_output=True, text=True, timeout=60)
    lines = out.stdout.splitlines()
    assert "DONE" in lines, out.stdout + out.stderr
    failures = [line for line in lines if line.startswith("FAIL")]
    assert not failures, "\n".join(failures)
    assert sum(line.startswith("ok ") for line in lines) >= 25
