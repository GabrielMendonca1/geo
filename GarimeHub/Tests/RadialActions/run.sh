#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/garime-radial-actions.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

swiftc \
  "$ROOT"/Sources/FileTools/Backend/*.swift \
  "$ROOT"/Sources/FileTools/UI/*.swift \
  "$ROOT"/Sources/FileTools/Selection/*.swift \
  "$ROOT/Sources/Feedback/FeedbackCue.swift" \
  "$ROOT/Tests/RadialActions/main.swift" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -o "$TMP/radial-actions-tests"

"$TMP/radial-actions-tests"
