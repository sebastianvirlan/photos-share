"""Start/stop a share: libraries + web server + (optionally) Tailscale. Used by CLI and app."""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import subprocess
import time
import threading
from dataclasses import dataclass, field
from pathlib import Path

TAILSCALE_NET = ipaddress.ip_network("100.64.0.0/10")
TAILSCALE_APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
MIN_FUNNEL_PASSWORD = 8
FUNNEL_WAIT = 8.0   # seconds to watch Tailscale's output when starting Funnel
MODES = ("local", "tailscale", "funnel")


class ShareError(Exception):
    """A problem the user can fix; the message is shown as-is."""


@dataclass
class ShareConfig:
    path: Path
    only: list[str] = field(default_factory=list)
    screenshots: bool = False
    hidden: bool = False        # include Photos' Hidden album (shown separately)
    video: str = "original"     # original | convert
    downloads: bool = False
    password: str | None = None
    mode: str = "local"         # local | tailscale | funnel
    host: str = "127.0.0.1"     # used in local mode only
    port: int = 8080
    keep_awake: bool = True     # stop the Mac idle-sleeping while sharing
    refresh: float = 60         # seconds between library change checks; 0 = never


class Share:
    def __init__(self, cfg: ShareConfig):
        from .auth import Auth
        from .library import Collection, Options

        if cfg.mode not in MODES:
            raise ShareError(f"Unknown mode: {cfg.mode}")
        if cfg.mode == "funnel" and len(cfg.password or "") < MIN_FUNNEL_PASSWORD:
            raise ShareError("A public link needs a password of at least "
                             f"{MIN_FUNNEL_PASSWORD} characters.")
        self.cfg = cfg
        try:
            self.collection = Collection(cfg.path, Options(show_screenshots=cfg.screenshots, show_hidden=cfg.hidden),
                                         cfg.only or None)
        except ValueError as e:
            raise ShareError(str(e)) from e
        except PermissionError as e:
            raise ShareError(
                "macOS blocked access to this location. Grant Full Disk Access to the app "
                "running photos-share (System Settings → Privacy & Security → Full Disk "
                "Access), then restart it.") from e
        self.auth = (Auth(cfg.password, secure_cookie=cfg.mode == "funnel")
                     if cfg.password else None)
        self.host, self.url = self._resolve_network()
        self._server = None
        self._thread: threading.Thread | None = None
        self._funnel: subprocess.Popen | None = None
        self._caffeinate: subprocess.Popen | None = None
        self._watch_stop: threading.Event | None = None

    # ---- network -----------------------------------------------------------

    def _resolve_network(self) -> tuple[str, str]:
        cfg = self.cfg
        if cfg.mode == "tailscale":
            ip = tailscale_ip()
            if not ip:
                raise ShareError("No Tailscale address found. Is Tailscale installed and connected?")
            return ip, f"http://{tailscale_name() or ip}:{cfg.port}"
        if cfg.mode == "funnel":
            if not tailscale_cli():
                raise ShareError("Tailscale's command-line tool wasn't found. Install the "
                                 "Tailscale app from tailscale.com, or `brew install tailscale`.")
            name = tailscale_name()
            if not name:
                raise ShareError("Couldn't get this Mac's Tailscale name. Is Tailscale connected?")
            return "127.0.0.1", f"https://{name}"
        return cfg.host, f"http://{cfg.host}:{cfg.port}"

    # ---- lifecycle ---------------------------------------------------------

    def server(self):
        import uvicorn

        from .server import create_app

        app = create_app(self.collection, self.cfg.video, self.cfg.downloads, self.auth)
        return uvicorn.Server(uvicorn.Config(app, host=self.host, port=self.cfg.port,
                                             log_level="warning"))

    def start_watching(self) -> None:
        """Pick up photos added in Photos while sharing (re-indexes changed libraries)."""
        if self.cfg.refresh and self._watch_stop is None:
            self._watch_stop = self.collection.watch(self.cfg.refresh)

    def stop_watching(self) -> None:
        if self._watch_stop:
            self._watch_stop.set()
        self._watch_stop = None

    def start_keep_awake(self) -> None:
        """Prevent idle sleep until stop_keep_awake() or until this process exits.

        `caffeinate -w <pid>` ends by itself if this process dies, so a crash can't leave
        the Mac permanently awake. Closing a laptop lid still sleeps it.
        """
        if self.cfg.keep_awake and self._caffeinate is None and shutil.which("caffeinate"):
            self._caffeinate = subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())])

    def stop_keep_awake(self) -> None:
        if self._caffeinate and self._caffeinate.poll() is None:
            self._caffeinate.terminate()
            self._caffeinate.wait(timeout=5)
        self._caffeinate = None

    def start_funnel(self, wait: float = FUNNEL_WAIT) -> None:
        if self.cfg.mode != "funnel":
            return
        # Foreground mode: the public link exists only while this process runs. Tailscale's
        # output is read, not discarded: when Funnel isn't enabled for this Mac yet, it prints
        # a link to approve it and then waits, which would otherwise look like success.
        proc = subprocess.Popen([tailscale_cli(), "funnel", str(self.cfg.port)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        lines: list[str] = []
        threading.Thread(target=lambda: [lines.append(l.rstrip()) for l in proc.stdout],
                         daemon=True).start()   # keeps draining, so Tailscale never blocks
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline and proc.poll() is None:
            text = "\n".join(lines)
            if "login.tailscale.com" in text or "not enabled" in text.lower():
                break
            if "available on the internet" in text.lower():
                self._funnel = proc
                return
            time.sleep(0.1)
        text = "\n".join(lines).strip()
        if proc.poll() is None and "login.tailscale.com" not in text and "not enabled" not in text.lower():
            self._funnel = proc   # running and not asking for anything: assume it's serving
            return
        if proc.poll() is None:
            proc.terminate()
        link = re.search(r"https://login\.tailscale\.com\S*", text)
        if link:
            raise ShareError("Tailscale Funnel isn’t enabled for this Mac yet. Open this link once, "
                             f"approve it, then start sharing again:\n{link.group(0)}")
        raise ShareError("Tailscale Funnel didn’t start:\n" + text +
                         "\nIf it mentions enabling Funnel, open that link once, then retry.")

    def stop_funnel(self) -> None:
        if self._funnel and self._funnel.poll() is None:
            self._funnel.terminate()
            try:
                self._funnel.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._funnel.kill()
        self._funnel = None

    def start_background(self) -> None:
        """Run the server on a thread (for the menu bar app)."""
        self._server = self.server()
        self._thread = threading.Thread(target=self._run_server, daemon=True, name="server")
        self._thread.start()
        for _ in range(100):  # wait up to ~5 s for the port to open
            if self._server.started or not self._thread.is_alive():
                break
            threading.Event().wait(0.05)
        if not self._server.started:
            raise ShareError(f"Couldn't start the web server on port {self.cfg.port}. "
                             "Is another copy already running?")
        try:
            self.start_funnel()
        except ShareError:
            self.stop()
            raise
        self.start_keep_awake()
        self.start_watching()

    def _run_server(self) -> None:
        try:
            self._server.run()
        except SystemExit:  # uvicorn exits like this when the port is taken; reported by caller
            pass

    def stop(self) -> None:
        self.stop_watching()
        self.stop_keep_awake()
        self.stop_funnel()
        if self._server:
            self._server.should_exit = True
        if self._thread:
            self._thread.join(timeout=10)
        self._server = self._thread = None


# ---- Tailscale helpers -----------------------------------------------------

def tailscale_cli() -> str | None:
    found = shutil.which("tailscale")
    if found:
        return found
    return TAILSCALE_APP_CLI if Path(TAILSCALE_APP_CLI).exists() else None


def tailscale_ip() -> str | None:
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    for ip in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out):
        if ipaddress.ip_address(ip) in TAILSCALE_NET:
            return ip
    return None


def tailscale_name() -> str | None:
    cli = tailscale_cli()
    if not cli:
        return None
    try:
        out = subprocess.run([cli, "status", "--json"], capture_output=True, text=True,
                             timeout=5).stdout
        # Full MagicDNS name: the short form doesn't resolve for people you share with.
        return json.loads(out)["Self"]["DNSName"].rstrip(".") or None
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        return None
