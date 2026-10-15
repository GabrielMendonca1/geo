#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/garime-floating-radial-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
OUT="${1:-/tmp/whisper-floating-shots}"
mkdir -p "$OUT"

# Escopo fechado: catálogo (backend das opções) + o protocolo da superfície do overlay.
swiftc \
  "$ROOT/Sources/FileTools/UI/FilesCatalog.swift" \
  "$ROOT/Sources/FileTools/UI/FilesTheme.swift" \
  "$ROOT/Sources/FileTools/UI/FilesWheelPlacement.swift" \
  "$ROOT/Sources/FileTools/UI/FloatingRadialView.swift" \
  "$ROOT/Tests/FloatingRadial/main.swift" \
  -framework AppKit \
  -framework QuartzCore \
  -o "$TMP/floating-radial-tests"

"$TMP/floating-radial-tests" "$OUT"
