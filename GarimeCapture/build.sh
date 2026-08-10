#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
BIN="$BUILD/garimecapture"
TARGET_ARCH="$(uname -m)-apple-macos14.0"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

mkdir -p "$BUILD"

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
  -framework CoreGraphics \
  -framework ImageIO \
  -framework Vision \
  -o "$BIN" \
  "${SOURCES[@]}"

IDENTITY="${CAPTURE_SIGN_IDENTITY:-}"
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
codesign --force --timestamp=none --sign "$IDENTITY" "$BIN"
codesign --verify --strict "$BIN"

echo "build: ok -> $BIN"
codesign -dvvv "$BIN" 2>&1 | grep -E 'Identifier=|TeamIdentifier=' || true
