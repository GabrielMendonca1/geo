#!/usr/bin/env bash
# Suite pura do modulo Feedback: sem playback audivel (tudo roda mudo ou so constroi players).
#
# Contrato de supressao verificado aqui: nenhum cue *comeca* depois que beginCapture retornou
# (gate escrito sob o mesmo NSLock que emit re-checa antes de play()). O que NAO e prometido:
# descarte dos frames ja entregues ao HAL de saida. AVAudioPlayer.stop() para o feed, mas a cauda
# fisica ja no buffer do dispositivo (~5-15 ms) pode terminar audivel dentro dos primeiros frames
# da gravacao. Isso e best-effort por limitacao do hardware/CoreAudio, nao um bug do gate, e nao e
# testavel sem tocar som de verdade -- por isso fica documentado aqui em vez de ser afirmado como
# garantia. Com o teto de volume (0.45) a cauda e praticamente inaudivel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET_ARCH="$(uname -m)-apple-macos14.0"
BIN="$(mktemp -t feedback-tests)"

trap 'rm -f "$BIN"' EXIT

swiftc \
  -O \
  -target "$TARGET_ARCH" \
  -sdk "$SDK" \
  -o "$BIN" \
  "$ROOT/Sources/Feedback/FeedbackCue.swift" \
  "$ROOT/Sources/Feedback/FeedbackPreferences.swift" \
  "$ROOT/Sources/Feedback/FeedbackPolicy.swift" \
  "$ROOT/Sources/Feedback/FeedbackVoice.swift" \
  "$ROOT/Sources/Feedback/SoundFeedback.swift" \
  "$ROOT/Tests/Feedback/main.swift"

"$BIN"
