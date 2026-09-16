#!/usr/bin/env bash
set -euo pipefail

# Independent review harness for the Mac Duo menu surface.
# It never starts the lid sensor, never opens a window and never touches
# ScreenCaptureKit or the Screen Recording permission.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET_ARCH="$(uname -m)-apple-macos14.0"
BIN="$(mktemp -t macduo-menu-review-tests)"

trap 'rm -f "$BIN"' EXIT

swiftc \
  -O \
  -target "$TARGET_ARCH" \
  -sdk "$SDK" \
  -o "$BIN" \
  "$ROOT"/Sources/MacDuo/*.swift \
  "$ROOT/Tests/MacDuoMenuReview/main.swift"

"$BIN"
