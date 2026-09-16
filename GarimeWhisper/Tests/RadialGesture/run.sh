#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET_ARCH="$(uname -m)-apple-macos14.0"
TMP="$(mktemp -d /tmp/garime-radial-gesture.XXXXXX)"

trap 'rm -rf "$TMP"' EXIT

swiftc \
  -target "$TARGET_ARCH" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -o "$TMP/radial-gesture-tests" \
  "$ROOT"/Sources/FileTools/Backend/*.swift \
  "$ROOT"/Sources/FileTools/UI/*.swift \
  "$ROOT"/Sources/FileTools/Selection/*.swift \
  "$ROOT/Sources/Feedback/FeedbackCue.swift" \
  "$ROOT/Tests/RadialGesture/main.swift"

"$TMP/radial-gesture-tests" "$ROOT/Sources/FileTools/UI"
