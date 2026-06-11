#!/bin/zsh
# asc-upload.sh — archive the sandboxed BlipAppStore target and upload the build
# to App Store Connect, fully headless.
#
# Unlike the shared local-ci-archive.sh, this passes the App Store Connect API
# key to xcodebuild's provisioning updates (-authenticationKey*), so xcodebuild
# can create/download the team's development certificate and the
# com.blainemiller.Blip provisioning profiles on its own — no Xcode account
# session, no pre-existing profile required.
#
# Requirements:
#   - ASC_API_KEY_ID, ASC_API_ISSUER_ID env vars (kept in your zsh profile)
#   - API key at ~/.appstoreconnect/private_keys/AuthKey_<ASC_API_KEY_ID>.p8
#     (the key's role must be able to manage certs/profiles, e.g. App Manager)
#
# Usage:  ./Scripts/asc-upload.sh
set -euo pipefail

cd "${0:A:h}/.."

# Coverage gate: the hermetic BlipTests suite must pass (and stay above the
# coverage ratchet) before anything is archived for App Store Connect.
# Skip with SKIP_COVERAGE_GATE=1 only for emergency re-uploads.
if [[ "${SKIP_COVERAGE_GATE:-0}" != "1" ]]; then
  ./Scripts/coverage-check.sh
fi

TEAM_ID="8ZVSPZYSVF"
SCHEME="BlipAppStore"
KEY_ID="${ASC_API_KEY_ID:?set ASC_API_KEY_ID}"
ISSUER_ID="${ASC_API_ISSUER_ID:?set ASC_API_ISSUER_ID}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
[[ -f "$KEY_PATH" ]] || { print "✗ missing API key: $KEY_PATH"; exit 1 }

OUT="${TMPDIR:-/tmp}/blip-asc"
ARCHIVE="$OUT/BlipAppStore.xcarchive"
EXPORT="$OUT/export"
OPTS="$OUT/ExportOptions.plist"
mkdir -p "$OUT"

AUTH=(
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$KEY_ID"
  -authenticationKeyIssuerID "$ISSUER_ID"
  -allowProvisioningUpdates
)

print "▶ regenerating project"
xcodegen generate >/dev/null

print "▶ archiving $SCHEME (Release, automatic signing via ASC API)"
rm -rf "$ARCHIVE"
xcodebuild \
  -project Blip.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$OUT/dd" \
  "${AUTH[@]}" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

print "▶ ensuring App Store distribution profile (via ASC API)"
# Creates/installs the MAC_APP_STORE profile for the bundle id if missing.
# Prints "NAME<TAB>UUID<TAB>PATH"; we only need the NAME for the export map.
PROFILE_NAME=$("${0:A:h}/asc-ensure-profile.py" | cut -f1)
[[ -n "$PROFILE_NAME" ]] || { print "✗ could not resolve App Store profile"; exit 1 }
print "  profile: $PROFILE_NAME"

print "▶ exporting for App Store Connect (manual: distribution + installer certs)"
cat > "$OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
  <key>provisioningProfiles</key>
  <dict><key>com.blainemiller.Blip</key><string>${PROFILE_NAME}</string></dict>
  <key>uploadSymbols</key><true/>
  <key>compileBitcode</key><false/>
</dict>
</plist>
EOF

rm -rf "$EXPORT"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTS" \
  -exportPath "$EXPORT"

PKG=$(find "$EXPORT" -maxdepth 1 \( -name '*.pkg' -o -name '*.ipa' \) | head -1)
[[ -n "$PKG" ]] || { print "✗ export produced no .pkg"; exit 1 }
print "▶ uploading $(basename "$PKG") → App Store Connect"
xcrun altool --upload-app -f "$PKG" -t macos \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

print "✓ uploaded to App Store Connect"
