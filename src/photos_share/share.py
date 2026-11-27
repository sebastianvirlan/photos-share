"""Start/stop a share: libraries + web server + (optionally) Tailscale. Used by CLI and app."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import threading
from dataclasses import dataclass, field
from pathlib import Path

TAILSCALE_APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
# Without a terminal attached (as when the Mac app runs us), the binary inside Tailscale.app
# tries to open the Tailscale app instead of acting as the command-line tool ("The Tailscale
# GUI failed to start … CLIError error 3"). This makes it act as the command-line tool.
TAILSCALE_ENV = {**os.environ, "TAILSCALE_BE_CLI": "1"}
MIN_FUNNEL_PASSWORD = 8
FUNNEL_WAIT = 8.0   # seconds to watch Tailscale's output when starting Funnel
TAILSCALE_WAIT = 20.0  # seconds to wait for Tailscale to connect (e.g. just opened)
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
        # Both Tailscale modes are https (Tailscale's certificate), so the cookie is https-only.
        self.auth = (Auth(cfg.password, secure_cookie=cfg.mode in ("tailscale", "funnel"))
                     if cfg.password else None)
        self.host, self.url = self._resolve_network()
        self._server = None
        self._thread: threading.Thread | None = None
        self._proxy: subprocess.Popen | None = None   # `tailscale serve` or `tailscale funnel`
        self._caffeinate: subprocess.Popen | None = None
        self._watch_stop: threading.Event | None = None

    # ---- network -----------------------------------------------------------

    def _resolve_network(self) -> tuple[str, str]:
        cfg = self.cfg
        # Both Tailscale modes: the server listens on this Mac only; Tailscale puts https in
        # front of it at https://<name>.ts.net, for the tailnet (serve) or everyone (funnel).
        if cfg.mode in ("tailscale", "funnel"):
            if not tailscale_cli():
                raise ShareError("Tailscale's command-line tool wasn't found. Install the "
                                 "Tailscale app from tailscale.com, or `brew install tailscale`.")
            name = _wait_for(tailscale_name)
            if not name:
                raise ShareError(tailscale_problem())
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

    def start_proxy(self, wait: float = FUNNEL_WAIT) -> None:
        """Tailscale's https front for the server: `tailscale serve` (private: only devices on
        the tailnet) or `tailscale funnel` (public)."""
        mode = self.cfg.mode
        if mode not in ("tailscale", "funnel"):
            return
        command = "serve" if mode == "tailscale" else "funnel"
        feature = "HTTPS" if mode == "tailscale" else "Funnel"
        # Foreground mode: the link exists only while this process runs. Tailscale's output is
        # read, not discarded: when the feature isn't enabled for this Mac yet, it prints a link
        # to approve it and then waits, which would otherwise look like success.
        proc = subprocess.Popen([tailscale_cli(), command, str(self.cfg.port)], env=TAILSCALE_ENV,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        lines: list[str] = []
        threading.Thread(target=lambda: [lines.append(l.rstrip()) for l in proc.stdout],
                         daemon=True).start()   # keeps draining, so Tailscale never blocks
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline and proc.poll() is None:
            text = "\n".join(lines)
            if "login.tailscale.com" in text or "not enabled" in text.lower():
                break
            # "Available on the internet:" (funnel) / "Available within your tailnet:" (serve)
            if "available on the internet" in text.lower() or "available within your tailnet" in text.lower():
                self._proxy = proc
                return
            time.sleep(0.1)
        text = "\n".join(lines).strip()
        if proc.poll() is None and "login.tailscale.com" not in text and "not enabled" not in text.lower():
            self._proxy = proc   # running and not asking for anything: assume it's serving
            return
        if proc.poll() is None:
            proc.terminate()
        link = re.search(r"https://login\.tailscale\.com\S*", text)
        if link:
            raise ShareError(f"Tailscale {feature} isn’t enabled for this Mac yet. Open this link once, "
                             f"approve it, then start sharing again:\n{link.group(0)}")
        raise ShareError(f"Tailscale {feature} didn’t start:\n" + text +
                         f"\nIf it mentions enabling {feature}, open that link once, then retry.")

    def stop_proxy(self) -> None:
        if self._proxy and self._proxy.poll() is None:
            self._proxy.terminate()
            try:
                self._proxy.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proxy.kill()
        self._proxy = None

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
            self.start_proxy()
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
        self.stop_proxy()
        if self._server:
            self._server.should_exit = True
        if self._thread:
            self._thread.join(timeout=10)
        self._server = self._thread = None


# ---- Tailscale helpers -----------------------------------------------------

def tailscale_clis() -> list[str]:
    """Every Tailscale command-line tool on this Mac: one on the PATH (e.g. Homebrew's) may
    not talk to the Tailscale app that's actually running, so callers try each."""
    found = [shutil.which("tailscale"), TAILSCALE_APP_CLI if Path(TAILSCALE_APP_CLI).exists() else None]
    return list(dict.fromkeys(c for c in found if c))


def tailscale_cli() -> str | None:
    """The tool that answers `status`, else the first one found."""
    clis = tailscale_clis()
    for cli in clis:
        if _status(cli)[0] is not None:
            return cli
    return clis[0] if clis else None


def _status(cli: str) -> tuple[dict | None, str]:
    """(`tailscale status --json`, or None) and what went wrong."""
    try:
        r = subprocess.run([cli, "status", "--json"], env=TAILSCALE_ENV, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"{cli}: {e}"
    try:
        return json.loads(r.stdout), ""
    except ValueError:
        said = (r.stderr or r.stdout).strip().splitlines()
        return None, f"{cli}: {said[0] if said else f'exit code {r.returncode}'}"


def _wait_for(get):
    """Tailscale takes a few seconds to connect after it's opened: keep asking until then."""
    deadline = time.monotonic() + TAILSCALE_WAIT
    while True:
        found = get()
        if found or time.monotonic() >= deadline:
            return found
        time.sleep(1)


def tailscale_state() -> str | None:
    """Tailscale's own state ("Running", "Stopped", "NeedsLogin", …), "NotRunning" when no
    tool gets an answer, or None when it isn't installed."""
    clis = tailscale_clis()
    if not clis:
        return None
    for cli in clis:
        st, _ = _status(cli)
        if st is not None:
            return st.get("BackendState") or "NotRunning"
    return "NotRunning"


def _tool_errors() -> str:
    errs = [e for e in (_status(c)[1] for c in tailscale_clis()) if e]
    return ("\nTailscale said: " + "; ".join(errs)) if errs else ""


def tailscale_problem() -> str:
    """Why there's no Tailscale address, in words the user can act on."""
    state = tailscale_state()
    if state is None:
        return "Tailscale isn't installed. Get the Tailscale app from tailscale.com."
    if state == "NotRunning":
        return "Tailscale isn't running. Open the Tailscale app, then try again." + _tool_errors()
    if state == "Stopped":
        return ("Tailscale is open but switched off. Turn it on from its menu bar icon, "
                "then try again.")
    if state in ("NeedsLogin", "NeedsMachineAuth"):
        return "Tailscale needs you to sign in. Use its menu bar icon, then try again."
    if state == "Running":
        return ("Tailscale is connected, but didn't give this Mac's name. Check MagicDNS is on "
                "in the Tailscale admin console (DNS page)." + _tool_errors())
    return (f"Tailscale didn't connect within {TAILSCALE_WAIT:.0f} seconds "
            f"(it says “{state}”). Try again once it shows as connected.")


def tailscale_name() -> str | None:
    for cli in tailscale_clis():
        st, _ = _status(cli)
        try:
            # Full MagicDNS name: the short form doesn't resolve for people you share with.
            name = st["Self"]["DNSName"].rstrip(".") if st else None
        except (KeyError, TypeError, AttributeError):
            name = None
        if name:
            return name
    return None
