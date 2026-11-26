#!/bin/zsh
# Builds the iPhone/iPad app into an .ipa in ios/dist/.
#
#   scripts/build-ipa.sh --team ABCDE12345 [--method release-testing]
#   scripts/build-ipa.sh                     (finds the team on this Mac; none: unsigned .ipa)
#   scripts/build-ipa.sh --unsigned          (just the .ipa, unsigned: for tools that sign it themselves)
#
# --team    Your Apple Developer Team ID. Optional when this Mac knows exactly one team (from its
#           signing certificates or Xcode → Settings → Accounts). Xcode must be signed
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
unsigned=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --team) team=$2; shift 2 ;;
    --method) method=$2; shift 2 ;;
    --unsigned) unsigned=true; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Team IDs this Mac can sign for: from Apple signing certificates in the keychain (their
# "OU" is the team), and from the accounts added in Xcode → Settings → Accounts.
find_teams() {
  local name
  # Each signing identity's certificate: its subject's OU is the team ID.
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Apple|iPhone) (Development|Distribution)[^"]*"' | tr -d '"' | sort -u \
    | while IFS= read -r name; do
        security find-certificate -c "$name" -p 2>/dev/null | team_of_cert
      done
  # Teams of the accounts added in Xcode (the key's name differs between Xcode versions).
  for key in IDEProvisioningTeamByIdentifier IDEProvisioningTeams; do
    defaults read com.apple.dt.Xcode "$key" 2>/dev/null | team_ids_in_xcode_prefs
  done
}
team_of_cert() {
  openssl x509 -noout -subject -nameopt multiline 2>/dev/null | awk -F' = ' '/organizationalUnitName/ {print $2}'
}
team_ids_in_xcode_prefs() {
  grep -oE 'teamID = "?[A-Z0-9]{10}"?' | grep -oE '[A-Z0-9]{10}'
}

if [[ -z $team ]] && ! $unsigned; then
  # "|| true": finding nothing isn't an error (grep reports no match as a failure).
  teams=(${(f)"$(find_teams 2>/dev/null | sort -u || true)"})
  if (( ${#teams} == 1 )); then
    team=$teams[1]
    echo "Using team $team (found on this Mac)."
  elif (( ${#teams} > 1 )); then
    echo "This Mac can sign for several teams: ${teams[*]}" >&2
    echo "Pick one: scripts/build-ipa.sh --team <ID>" >&2
    exit 2
  fi
fi

root=${0:A:h:h}/ios
dist=$root/dist
build=$root/build/ipa
archive=$build/PhotosShare.xcarchive
# Xcode's tools, even when xcode-select still points at the Command Line Tools.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

rm -rf "$build" && mkdir -p "$build" "$dist"
cd "$root"

if [[ -n $team ]] && ! $unsigned; then
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
  echo "Building an UNSIGNED .ipa (a sideloading tool signs it; can't be installed as it is)."
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
