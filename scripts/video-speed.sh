#!/bin/zsh
# How fast a share sends videos: downloads the start of a video and prints the speed.
#
#   scripts/video-speed.sh https://name.tailnet.ts.net          (public link)
#   scripts/video-speed.sh http://name.tailnet.ts.net:8080      (private link)
#
# Asks for the share's password if it has one (not stored). Uses the newest video in the
# first library. Run it once per link, from the same place, to compare them.
set -euo pipefail

url=${1:?Usage: scripts/video-speed.sh <share link>}
url=${url%/}
# Follow redirects once (Tailscale sends http:// on a public link to https://) and use where
# they lead: a redirected sign-in would lose its password.
url=$(curl -s -L -o /dev/null -w '%{url_effective}' "$url/api/info")
url=${url%/api/info}
mb=${MB:-20}          # how much of the video to download

json() { python3 -c "import sys, json; d = json.load(sys.stdin); print($1)"; }

auth=()
code=$(curl -s -o /dev/null -w '%{http_code}' -L "$url/api/info")
if [[ $code == 401 ]]; then
  read -rs "password?Password: "; echo
  body=$(python3 -c 'import json, sys; print(json.dumps({"password": sys.argv[1]}))' "$password")
  token=$(curl -s -L -X POST -H 'Content-Type: application/json' -d "$body" "$url/api/login" \
          | json 'd.get("token") or d.get("error", "")')
  [[ $token == *" "* || -z $token ]] && { echo "Sign-in failed: $token" >&2; exit 1; }
  auth=(-H "Authorization: Bearer $token")
elif [[ $code != 200 ]]; then
  echo "The share didn't answer properly (HTTP $code). Is it sharing, and is this the link?" >&2
  exit 1
fi

mode=$(curl -s -L "${auth[@]}" "$url/api/info" | json 'd["video"]')
lib=$(curl -s -L "${auth[@]}" "$url/api/libraries" | json 'next(l["id"] for l in d if l["state"] == "ready")')
video=$(curl -s -L "${auth[@]}" "$url/api/libraries/$lib" | json 'next((a["u"] for a in d["assets"] if a["m"]), "")')
[[ -z $video ]] && { echo "No videos in the first library." >&2; exit 1; }

if [[ $mode == convert ]]; then
  echo "Note: the Mac converts videos before sending them (\"Convert videos for any browser\")."
  echo "      The first play of each video waits for the whole conversion."
  state=$(curl -s -L "${auth[@]}" "$url/video-status/$lib/$video" | json 'd["state"]')
  [[ $state != ready ]] && { echo "This video isn't converted yet ($state); try again when it is." >&2; exit 1; }
fi

# The total size, from the answer to a 1-byte request ("Content-Range: bytes 0-0/<size>").
size=$(curl -s -L -o /dev/null -D - -r 0-0 "${auth[@]}" "$url/video/$lib/$video" \
       | awk -F/ 'tolower($0) ~ /^content-range:/ {print $2}' | tr -d '\r' | tail -1)
printf 'Video: %s, %.1f MB in total\n' "$video" "$(( ${size:-0} / 1000000.0 ))"
echo "Downloading the first $mb MB from $url …"
curl -s -L -o /dev/null "${auth[@]}" -r "0-$(( mb * 1000000 - 1 ))" "$url/video/$lib/$video" \
  -w '%{time_starttransfer} %{size_download} %{time_total} %{speed_download}\n' \
  | read first bytes total speed
printf 'First byte after %.2f s; %.1f MB in %.1f s = %.1f MB/s (%.0f Mbit/s)\n' \
  "$first" "$(( bytes / 1000000.0 ))" "$total" "$(( speed / 1000000.0 ))" "$(( speed * 8 / 1000000.0 ))"
echo "An iPhone 4K video needs roughly 50–100 Mbit/s to play without waiting; 1080p about 15–25."
