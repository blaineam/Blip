#!/usr/bin/env bash
set -euo pipefail

# Blip — Local build & package script (styled DMG)
# Usage: ./Scripts/build-dmg.sh [--skip-notarize]

SKIP_NOTARIZE=false
if [[ "${1:-}" == "--skip-notarize" ]]; then
    SKIP_NOTARIZE=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
DIST_DIR="$PROJECT_DIR/dist"

cd "$PROJECT_DIR"

echo "=== Blip Build Script ==="

# 1. Generate project
echo "→ Generating Xcode project..."
xcodegen generate

# 2. Generate assets (icon + DMG background)
echo "→ Generating brand assets..."
mkdir -p "$BUILD_DIR/assets"
swift Scripts/generate-assets.swift "$BUILD_DIR/assets"

# 3. Find signing identity
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
if [[ -z "$IDENTITY" ]]; then
    echo "⚠ No Developer ID found. Building unsigned."
    IDENTITY="-"
fi
echo "→ Signing with: $IDENTITY"

# 3b. Strip extended attributes (iCloud Drive adds com.apple.provenance)
echo "→ Stripping extended attributes..."
find "$PROJECT_DIR" -not -path "$PROJECT_DIR/.git/*" -not -path "$PROJECT_DIR/.build/*" -exec xattr -c {} \; 2>/dev/null || true

# 4. Build
echo "→ Building release..."
xcodebuild -scheme Blip -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -arch arm64 \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/Blip.app"
echo "→ Built: $APP_PATH"

# 5. Inject generated icon (fallback if asset catalog didn't produce one)
if [[ -f "$BUILD_DIR/assets/Blip.icns" ]]; then
    echo "→ Injecting app icon..."
    mkdir -p "$APP_PATH/Contents/Resources"
    cp "$BUILD_DIR/assets/Blip.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_PATH/Contents/Info.plist"
fi

# 6. Clean xattrs (needed if on iCloud Drive)
STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING/"
xattr -cr "$STAGING/Blip.app"

# 7. Codesign the staged app (proper signing after xattr cleanup)
if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --deep --sign "$IDENTITY" --timestamp --options runtime "$STAGING/Blip.app"
else
    codesign --force --deep --sign - "$STAGING/Blip.app"
fi

# 8. Create styled DMG
echo "→ Packaging styled DMG..."
mkdir -p "$DIST_DIR"

DMG_TEMP="$BUILD_DIR/blip-temp.dmg"
DMG_FINAL="$DIST_DIR/Blip.dmg"
VOLUME_NAME="Blip"

# Create writable DMG
hdiutil create -size 50m -fs HFS+ -volname "$VOLUME_NAME" -ov "$DMG_TEMP"

# Mount it
MOUNT_POINT=$(hdiutil attach "$DMG_TEMP" -readwrite -noverify -noautoopen | grep "$VOLUME_NAME" | awk '{print $NF}' | head -1)
if [[ -z "$MOUNT_POINT" ]]; then
    MOUNT_POINT="/Volumes/$VOLUME_NAME"
fi

# Copy app
cp -R "$STAGING/Blip.app" "$MOUNT_POINT/"

# Create Applications alias
osascript -e "tell application \"Finder\" to make alias file to POSIX file \"/Applications\" at POSIX file \"$MOUNT_POINT\"" 2>/dev/null || \
    ln -s /Applications "$MOUNT_POINT/Applications"

# Copy DMG background if generated
if [[ -f "$BUILD_DIR/assets/dmg-background.jpg" ]]; then
    mkdir -p "$MOUNT_POINT/.background"
    cp "$BUILD_DIR/assets/dmg-background.jpg" "$MOUNT_POINT/.background/background.jpg"
fi

# Style the DMG window via AppleScript
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Blip"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 760, 500}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        try
            set background picture of theViewOptions to file ".background:background.jpg"
        end try
        set position of item "Blip.app" of container window to {145, 185}
        set position of item "Applications" of container window to {515, 185}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT

# Detach
sync
hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
sleep 1

# Convert to compressed DMG
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" -ov
rm -f "$DMG_TEMP"

# Sign DMG
if [[ "$IDENTITY" != "-" ]]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG_FINAL"
fi

# Clean up staging
rm -rf "$STAGING"

# 9. Notarize
if [[ "$SKIP_NOTARIZE" == false && "$IDENTITY" != "-" ]]; then
    echo "→ Notarizing..."
    xcrun notarytool submit "$DMG_FINAL" \
        --keychain-profile "blip-notarize" \
        --wait
    xcrun stapler staple "$DMG_FINAL"
    echo "✓ Notarized and stapled"
else
    echo "→ Skipping notarization"
fi

BINARY_SIZE=$(stat -f%z "$APP_PATH/Contents/MacOS/Blip")
DMG_SIZE=$(stat -f%z "$DMG_FINAL")
echo ""
echo "=== Build Complete ==="
echo "Binary: $(( BINARY_SIZE / 1024 )) KB"
echo "DMG:    $(( DMG_SIZE / 1024 )) KB"
echo "Output: $DMG_FINAL"
