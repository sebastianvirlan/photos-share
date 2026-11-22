import argparse
import getpass
import logging
import os
import sys
from pathlib import Path

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
    parser.add_argument("--no-keep-awake", dest="keep_awake", action="store_false",
                        help="let the Mac sleep while sharing (by default it's kept awake)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logging.getLogger("osxphotos").setLevel(logging.ERROR)

    from .share import Share, ShareConfig, ShareError

    password = None
    if args.password or args.funnel:
        password = os.environ.get(PASSWORD_ENV)
        if not password:
            if not sys.stdin.isatty():
                sys.exit(f"Error: a password is required; set ${PASSWORD_ENV}.")
            password = getpass.getpass("Choose a password for viewers: ")
            if password != getpass.getpass("Repeat it: "):
                sys.exit("Error: passwords don't match.")

    mode = "tailscale" if args.tailscale else "funnel" if args.funnel else "local"
    cfg = ShareConfig(path=args.path, only=args.only or [], screenshots=args.screenshots,
                      video=args.video, downloads=args.downloads, password=password,
                      mode=mode, host=args.host, port=args.port, keep_awake=args.keep_awake)
    try:
        share = Share(cfg)
    except ShareError as e:
        sys.exit(f"Error: {e}")

    libs = list(share.collection.libraries.values())
    ready = sum(lib.state == "ready" for lib in libs)
    print(f"{len(libs)} librar{'y' if len(libs) == 1 else 'ies'} "
          f"({ready} already indexed; others index on first open)")
    print(f"Screenshots: {'shown' if args.screenshots else 'hidden'} · "
          f"Video: {args.video} · Downloads: {'on' if args.downloads else 'off'} · "
          f"Password: {'on' if password else 'off'} · "
          f"Keep awake: {'on' if args.keep_awake else 'off'} · Hidden & deleted photos: excluded")
    if mode == "funnel":
        print("\n⚠ PUBLIC link: anyone who has it reaches the password page.")
    elif mode == "local" and args.host not in ("127.0.0.1", "localhost"):
        print("Warning: listening beyond this Mac" + ("" if password else " with no password") + ".")

    try:
        share.start_funnel()
    except ShareError as e:
        sys.exit(f"Error: {e}")
    share.start_keep_awake()
    print(f"\nSharing at: {share.url}\nPress Ctrl+C to stop sharing.", flush=True)
    try:
        share.server().run()  # blocks; handles Ctrl+C
    finally:
        share.stop_keep_awake()
        if mode == "funnel":
            share.stop_funnel()
            print("Public link closed.")
