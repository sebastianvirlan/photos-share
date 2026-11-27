import argparse
import getpass
import json
import logging
import os
import signal
import sys
import warnings
from pathlib import Path

# urllib3 (pulled in by osxphotos) warns about optional SOCKS proxy support on import;
# nothing here uses a proxy, so it's only noise in the terminal.
warnings.filterwarnings("ignore", message="SOCKS support in urllib3")

PASSWORD_ENV = "PHOTOS_SHARE_PASSWORD"


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="photos-share",
        description="Share macOS Photos libraries as a Photos-style web page.")
    parser.add_argument("path", type=Path,
                        help="a .photoslibrary, or a folder containing several")
    parser.add_argument("--only", action="append", metavar="NAME",
                        help="share only this library (repeatable), e.g. --only 'Final 13 pro'")
    parser.add_argument("--screenshots", action="store_true",
                        help="include screenshots and screen recordings (hidden by default)")
    parser.add_argument("--hidden", action="store_true",
                        help="include photos from Photos' Hidden album (shown under 'Hidden')")
    parser.add_argument("--video", choices=["original", "convert"], default="original",
                        help="original: stream files as-is (iPhone/Mac). "
                             "convert: 1080p H.264 via avconvert (plays everywhere, slower start)")
    parser.add_argument("--downloads", action="store_true",
                        help="let viewers download original files (off by default)")
    parser.add_argument("--password", action="store_true",
                        help=f"require a password (asked for at start, or read from ${PASSWORD_ENV})")
    net = parser.add_mutually_exclusive_group()
    net.add_argument("--tailscale", action="store_true",
                     help="private https link for devices on your Tailscale network only "
                          "(viewers need Tailscale; uses tailscale serve)")
    net.add_argument("--funnel", action="store_true",
                     help="publish a public https link with Tailscale Funnel (no app needed for "
                          "viewers; requires a password)")
    net.add_argument("--host", default="127.0.0.1", help="bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--machine", action="store_true",
                        help="report status as JSON lines on stdout (used by the Mac app)")
    parser.add_argument("--refresh", type=float, default=60, metavar="SECONDS",
                        help="how often to check for photos added in Photos (default 60; 0 = off)")
    parser.add_argument("--no-keep-awake", dest="keep_awake", action="store_false",
                        help="let the Mac sleep while sharing (by default it's kept awake)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logging.getLogger("osxphotos").setLevel(logging.ERROR)

    from .share import Share, ShareConfig, ShareError

    def emit(event: str, **data) -> None:
        if args.machine:
            print(json.dumps({"event": event, **data}), flush=True)

    def fail(msg: str):
        if args.machine:
            emit("error", message=msg)
            sys.exit(1)
        sys.exit(f"Error: {msg}")

    def say(*a) -> None:  # human-readable output; goes to stderr in machine mode
        print(*a, file=sys.stderr if args.machine else sys.stdout, flush=True)

    password = None
    if args.password or args.funnel:
        password = os.environ.get(PASSWORD_ENV)
        if not password:
            if args.machine or not sys.stdin.isatty():
                fail(f"a password is required; set ${PASSWORD_ENV}.")
            password = getpass.getpass("Choose a password for viewers: ")
            if password != getpass.getpass("Repeat it: "):
                fail("passwords don't match.")

    mode = "tailscale" if args.tailscale else "funnel" if args.funnel else "local"
    cfg = ShareConfig(path=args.path, only=args.only or [], screenshots=args.screenshots,
                      hidden=args.hidden,
                      video=args.video, downloads=args.downloads, password=password,
                      mode=mode, host=args.host, port=args.port, keep_awake=args.keep_awake,
                      refresh=args.refresh)
    try:
        share = Share(cfg)
    except ShareError as e:
        fail(str(e))

    libs = list(share.collection.libraries.values())
    ready = sum(lib.state == "ready" for lib in libs)
    if len(libs) == 1 and ready == 0:
        libs[0].ensure_open()   # one library: read it now, not when the first visitor arrives
        say("1 library (reading it now, in the background)")
    else:
        say(f"{len(libs)} librar{'y' if len(libs) == 1 else 'ies'} "
            f"({ready} already indexed; others index on first open)")
    say(f"Screenshots: {'shown' if args.screenshots else 'hidden'} · "
        f"Hidden album: {'included' if args.hidden else 'excluded'} · "
          f"Video: {args.video} · Downloads: {'on' if args.downloads else 'off'} · "
          f"Password: {'on' if password else 'off'} · "
          f"Keep awake: {'on' if args.keep_awake else 'off'} · Recently Deleted: excluded")
    if mode == "funnel":
        say("\n⚠ PUBLIC link: anyone who has it reaches the password page.")
    elif mode == "local" and args.host not in ("127.0.0.1", "localhost"):
        say("Warning: listening beyond this Mac" + ("" if password else " with no password") + ".")

    try:
        share.start_proxy()
    except ShareError as e:
        fail(str(e))
    share.start_keep_awake()
    share.start_watching()
    say(f"\nSharing at: {share.url}\nPress Ctrl+C to stop sharing.")
    if mode == "funnel":
        say("The first time, a public link can take a few minutes to work (Tailscale sets up its\n"
            "address and certificate). Test it from a phone on mobile data, not from this Mac.")
    elif mode == "tailscale":
        say("The first time, the link can take a minute to work while Tailscale gets its certificate.")
    server = share.server()
    if args.machine:
        # Announce "ready" only once the port is actually open.
        orig_startup = server.startup

        async def startup(*a, **kw):
            await orig_startup(*a, **kw)
            if server.started:
                emit("ready", url=share.url, libraries=len(libs))
        server.startup = startup
    # uvicorn shuts down gracefully on SIGINT/SIGTERM, then re-raises the signal. Make
    # SIGTERM behave like Ctrl+C so our cleanup below still runs (closing a Funnel link).
    def _term(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, _term)
    try:
        try:
            server.run()  # blocks; handles Ctrl+C / SIGTERM
        except SystemExit:
            pass  # uvicorn exits this way when it can't start
        except KeyboardInterrupt:
            pass  # stopped by Ctrl+C or SIGTERM; cleanup below
        if not server.started:
            share.stop_watching()
            share.stop_keep_awake()
            share.stop_proxy()
            fail(f"couldn't start the web server on port {args.port}. Is another copy running?")
    finally:
        share.stop_watching()
        share.stop_keep_awake()
        if mode == "funnel":
            share.stop_proxy()
            say("Public link closed.")
        emit("stopped")
