#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/GarimeWhisper.app"
BIN_DIR="$APP/Contents/MacOS"
TARGET_ARCH="$(uname -m)-apple-macos14.0"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' | sort)
if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "build: no sources found" >&2
  exit 1
fi

echo "build: compiling ${#SOURCES[@]} sources for $TARGET_ARCH"
swiftc \
  -O \
  -target "$TARGET_ARCH" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  -o "$BIN_DIR/GarimeWhisper" \
  "${SOURCES[@]}"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${WHISPER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application)' \
    | head -1 \
    | sed -E 's/.*"(.*)".*/\1/')"
fi
if [ -z "$IDENTITY" ]; then
  echo "build: no codesigning identity found, signing ad-hoc (TCC grants reset on rebuild)" >&2
  IDENTITY="-"
fi

echo "build: signing with ${IDENTITY}"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "build: ok -> $APP"
codesign -dvvv "$APP" 2>&1 | grep -E 'Identifier=|TeamIdentifier=' || true
