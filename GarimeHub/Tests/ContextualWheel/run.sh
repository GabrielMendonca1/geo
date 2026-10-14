#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/garime-contextual-wheel-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fixtures"

swiftc \
  "$ROOT"/Sources/FileTools/Backend/*.swift \
  "$ROOT"/Sources/FileTools/Selection/*.swift \
  "$ROOT"/Sources/FileTools/UI/*.swift \
  "$ROOT/Sources/Feedback/FeedbackCue.swift" \
  "$ROOT/Tests/ContextualWheel/main.swift" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -o "$TMP/contextual-wheel-tests"

"$TMP/contextual-wheel-tests" "$TMP/fixtures" "$ROOT/Sources/FileTools/UI"
