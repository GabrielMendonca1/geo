#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/garime-filetools-ui-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fixtures"

swiftc \
  "$ROOT"/Sources/FileTools/Backend/*.swift \
  "$ROOT"/Sources/FileTools/UI/*.swift \
  "$ROOT"/Sources/FileTools/Selection/*.swift \
  "$ROOT/Sources/Feedback/FeedbackCue.swift" \
  "$ROOT/Tests/FileToolsUI/main.swift" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -o "$TMP/filetools-ui-tests"

"$TMP/filetools-ui-tests" \
  "$ROOT/Sources/FileTools/Backend/FileToolsBackend.swift" \
  "$TMP/fixtures" \
  "$ROOT/Sources/App/AppDelegate.swift"
