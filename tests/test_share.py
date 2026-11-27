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
    ("NotRunning", "isn't running"), ("Stopped", "switched off"),
    ("NeedsLogin", "sign in"), ("Starting", "didn't connect")])
@pytest.mark.parametrize("mode", ["tailscale", "funnel"])
def test_tailscale_modes_need_tailscale(libs_dir, monkeypatch, mode, state, says):
    monkeypatch.setattr(share_mod, "TAILSCALE_WAIT", 0)
    monkeypatch.setattr(share_mod, "tailscale_cli", lambda: "/usr/bin/true")
    monkeypatch.setattr(share_mod, "tailscale_name", lambda: None)
    monkeypatch.setattr(share_mod, "tailscale_state", lambda: state)
    with pytest.raises(ShareError, match=says):
        Share(ShareConfig(path=libs_dir, mode=mode, password="long-enough"))


def test_tailscale_mode_without_tailscale(libs_dir, monkeypatch):
    monkeypatch.setattr(share_mod, "tailscale_cli", lambda: None)
    with pytest.raises(ShareError, match="wasn't found"):
        Share(ShareConfig(path=libs_dir, mode="tailscale"))


def test_tailscale_mode_waits_for_tailscale_to_connect(libs_dir, monkeypatch):
    answers = iter([None, None, "mac.tail1234.ts.net"])
    monkeypatch.setattr(share_mod, "tailscale_cli", lambda: "/usr/bin/true")
    monkeypatch.setattr(share_mod, "tailscale_name", lambda: next(answers))
    monkeypatch.setattr(share_mod.time, "sleep", lambda _: None)
    s = Share(ShareConfig(path=libs_dir, mode="tailscale", port=8123))
    assert s.url == "https://mac.tail1234.ts.net"


@pytest.mark.parametrize("mode", ["tailscale", "funnel"])
def test_tailscale_modes_listen_locally_behind_https(libs_dir, monkeypatch, mode):
    # Private (tailscale serve) and public (tailscale funnel) alike: https in front, the server
    # reachable only from this Mac, and an https-only sign-in cookie.
    monkeypatch.setattr(share_mod, "tailscale_cli", lambda: "/usr/bin/true")
    monkeypatch.setattr(share_mod, "tailscale_name", lambda: "mac.tail1234.ts.net")
    s = Share(ShareConfig(path=libs_dir, mode=mode, password="long-enough", port=8123))
    assert (s.host, s.url) == ("127.0.0.1", "https://mac.tail1234.ts.net")
    assert s.auth.secure_cookie


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


# ---- starting serve / Funnel: Tailscale's output is read (with a stand-in `tailscale`) ----

def _fake_tailscale(tmp_path, script: str) -> str:
    cli = tmp_path / "tailscale"
    cli.write_text("#!/bin/sh\n" + 'echo "$@" > "$(dirname "$0")/args"\n' + script + "\n")
    cli.chmod(0o755)
    return str(cli)


def _share(mode):
    import types
    return types.SimpleNamespace(cfg=types.SimpleNamespace(mode=mode, port=8080), _proxy=None)


@pytest.mark.parametrize("mode,script,ok,expect", [
    ("funnel", 'echo "Available on the internet:"; echo "https://mac.tailnet.ts.net/"; sleep 30', True, None),
    ("tailscale", 'echo "Available within your tailnet:"; echo "https://mac.tailnet.ts.net/"; sleep 30',
     True, None),
    ("funnel", 'echo "Funnel is not enabled on your tailnet."; echo "To enable, visit:";'
     ' echo "  https://login.tailscale.com/f/funnel?node=abc"; sleep 30', False,
     "https://login.tailscale.com/f/funnel?node=abc"),
    ("tailscale", 'echo "Serve is not enabled on your tailnet."; echo "To enable, visit:";'
     ' echo "  https://login.tailscale.com/f/serve?node=abc"; sleep 30', False,
     "Tailscale HTTPS isn’t enabled for this Mac yet"),
    ("funnel", 'echo "error: serve config denied" >&2; exit 1', False, "serve config denied"),
])
def test_start_proxy_reads_tailscale(monkeypatch, tmp_path, mode, script, ok, expect):
    from photos_share import share
    monkeypatch.setattr(share, "tailscale_cli", lambda: _fake_tailscale(tmp_path, script))
    s = _share(mode)
    if ok:
        share.Share.start_proxy(s, wait=3)
        assert s._proxy is not None and s._proxy.poll() is None
        s._proxy.terminate()
        command = "serve" if mode == "tailscale" else "funnel"
        assert (tmp_path / "args").read_text().split() == [command, "8080"]
    else:
        with pytest.raises(share.ShareError) as e:
            share.Share.start_proxy(s, wait=3)
        assert expect in str(e.value)
        assert s._proxy is None


def test_tailscale_name_tries_every_tool(monkeypatch):
    # A Homebrew `tailscale` on the PATH that can't reach the running app, then the app's own.
    monkeypatch.setattr(share_mod, "tailscale_clis", lambda: ["/opt/homebrew/bin/tailscale", "/app"])
    answers = {"/opt/homebrew/bin/tailscale": (None, "failed to connect to local tailscaled"),
               "/app": ({"BackendState": "Running", "Self": {"DNSName": "mac.tail1.ts.net."}}, "")}
    monkeypatch.setattr(share_mod, "_status", lambda cli: answers[cli])
    assert share_mod.tailscale_name() == "mac.tail1.ts.net"
    assert share_mod.tailscale_cli() == "/app"
    assert share_mod.tailscale_state() == "Running"
