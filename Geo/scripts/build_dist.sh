#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
XCODE_PROJECT="$PROJECT_ROOT/Geo.xcodeproj"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Geo.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="Geo"
DMG_NAME="Geo"
BACKGROUND_IMG="$SCRIPT_DIR/assets/dmg-background.png"

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

echo "==> Building archive..."
xcodebuild archive \
    -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    -clonedSourcePackagesDirPath "$SPM_CACHE" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | grep -E "(^\*\*|error:|warning:)" || true

echo "==> Exporting app bundle..."
mkdir -p "$EXPORT_PATH"

cat > "$BUILD_DIR/ExportOptions.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>automatic</string>
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

echo "==> Signing app with ad-hoc signature..."
codesign --force --deep --sign - "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --verbose "$APP_PATH" || echo "Warning: Signature verification returned non-zero"

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

echo ""
echo "==> Build complete!"
echo "    DMG: $BUILD_DIR/$DMG_NAME.dmg"
