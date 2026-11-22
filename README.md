# photos-share

Share macOS Photos libraries (e.g. on an external drive) as a Photos-style web page served
from your Mac. Read-only, no uploads, no copies. The library is the source of truth.

## Usage

```sh
uv run photos-share "/Volumes/My Passport for Mac/Photolibraries" --tailscale
```

| Option | Meaning |
|---|---|
| `PATH` | A `.photoslibrary`, or a folder containing several (shown as a library picker) |
| `--only NAME` | Share only this library; repeatable |
| `--screenshots` | Include screenshots and screen recordings (hidden by default) |
| `--video original\|convert` | Stream originals (default; fine for iPhone/Mac) or convert to 1080p H.264 |
| `--downloads` | Show a button to download original files (off by default) |
| `--password` | Require a password (prompted at start, or `PHOTOS_SHARE_PASSWORD`) |
| `--tailscale` | Listen only on this Mac's Tailscale address; viewers need the Tailscale app |
| `--funnel` | Public `https://…ts.net` link via Tailscale Funnel; no app needed; password required |
| `--host`, `--port` | Bind address (default `127.0.0.1`) and port (default `8080`) |

Hidden and Recently Deleted photos are never shared.

### Sharing without the Tailscale app (Funnel)

```sh
uv run photos-share "/Volumes/My Passport for Mac/Photolibraries" --funnel
```

You're asked for a password (8+ characters). The printed `https://<mac>.<tailnet>.ts.net` link
works in any browser. Viewers enter the password once and stay signed in for 30 days, or until
you change the password. The link closes when you stop the tool. The first time, Tailscale may
ask you to enable Funnel for your network via a link it prints.

Generated thumbnails, previews and library indexes are cached in
`~/Library/Caches/photos-share/` and can be deleted at any time.

Don't open a library in Photos.app while sharing it. Photos may upgrade it, and the tool
will then rebuild its index.
