#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /private/tmp/garime-selection-pipeline.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fixtures"

swiftc \
  "$ROOT"/Sources/FileTools/Backend/*.swift \
  "$ROOT"/Sources/FileTools/Selection/*.swift \
  "$ROOT"/Sources/FileTools/UI/*.swift \
  "$ROOT/Sources/Feedback/FeedbackCue.swift" \
  "$ROOT/Tests/SelectionPipeline/main.swift" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -o "$TMP/selection-pipeline-tests"

"$TMP/selection-pipeline-tests" "$TMP/fixtures" "$ROOT"
