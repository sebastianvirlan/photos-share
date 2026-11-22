#!/bin/sh
# Builds "Photos Share.app": the native SwiftUI menu bar app in mac/, which runs the
# Python tools from this checkout via uv.
# Usage: scripts/build-app.sh [destination folder]
#   Default: /Applications if writable (it is for admin users), else ~/Applications.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UV="$(command -v uv || true)"
[ -n "$UV" ] || { echo "uv not found: brew install uv" >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift not found: xcode-select --install" >&2; exit 1; }
if [ -n "${1:-}" ]; then
  DEST="$1"
elif [ -w /Applications ]; then
  DEST=/Applications
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
APP="$DEST/Photos Share.app"

echo "Preparing the Python tools…"
"$UV" sync --project "$REPO" --quiet
echo "Building the Swift app…"
swift build -c release --package-path "$REPO/mac" >/dev/null
BIN="$(swift build -c release --package-path "$REPO/mac" --show-bin-path)/PhotosShare"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotosShare"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Photos Share</string>
  <key>CFBundleDisplayName</key><string>Photos Share</string>
  <key>CFBundleIdentifier</key><string>io.github.photos-share</string>
  <key>CFBundleExecutable</key><string>PhotosShare</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Photos Share asks Photos to open a library and collect photos into an album for you to review.</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Photos Share deletes photos you've confirmed were imported into another library.</string>
  <key>PSUVPath</key><string>$UV</string>
  <key>PSRepoPath</key><string>$REPO</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed" >&2

echo "Built: $APP"
echo "Open it; it appears as an icon in the menu bar (no Dock icon)."
[ -z "${NO_REVEAL:-}" ] && open -R "$APP" 2>/dev/null || true   # show it in Finder
