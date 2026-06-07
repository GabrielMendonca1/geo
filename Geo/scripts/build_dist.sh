#!/bin/bash
set -euo pipefail

# Builds a distributable Geo DMG. Signing mode is selected automatically:
#
#   developer-id  when DEVELOPER_ID_APP (+ TEAM_ID) are set — hardened-runtime,
#                 timestamped signature, ready for notarize.sh. REQUIRES a paid
#                 Apple Developer Program membership (the Developer ID cert).
#
#   adhoc         the fallback when no Developer ID is available — a fully working,
#                 locally-runnable DMG. Not notarizable; Gatekeeper shows
#                 "unidentified developer" until notarized.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
XCODE_PROJECT="$REPO_ROOT/Geo.xcodeproj"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Geo.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="${APP_NAME:-Geo}"
DMG_NAME="${DMG_NAME:-Geo}"
BACKGROUND_IMG="$SCRIPT_DIR/assets/dmg-background.png"
ENTITLEMENTS="$REPO_ROOT/Geo/App/Geo.entitlements"
SPM_CACHE="$BUILD_DIR/spm-cache"

DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-}"
TEAM_ID="${TEAM_ID:-}"

if [ -n "$DEVELOPER_ID_APP" ]; then
    : "${TEAM_ID:?Set TEAM_ID alongside DEVELOPER_ID_APP for Developer ID signing}"
    SIGN_MODE="developer-id"
    SIGN_IDENTITY="$DEVELOPER_ID_APP"
else
    SIGN_MODE="adhoc"
    SIGN_IDENTITY="-"
fi
echo "==> Signing mode: $SIGN_MODE"

echo "==> Cleaning previous build artifacts..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Cleaning Xcode build products..."
xcodebuild clean \
    -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    2>/dev/null || true

echo "==> Building archive ($SIGN_MODE signing)..."
ARCHIVE_FLAGS=( CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" PROVISIONING_PROFILE_SPECIFIER="" )
if [ "$SIGN_MODE" = "developer-id" ]; then
    ARCHIVE_FLAGS+=( DEVELOPMENT_TEAM="$TEAM_ID" OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" )
else
    ARCHIVE_FLAGS+=( DEVELOPMENT_TEAM="" )
fi

xcodebuild archive \
    -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    -clonedSourcePackagesDirPath "$SPM_CACHE" \
    "${ARCHIVE_FLAGS[@]}" \
    | grep -E "(^\*\*|error:|warning:)" || true

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
mkdir -p "$EXPORT_PATH"

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "==> Exporting app bundle..."
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
fi

if [ ! -d "$APP_PATH" ]; then
    echo "==> Copying app from archive..."
    cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/"
fi

if [ "$SIGN_MODE" = "developer-id" ]; then
    SIGN_FLAGS=( --force --timestamp --options runtime )
else
    SIGN_FLAGS=( --force )
fi

echo "==> Deep-signing embedded bundles (inside-out)..."
find "$APP_PATH/Contents" \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' -o -name '*.bundle' \) \
    -print0 | while IFS= read -r -d '' item; do
    echo "    signing $item"
    codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$item"
done

echo "==> Signing app bundle ($SIGN_MODE) with entitlements..."
codesign "${SIGN_FLAGS[@]}" \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "==> Asserting hardened runtime is present..."
    if ! codesign -dvvv "$APP_PATH" 2>&1 | grep -q 'flags=.*runtime'; then
        echo "ERROR: hardened runtime flag missing from signed app" >&2
        exit 1
    fi
fi

VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
BUILD_NUM="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion)"

echo "==> Creating DMG (Geo $VERSION, build $BUILD_NUM)..."
rm -f "$BUILD_DIR/$DMG_NAME.dmg"

create-dmg \
    --volname "$APP_NAME $VERSION" \
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
if [ "$SIGN_MODE" = "developer-id" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$BUILD_DIR/$DMG_NAME.dmg"
else
    codesign --force --sign "$SIGN_IDENTITY" "$BUILD_DIR/$DMG_NAME.dmg"
fi

echo "==> Emitting SHA256..."
shasum -a 256 "$BUILD_DIR/$DMG_NAME.dmg" > "$BUILD_DIR/$DMG_NAME.dmg.sha256"

echo ""
echo "==> Build complete: Geo $VERSION (build $BUILD_NUM) — $SIGN_MODE"
echo "    DMG:    $BUILD_DIR/$DMG_NAME.dmg"
echo "    SHA256: $BUILD_DIR/$DMG_NAME.dmg.sha256"
if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "    Next:   NOTARY_PROFILE=<profile> bash $SCRIPT_DIR/notarize.sh \"$BUILD_DIR/$DMG_NAME.dmg\""
else
    echo ""
    echo "    This is an AD-HOC build — fully runnable locally. The ONLY thing missing"
    echo "    for a notarized, Gatekeeper-trusted release is a paid Apple Developer"
    echo "    Program membership:"
    echo "      1. Enroll at developer.apple.com, create a 'Developer ID Application' cert."
    echo "      2. export DEVELOPER_ID_APP='Developer ID Application: <Name> (<TEAMID>)' TEAM_ID=<TEAMID>"
    echo "      3. Re-run this script, then:"
    echo "         NOTARY_PROFILE=<profile> bash $SCRIPT_DIR/notarize.sh \"$BUILD_DIR/$DMG_NAME.dmg\""
fi
