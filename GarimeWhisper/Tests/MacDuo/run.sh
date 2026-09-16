#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET_ARCH="$(uname -m)-apple-macos14.0"
BIN="$(mktemp -t macduo-tests)"

trap 'rm -f "$BIN"' EXIT

swiftc \
  -O \
  -target "$TARGET_ARCH" \
  -sdk "$SDK" \
  -o "$BIN" \
  "$ROOT"/Sources/MacDuo/*.swift \
  "$ROOT/Tests/MacDuo/main.swift"

"$BIN"
