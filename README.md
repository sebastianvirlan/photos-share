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
| `--tailscale` | Listen only on this Mac's Tailscale address |
| `--host`, `--port` | Bind address (default `127.0.0.1`) and port (default `8080`) |

Hidden and Recently Deleted photos are never shared.

Generated thumbnails, previews and library indexes are cached in
`~/Library/Caches/photos-share/` and can be deleted at any time.

Don't open a library in Photos.app while sharing it. Photos may upgrade it, and the tool
will then rebuild its index.
