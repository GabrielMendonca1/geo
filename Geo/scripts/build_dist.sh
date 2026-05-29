#!/bin/bash
set -euo pipefail

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID (e.g. ABCDE12345)}"
: "${DEVELOPER_ID_APP:?Set DEVELOPER_ID_APP to the full identity, e.g. 'Developer ID Application: Gabriel Mendonca (ABCDE12345)'}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
XCODE_PROJECT="$PROJECT_ROOT/Geo.xcodeproj"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Geo.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="${APP_NAME:-Geo}"
DMG_NAME="${DMG_NAME:-Geo}"
BACKGROUND_IMG="$SCRIPT_DIR/assets/dmg-background.png"
ENTITLEMENTS="$PROJECT_ROOT/Geo/App/Geo.entitlements"

echo "==> Cleaning previous build artifacts..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Cleaning Xcode build products..."
xcodebuild clean \
    -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    2>/dev/null || true

SPM_CACHE="$BUILD_DIR/spm-cache"

echo "==> Building archive (Developer ID signing)..."
xcodebuild archive \
    -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    -clonedSourcePackagesDirPath "$SPM_CACHE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    | grep -E "(^\*\*|error:|warning:)" || true

echo "==> Exporting app bundle..."
mkdir -p "$EXPORT_PATH"

cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>hardenedRuntime</key>
    <true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    | grep -E "(^\*\*|error:|warning:)" || true

APP_PATH="$EXPORT_PATH/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "==> Export failed, copying from archive..."
    cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/"
fi

echo "==> Deep-signing embedded bundles (inside-out)..."
find "$APP_PATH/Contents" \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' -o -name '*.bundle' \) \
    -print0 | while IFS= read -r -d '' item; do
    echo "    signing $item"
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APP" "$item"
done

echo "==> Signing app bundle with hardened runtime + entitlements..."
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APP" \
    "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Asserting hardened runtime is present..."
if ! codesign -dvvv "$APP_PATH" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "ERROR: hardened runtime flag missing from signed app" >&2
    exit 1
fi

echo "==> Creating DMG..."
rm -f "$BUILD_DIR/$DMG_NAME.dmg"

create-dmg \
    --volname "$DMG_NAME" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 120 \
    --icon "$APP_NAME.app" 175 195 \
    --app-drop-link 485 195 \
    --background "$BACKGROUND_IMG" \
    --no-internet-enable \
    "$BUILD_DIR/$DMG_NAME.dmg" \
    "$APP_PATH"

echo "==> Signing DMG..."
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$BUILD_DIR/$DMG_NAME.dmg"

echo "==> Emitting SHA256..."
shasum -a 256 "$BUILD_DIR/$DMG_NAME.dmg" > "$BUILD_DIR/$DMG_NAME.dmg.sha256"

echo ""
echo "==> Build complete!"
echo "    DMG:    $BUILD_DIR/$DMG_NAME.dmg"
echo "    SHA256: $BUILD_DIR/$DMG_NAME.dmg.sha256"
echo "    Next:   NOTARY_PROFILE=<profile> bash $SCRIPT_DIR/notarize.sh \"$BUILD_DIR/$DMG_NAME.dmg\""
