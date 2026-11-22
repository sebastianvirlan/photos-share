# photos-share — plan

Share a macOS `.photoslibrary` (stored on an external HDD) with one trusted person
through a Photos-style web page, served from this Mac. No uploads and no copies:
the library is the source of truth.

## Constraints

- Libraries live on an external HDD. There may be several, from different macOS versions.
- iCloud is not used, so all originals are stored in the library.
- Sharing is occasional and with one trusted person.
- The library is read-only. Never write to it.

## Flow

```
$ photos-share /Volumes/PhotosHDD/Italy2023.photoslibrary
Reading library… 4,812 photos, 23 albums (hidden & deleted excluded)
Sharing at: http://<mac-name>:8080
Press Ctrl+C to stop sharing.
```

1. Plug in the HDD.
2. Run the command with the path to the library.
3. Send the link. She opens it through Tailscale.
4. Press Ctrl+C to stop sharing.

## Architecture

```
.photoslibrary (HDD, read-only)
  ├─ database/Photos.sqlite ──► osxphotos (reads a temporary copy) ──► in-memory index
  ├─ resources/derivatives  ──► grid thumbnails (resized with sips, then cached)
  ├─ resources/renders      ──► edited versions
  └─ originals/             ──► full-size / download
                                         │
                       FastAPI on this Mac (port 8080)
                                         │
                          Tailscale (private network)
                                         │
                                Her phone or laptop
```

- **Reading the library: osxphotos.** It reads `Photos.sqlite` from many macOS
  versions. PhotoKit is not an option, because it only opens the System Photo Library.
- **Cache:** `~/Library/Caches/photos-share/<library-id>/`. It holds generated JPEGs
  only, can be deleted at any time, and is never treated as the source of truth.
- **Network: Tailscale** (free Personal plan). It's private, so the server doesn't
  need public-internet hardening. The Mac must be awake and the tool running.
- **Security:** photos are looked up by UUID from the index only, and file paths are
  never accepted from the client. Hidden and Recently Deleted photos are excluded.

## Phases

0. ✅ **Spike.** Open a library with osxphotos, print the counts, and serve thumbnails
   and a basic grid on localhost.
1. ✅ **MVP (not yet tested over Tailscale).**
   - Library picker when given a folder of libraries; `--only` limits which are shared.
   - Each library is indexed on first open, and the index is cached until `Photos.sqlite` changes.
   - Grid grouped by month, with zoom.
   - Viewer: ~2048 px JPEGs, edited versions, keyboard and swipe.
   - Video: `--video original|convert` (avconvert, no ffmpeg).
   - Live Photos play from a LIVE button.
   - Screenshots hidden unless `--screenshots`.
   - `--tailscale` listens on the Tailscale address only.
2. ✅ **Photos-style browsing.** Albums sidebar (a drawer on phones); Years / Months / Days /
   All Photos views (Years → Months → Days drill-down); Live Photos play on press-and-hold or
   on hovering over LIVE; optional `--downloads`.
3. ✅ **Drive unplugged:** the library shows as "Drive not connected". Already-viewed photos still
   load from the cache, and everything comes back when the drive is plugged in again.
4. ✅ **Favourites, Media Types, People, Places, Mac app.**
   - Sidebar: Favourites; Media Types (Videos, Selfies, Live Photos, Portrait, Panoramas,
     Slo-mo, Time-lapse, Screenshots).
   - People: named people with face avatars (cropped in the browser), sorted by
     favourites, then photo count.
   - Places: Leaflet + OpenStreetMap with clustered thumbnail pins.
   - Menu bar app (`rumps`), built with `scripts/build-app.sh`. It shares its start/stop code
     with the command line (`share.py`) and keeps the password in the Keychain.
   - Index format v3; existing caches re-index on first open.

## Findings

- Opening a big library (~300 MB database) takes about 15 s cold: about 12 s to copy the
  database off the HDD and about 2 s to parse it. While Spotlight was indexing the freshly
  plugged-in drive, it took 4–7 minutes. The cached index makes later opens instant.
- Upload measured 74 Mbps, enough to stream iPhone 4K originals, so `--video original`
  is the default.

