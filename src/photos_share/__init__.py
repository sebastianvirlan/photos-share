import argparse
import getpass
import ipaddress
import json
import logging
import os
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

TAILSCALE_NET = ipaddress.ip_network("100.64.0.0/10")
TAILSCALE_APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
PASSWORD_ENV = "PHOTOS_SHARE_PASSWORD"
MIN_FUNNEL_PASSWORD = 8


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
    parser.add_argument("--video", choices=["original", "convert"], default="original",
                        help="original: stream files as-is (iPhone/Mac). "
                             "convert: 1080p H.264 via avconvert (plays everywhere, slower start)")
    parser.add_argument("--downloads", action="store_true",
                        help="let viewers download original files (off by default)")
    parser.add_argument("--password", action="store_true",
                        help=f"require a password (asked for at start, or read from ${PASSWORD_ENV})")
    net = parser.add_mutually_exclusive_group()
    net.add_argument("--tailscale", action="store_true",
                     help="listen on this Mac's Tailscale address only (viewers need Tailscale)")
    net.add_argument("--funnel", action="store_true",
                     help="publish a public https link with Tailscale Funnel (no app needed for "
                          "viewers; requires a password)")
    net.add_argument("--host", default="127.0.0.1", help="bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logging.getLogger("osxphotos").setLevel(logging.ERROR)

    from .auth import Auth
    from .library import Collection, Options
    from .server import create_app

    # ---- password ----------------------------------------------------------
    password = os.environ.get(PASSWORD_ENV) if (args.password or args.funnel) else None
    if (args.password or args.funnel) and not password:
        if not sys.stdin.isatty():
            sys.exit(f"Error: a password is required; set ${PASSWORD_ENV}.")
        password = getpass.getpass("Choose a password for viewers: ")
        if password != getpass.getpass("Repeat it: "):
            sys.exit("Error: passwords don't match.")
    if args.funnel and len(password or "") < MIN_FUNNEL_PASSWORD:
        sys.exit(f"Error: --funnel makes the link public; use a password of at least "
                 f"{MIN_FUNNEL_PASSWORD} characters.")
    auth = Auth(password, secure_cookie=args.funnel) if password else None

    # ---- libraries ---------------------------------------------------------
    try:
        col = Collection(args.path, Options(show_screenshots=args.screenshots), args.only)
    except ValueError as e:
        sys.exit(f"Error: {e}")
    except PermissionError:
        sys.exit("Error: macOS blocked access to this location.\n"
                 "Grant Full Disk Access to the app running this command (Terminal, VS Code…):"
                 "\nSystem Settings → Privacy & Security → Full Disk Access, then restart it.")

    libs = list(col.libraries.values())
    ready = sum(lib.state == "ready" for lib in libs)
    print(f"{len(libs)} librar{'y' if len(libs) == 1 else 'ies'} "
          f"({ready} already indexed; others index on first open)")
    print(f"Screenshots: {'shown' if args.screenshots else 'hidden'} · "
          f"Video: {args.video} · Downloads: {'on' if args.downloads else 'off'} · "
          f"Password: {'on' if auth else 'off'} · Hidden & deleted photos: excluded")

    # ---- network -----------------------------------------------------------
    host, url = args.host, f"http://{args.host}:{args.port}"
    funnel = None
    if args.tailscale:
        host = _tailscale_ip() or sys.exit(
            "Error: no Tailscale address found. Is Tailscale installed and connected?")
        url = f"http://{_tailscale_name() or host}:{args.port}"
    elif args.funnel:
        cli = _tailscale_cli() or sys.exit(
            "Error: Tailscale command-line tool not found. Install the Tailscale app, or "
            "`brew install tailscale`.")
        name = _tailscale_name() or sys.exit(
            "Error: couldn't get this Mac's Tailscale name. Is Tailscale connected?")
        host, url = "127.0.0.1", f"https://{name}"
        # Foreground mode: the public link exists only while this process runs.
        funnel = subprocess.Popen([cli, "funnel", str(args.port)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            err = funnel.communicate(timeout=3)[1]
            sys.exit("Error: Tailscale Funnel didn't start:\n" + (err or "").strip() +
                     "\nIf it mentions enabling Funnel, open that link once, then try again.")
        except subprocess.TimeoutExpired:
            pass  # still running: good
        print("\n⚠ PUBLIC link: anyone who has it reaches the password page.")
    elif host == "0.0.0.0":
        url = f"http://{socket.gethostname().split('.')[0]}:{args.port}"
        print("Warning: listening on all networks, including local Wi-Fi.")
    if host not in ("127.0.0.1", "localhost") and not auth and not args.tailscale:
        print("Warning: no password set (--password).")

    print(f"\nSharing at: {url}\nPress Ctrl+C to stop sharing.", flush=True)

    import uvicorn
    try:
        uvicorn.run(create_app(col, args.video, args.downloads, auth), host=host,
                    port=args.port, log_level="warning")
    finally:
        if funnel and funnel.poll() is None:
            funnel.terminate()
            print("Public link closed.")


def _tailscale_cli() -> str | None:
    found = shutil.which("tailscale")
    if found:
        return found
    return TAILSCALE_APP_CLI if Path(TAILSCALE_APP_CLI).exists() else None


def _tailscale_ip() -> str | None:
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    for ip in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out):
        if ipaddress.ip_address(ip) in TAILSCALE_NET:
            return ip
    return None


def _tailscale_name() -> str | None:
    cli = _tailscale_cli()
    if not cli:
        return None
    try:
        out = subprocess.run([cli, "status", "--json"], capture_output=True, text=True,
                             timeout=5).stdout
        # Full MagicDNS name: the short form doesn't resolve for people you share with.
        return json.loads(out)["Self"]["DNSName"].rstrip(".") or None
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        return None
