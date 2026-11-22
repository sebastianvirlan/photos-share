# photos-share

Share macOS Photos libraries (e.g. on an external drive) as a Photos-style web page served
from your Mac. Read-only, no uploads, no copies. The library is the source of truth.

## Mac app (menu bar)

```sh
scripts/build-app.sh          # builds ~/Applications/Photos Share.app
```

Open **Photos Share** from Applications. It lives in the menu bar:
**Choose Library or Folder…** → **Who can see it** (this Mac / Tailscale / public link) →
**Start Sharing**. The link is copied automatically. Settings are remembered, and the
viewer password is kept in your Keychain. Logs go to `~/Library/Logs/photos-share.log`.

The app runs this checkout via `uv`, so keep the repo folder where it is (or rebuild after
moving it).

## Command line

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
| `--refresh SECONDS` | How often to check for photos added in Photos (default 60; `0` = off) |
| `--no-keep-awake` | Let the Mac sleep while sharing (kept awake by default) |
| `--host`, `--port` | Bind address (default `127.0.0.1`) and port (default `8080`) |

Hidden and Recently Deleted photos are never shared.

The web page mirrors Photos: Library (Years / Months / Days / All Photos), Favourites, People,
Places (map; needs internet for map tiles), Media Types and Albums.

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

Photos you add or edit in Photos.app while sharing appear automatically. Every minute, the
tool checks whether the library changed. Once the changes have settled, it re-indexes in the
background, and the viewer's page shows a **New photos · Show** button. Edited photos get
fresh previews.

## Tests

```sh
uv run pytest
```

The suite uses fake libraries with pre-built indexes, so no real Photos library or drive is
needed. Everything runs on macOS, since it uses `sips`, `caffeinate` and JavaScriptCore.
- **Server:** API routes, path-traversal protection, downloads, video range requests, and
  unplugged-drive handling.
- **Password:** login, lockout, and cookies.
- **Sharing:** start/stop, port conflicts, keep-awake, and the Tailscale/Funnel safety checks.
- **Frontend:** `app.js` runs under JavaScriptCore with a tiny DOM stand-in
  (`tests/frontend/`), covering routing, views, filters and the viewer.
