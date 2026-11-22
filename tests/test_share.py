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


def test_tailscale_mode_needs_tailscale(libs_dir, monkeypatch):
    monkeypatch.setattr(share_mod, "tailscale_ip", lambda: None)
    with pytest.raises(ShareError, match="No Tailscale address"):
        Share(ShareConfig(path=libs_dir, mode="tailscale"))


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
