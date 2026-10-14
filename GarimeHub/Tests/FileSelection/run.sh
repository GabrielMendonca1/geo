#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/garime-file-selection-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

swiftc \
  "$ROOT"/Sources/FileTools/Selection/*.swift \
  "$ROOT/Tests/FileSelection/main.swift" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -o "$TMP/file-selection-tests"

"$TMP/file-selection-tests" "$ROOT/Sources/FileTools/Selection"
for key in NSAppleEventsUsageDescription NSDesktopFolderUsageDescription NSDocumentsFolderUsageDescription NSDownloadsFolderUsageDescription; do
  value="$(plutil -extract "$key" raw -o - "$ROOT/Resources/Info.plist")"
  test -n "$value" || { echo "FAIL missing usage description: $key"; exit 1; }
done
echo 'FileSelection: 4 permission descriptions present'
