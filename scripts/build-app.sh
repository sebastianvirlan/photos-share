#!/bin/sh
# Builds "Photos Share.app", a menu bar launcher that runs this checkout with uv.
# Usage: scripts/build-app.sh [destination folder]
#   Default: /Applications if writable (it is for admin users), else ~/Applications.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UV="$(command -v uv || true)"
[ -n "$UV" ] || { echo "uv not found: brew install uv" >&2; exit 1; }
if [ -n "${1:-}" ]; then
  DEST="$1"
elif [ -w /Applications ]; then
  DEST=/Applications
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
APP="$DEST/Photos Share.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Photos Share</string>
  <key>CFBundleDisplayName</key><string>Photos Share</string>
  <key>CFBundleIdentifier</key><string>io.github.photos-share</string>
  <key>CFBundleExecutable</key><string>photos-share</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Photos Share deletes photos you've confirmed were imported into another library.</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
cat > "$APP/Contents/MacOS/photos-share" <<SH
#!/bin/sh
mkdir -p "\$HOME/Library/Logs"
exec "$UV" run --project "$REPO" --quiet photos-share-app >> "\$HOME/Library/Logs/photos-share.log" 2>&1
SH
chmod +x "$APP/Contents/MacOS/photos-share"
echo "Built: $APP"
echo "Open it from there; it appears as an icon in the menu bar (no Dock icon, no window)."
echo "Logs:  ~/Library/Logs/photos-share.log"
[ -z "${NO_REVEAL:-}" ] && open -R "$APP" 2>/dev/null || true   # show it in Finder
