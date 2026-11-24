import os
import socket
import subprocess
import time
import urllib.request

import pytest

import photos_share.share as share_mod
from photos_share.share import Share, ShareConfig, ShareError


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def get(url):
    try:
        return urllib.request.urlopen(url, timeout=2).status
    except Exception as e:  # noqa: BLE001
        return type(e).__name__


def my_caffeinate() -> list[str]:
    out = subprocess.run(["pgrep", "-fl", "caffeinate"], capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if f"-w {os.getpid()}" in line]


def test_funnel_requires_a_long_password(libs_dir):
    for pw in (None, "short"):
        with pytest.raises(ShareError, match="at least 8"):
            Share(ShareConfig(path=libs_dir, mode="funnel", password=pw))


@pytest.mark.parametrize("state, says", [
    (None, "isn't installed"), ("NotRunning", "isn't running"), ("Stopped", "switched off"),
    ("NeedsLogin", "sign in"), ("Starting", "didn't connect")])
def test_tailscale_mode_needs_tailscale(libs_dir, monkeypatch, state, says):
    monkeypatch.setattr(share_mod, "TAILSCALE_WAIT", 0)
    monkeypatch.setattr(share_mod, "tailscale_ip", lambda: None)
    monkeypatch.setattr(share_mod, "tailscale_state", lambda: state)
    with pytest.raises(ShareError, match=says):
        Share(ShareConfig(path=libs_dir, mode="tailscale"))


def test_tailscale_mode_waits_for_tailscale_to_connect(libs_dir, monkeypatch):
    answers = iter([None, None, "100.101.102.103"])
    monkeypatch.setattr(share_mod, "tailscale_ip", lambda: next(answers))
    monkeypatch.setattr(share_mod, "tailscale_name", lambda: None)
    monkeypatch.setattr(share_mod.time, "sleep", lambda _: None)
    s = Share(ShareConfig(path=libs_dir, mode="tailscale", port=8123))
    assert s.host == "100.101.102.103"


def test_tailscale_mode_binds_tailscale_address(libs_dir, monkeypatch):
    monkeypatch.setattr(share_mod, "tailscale_ip", lambda: "100.101.102.103")
    monkeypatch.setattr(share_mod, "tailscale_name", lambda: "mac.tail1234.ts.net")
    s = Share(ShareConfig(path=libs_dir, mode="tailscale", port=8123))
    assert (s.host, s.url) == ("100.101.102.103", "http://mac.tail1234.ts.net:8123")


def test_funnel_mode_listens_locally_only(libs_dir, monkeypatch):
    monkeypatch.setattr(share_mod, "tailscale_cli", lambda: "/usr/bin/true")
    monkeypatch.setattr(share_mod, "tailscale_name", lambda: "mac.tail1234.ts.net")
    s = Share(ShareConfig(path=libs_dir, mode="funnel", password="long-enough"))
    assert (s.host, s.url) == ("127.0.0.1", "https://mac.tail1234.ts.net")


def test_bad_library_path(tmp_path):
    with pytest.raises(ShareError, match="Not found"):
        Share(ShareConfig(path=tmp_path / "missing"))


def test_start_stop_restart_and_keep_awake(libs_dir):
    port = free_port()
    s = Share(ShareConfig(path=libs_dir, port=port, keep_awake=True))
    s.start_background()
    try:
        assert get(f"http://127.0.0.1:{port}/api/libraries") == 200
        assert my_caffeinate(), "caffeinate should run while sharing"
        with pytest.raises(ShareError, match="already running"):
            Share(ShareConfig(path=libs_dir, port=port)).start_background()
    finally:
        s.stop()
    time.sleep(0.2)
    assert get(f"http://127.0.0.1:{port}/api/libraries") != 200
    assert not my_caffeinate()

    s2 = Share(ShareConfig(path=libs_dir, port=port, keep_awake=False))
    s2.start_background()
    try:
        assert get(f"http://127.0.0.1:{port}/api/libraries") == 200
        assert not my_caffeinate()
    finally:
        s2.stop()


# ---- starting Funnel: Tailscale's output is read (with a stand-in `tailscale` command) ----

def _fake_tailscale(tmp_path, script: str) -> str:
    cli = tmp_path / "tailscale"
    cli.write_text("#!/bin/sh\n" + script + "\n")
    cli.chmod(0o755)
    return str(cli)


def _funnel_share():
    import types
    return types.SimpleNamespace(cfg=types.SimpleNamespace(mode="funnel", port=8080), _funnel=None)


@pytest.mark.parametrize("script,ok,expect", [
    ('echo "Available on the internet:"; echo "https://mac.tailnet.ts.net/"; sleep 30', True, None),
    ('echo "Funnel is not enabled on your tailnet."; echo "To enable, visit:";'
     ' echo "  https://login.tailscale.com/f/funnel?node=abc"; sleep 30', False,
     "https://login.tailscale.com/f/funnel?node=abc"),
    ('echo "error: serve config denied" >&2; exit 1', False, "serve config denied"),
])
def test_start_funnel_reads_tailscale(monkeypatch, tmp_path, script, ok, expect):
    from photos_share import share
    monkeypatch.setattr(share, "tailscale_cli", lambda: _fake_tailscale(tmp_path, script))
    s = _funnel_share()
    if ok:
        share.Share.start_funnel(s, wait=3)
        assert s._funnel is not None and s._funnel.poll() is None
        s._funnel.terminate()
    else:
        with pytest.raises(share.ShareError) as e:
            share.Share.start_funnel(s, wait=3)
        assert expect in str(e.value)
        assert s._funnel is None
