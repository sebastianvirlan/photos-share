import argparse
import ipaddress
import json
import logging
import re
import socket
import subprocess
import sys
from pathlib import Path

TAILSCALE_NET = ipaddress.ip_network("100.64.0.0/10")
TAILSCALE_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"


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
    net = parser.add_mutually_exclusive_group()
    net.add_argument("--tailscale", action="store_true",
                     help="listen on this Mac's Tailscale address only")
    net.add_argument("--host", default="127.0.0.1", help="bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    for noisy in ("osxphotos",):
        logging.getLogger(noisy).setLevel(logging.ERROR)

    from .library import Collection, Options
    from .server import create_app

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
          f"Video: {args.video} · Hidden & deleted photos: excluded")

    host, url_host = args.host, args.host
    if args.tailscale:
        host = _tailscale_ip() or sys.exit(
            "Error: no Tailscale address found. Is Tailscale installed and connected?")
        url_host = _tailscale_name() or host
    elif host == "0.0.0.0":
        url_host = socket.gethostname().split(".")[0]
        print("Warning: listening on all networks, including local Wi-Fi.")

    print(f"\nSharing at: http://{url_host}:{args.port}\nPress Ctrl+C to stop sharing.",
          flush=True)

    import uvicorn
    uvicorn.run(create_app(col, args.video), host=host, port=args.port, log_level="warning")


def _tailscale_ip() -> str | None:
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    for ip in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out):
        if ipaddress.ip_address(ip) in TAILSCALE_NET:
            return ip
    return None


def _tailscale_name() -> str | None:
    for cli in ("tailscale", TAILSCALE_CLI):
        try:
            out = subprocess.run([cli, "status", "--json"], capture_output=True, text=True,
                                 timeout=5).stdout
            # Full MagicDNS name: the short form doesn't resolve for people you share with.
            return json.loads(out)["Self"]["DNSName"].rstrip(".") or None
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
            continue
    return None
