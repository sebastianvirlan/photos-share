#!/bin/zsh
# Builds the iPhone/iPad app into an .ipa in ios/dist/.
#
#   scripts/build-ipa.sh --team ABCDE12345 [--method release-testing]
#   scripts/build-ipa.sh                     (no team: unsigned .ipa, for checking the build only)
#
# --team    Your Apple Developer Team ID (developer.apple.com → Membership). Xcode must be signed
#           in to that account (Xcode → Settings → Accounts); signing is automatic.
# --method  How the .ipa will be installed:
#             release-testing    (default) Ad Hoc: devices registered in your account
#             app-store-connect  upload to TestFlight / the App Store
#             debugging          development installs
#
# An unsigned .ipa can't be installed on a device as it is.
set -euo pipefail

team=""
method="release-testing"
while [[ $# -gt 0 ]]; do
  case $1 in
    --team) team=$2; shift 2 ;;
    --method) method=$2; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

root=${0:A:h:h}/ios
dist=$root/dist
build=$root/build/ipa
archive=$build/PhotosShare.xcarchive
# Xcode's tools, even when xcode-select still points at the Command Line Tools.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

rm -rf "$build" && mkdir -p "$build" "$dist"
cd "$root"

if [[ -n $team ]]; then
  echo "Archiving (signed for team $team)…"
  xcodebuild -project PhotosShare.xcodeproj -scheme PhotosShare -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" archive -quiet

  cat > "$build/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$method</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
  echo "Exporting ($method)…"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$build/export" \
    -exportOptionsPlist "$build/ExportOptions.plist" -allowProvisioningUpdates -quiet
  ipa=$(ls "$build"/export/*.ipa)
  out="$dist/Photos Share.ipa"
  mv "$ipa" "$out"
else
  echo "No --team given: building an UNSIGNED .ipa (can't be installed as it is)."
  xcodebuild -project PhotosShare.xcodeproj -scheme PhotosShare -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    CODE_SIGNING_ALLOWED=NO archive -quiet
  mkdir -p "$build/Payload"
  cp -R "$archive/Products/Applications/Photos Share.app" "$build/Payload/"
  out="$dist/Photos Share (unsigned).ipa"
  rm -f "$out"
  (cd "$build" && zip -qry "$out" Payload)
fi

echo "Done: $out"
