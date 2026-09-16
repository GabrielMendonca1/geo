#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/garime-selection-hotkeys-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

swiftc \
  "$ROOT/Sources/Dictation/Hotkey.swift" \
  "$ROOT/Sources/FileTools/Selection/TangerineSelectionHotKeys.swift" \
  "$ROOT/Tests/SelectionHotKeys/main.swift" \
  -framework Carbon \
  -o "$TMP/selection-hotkeys-tests"

"$TMP/selection-hotkeys-tests" "$ROOT"
