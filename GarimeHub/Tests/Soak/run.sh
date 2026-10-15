#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src() { find "$ROOT/Sources" -name "$1.swift" | head -1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SESSIONS="${1:-4}"
AUDIO="${SOAK_AUDIO:-}"

if [ -z "$AUDIO" ]; then
  say -v Luciana -o "$TMP/voz.aiff" "Olá, este é um teste do ditado do Garime Hub. Eu quero ver o texto aparecer enquanto eu falo, e não só no final. Vamos medir quanto tempo cada passo leva."
  AUDIO="$TMP/voz.aiff"
fi
/opt/homebrew/bin/ffmpeg -nostdin -hide_banner -loglevel error -y -i "$AUDIO" -ac 1 -ar 16000 -c:a pcm_s16le "$TMP/voz.wav"

swiftc -O -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$TMP/soak" \
  "$(src Config)" \
  "$(src Stabilizer)" \
  "$(src StreamBuffer)" \
  "$(src FlushGuard)" \
  "$(src WindowedDecoder)" \
  "$(src WhisperBackend)" \
  "$(src ProcessRunner)" \
  "$(src DictationSession)" \
  "$(src TextChunker)" \
  "$ROOT/Tests/Soak/main.swift"

HARNESS_WORKDIR="$TMP/work" MallocStackLogging=lite "$TMP/soak" "$TMP/voz.wav" "$SESSIONS"
