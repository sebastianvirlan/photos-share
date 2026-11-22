# photos-share

Share macOS Photos libraries (e.g. on an external drive) as a Photos-style web page served
from your Mac. Read-only, no uploads, no copies. The library is the source of truth.

## Mac app (menu bar)

A native SwiftUI app (in `mac/`). It runs the Python tools from this checkout in the
background.

```sh
scripts/build-app.sh          # builds Photos Share.app in /Applications and shows it in Finder
```

Requirements: `uv` (`brew install uv`) and Swift (`xcode-select --install`). Xcode isn't needed.

The app lives in the menu bar and has two windows:
- **Sharing:** choose a library or folder and who can see it (this Mac, Tailscale, or a
  public link with a password). Then set the options: hidden photos, screenshots,
  downloads, video conversion and keep-awake. The viewer password is kept in your Keychain.
- **Import Between Libraries:** a faster alternative to Photos' own import screen.
  - Pick the two libraries and see the source as a grid. Photos already in the destination
    are left out.
  - Filter by album, year, photos or videos, and favourites, then select.
  - **When the destination is the System Photo Library** (Photos → Settings → General), edits
    stay editable: the app creates each photo itself from all its parts (original, Live
    video, Photos' edit recipe, edited versions), so crops, adjustments, styles, Clean Up,
    portrait depth and video trims can still be changed or reverted. Each imported photo is
    then checked against its source, and titles, captions and keywords are added through
    Photos (it opens briefly, only if any photo has them).
  - Otherwise Photos imports them in batches, without its duplicate prompts. Photos ignores
    edit recipes that way, so choose whether to skip edited photos (the default), import them
    as they look now, or import both versions.
  - Favourites, location, adjusted dates, album membership, Live Photos and RAW+JPEG pairs
    come across either way.
  - Afterwards, **Open Clean Up** checks what arrived.
- **Clean Up After Import:** pick the two libraries, see the three groups as thumbnails,
  compare any photo side by side, then **Move to Trash**, **Delete N Photos** (when the source
  is the System Photo Library) or **Mark in Photos**. Every action re-checks both libraries
  first.

The app runs this checkout, so keep the repo folder where it is (or rebuild after moving it).

Layout check without clicking around: `$(swift build --package-path mac --show-bin-path)/PhotosShare --snapshot /tmp/shots` renders the Clean Up window to PNGs with sample data.

## Command line

```sh
uv run photos-share "/Volumes/My Passport for Mac/Photolibraries" --tailscale
```

| Option | Meaning |
|---|---|
| `PATH` | A `.photoslibrary`, or a folder containing several (shown as a library picker) |
| `--only NAME` | Share only this library; repeatable |
| `--hidden` | Include Photos' Hidden album, shown only under **Hidden** (excluded by default) |
| `--screenshots` | Include screenshots and screen recordings (hidden by default) |
| `--video original\|convert` | Stream originals (default; fine for iPhone/Mac) or convert to 1080p H.264 |
| `--downloads` | Show a button to download original files (off by default) |
| `--password` | Require a password (prompted at start, or `PHOTOS_SHARE_PASSWORD`) |
| `--tailscale` | Listen only on this Mac's Tailscale address; viewers need the Tailscale app |
| `--funnel` | Public `https://…ts.net` link via Tailscale Funnel; no app needed; password required |
| `--refresh SECONDS` | How often to check for photos added in Photos (default 60; `0` = off) |
| `--no-keep-awake` | Let the Mac sleep while sharing (kept awake by default) |
| `--host`, `--port` | Bind address (default `127.0.0.1`) and port (default `8080`) |

Recently Deleted photos are never shared. Hidden photos are shared only with `--hidden`, and then only under a separate **Hidden** entry, as in Photos.

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

## Cleaning up after importing one library into another

Photos' **File → Import** from another library copies photos but can't delete them from the
source. `photos-dedupe`, or **Clean Up After Import…** in the menu bar app, finds what's safe
to delete:

```sh
uv run photos-dedupe "Source.photoslibrary" "Destination.photoslibrary"          # report only
uv run photos-dedupe "Source.photoslibrary" "Destination.photoslibrary" --mark   # + album
```

- **Matching:** photos are matched by content fingerprint, or by filename, size and date
  when that fails. Photos edited in the source whose edit didn't come across are left out.
- **File checks:** every match must also pass these, or it goes to **Needs a look** and is
  kept:
  - the destination's original file exists and is exactly the same size;
  - Live Photo videos and RAW+JPEG files came across;
  - matches found by filename, size and date have identical SHA-256 checksums.
- **`--mark`:** opens the source in Photos and puts the verified photos into an album
  "In <destination> – safe to delete". Review it, then press ⌘A, ⌘⌫ and confirm.
- **Deleting:** the tool never deletes photos itself, and Photos' scripting doesn't allow it.
  Deleted photos stay in Recently Deleted for 30 days.

### Importing from the command line

```sh
uv run photos-import "Source.photoslibrary" "Dest.photoslibrary" --plan     # what's new
uv run photos-import "Source.photoslibrary" "Dest.photoslibrary" --uuids-file ids.txt --edited skip
```

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
