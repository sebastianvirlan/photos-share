"""Start/stop a share: libraries + web server + (optionally) Tailscale. Used by CLI and app."""

from __future__ import annotations

import ipaddress
import json
import re
import shutil
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path

TAILSCALE_NET = ipaddress.ip_network("100.64.0.0/10")
TAILSCALE_APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
MIN_FUNNEL_PASSWORD = 8
MODES = ("local", "tailscale", "funnel")


class ShareError(Exception):
    """A problem the user can fix; the message is shown as-is."""


@dataclass
class ShareConfig:
    path: Path
    only: list[str] = field(default_factory=list)
    screenshots: bool = False
    video: str = "original"     # original | convert
    downloads: bool = False
    password: str | None = None
    mode: str = "local"         # local | tailscale | funnel
    host: str = "127.0.0.1"     # used in local mode only
    port: int = 8080


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
            self.collection = Collection(cfg.path, Options(show_screenshots=cfg.screenshots),
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

    def start_funnel(self) -> None:
        if self.cfg.mode != "funnel":
            return
        # Foreground mode: the public link exists only while this process runs.
        self._funnel = subprocess.Popen([tailscale_cli(), "funnel", str(self.cfg.port)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        text=True)
        try:
            err = self._funnel.communicate(timeout=3)[1]
        except subprocess.TimeoutExpired:
            return  # still running: good
        self._funnel = None
        raise ShareError("Tailscale Funnel didn't start:\n" + (err or "").strip() +
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
        self._thread = threading.Thread(target=self._server.run, daemon=True, name="server")
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

    def stop(self) -> None:
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
