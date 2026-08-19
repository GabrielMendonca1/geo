#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "${1:-}" = "--gravar" ]; then
  SECONDS_TO_RECORD="${2:-30}"
  TARGET="${3:-$HOME/Downloads/ditado-bench.wav}"
  DEVICE="${BENCH_MIC:-1}"
  echo "gravando ${SECONDS_TO_RECORD}s do dispositivo :${DEVICE} — fale normalmente"
  /opt/homebrew/bin/ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f avfoundation -i ":${DEVICE}" -t "$SECONDS_TO_RECORD" \
    -ac 1 -ar 16000 -c:a pcm_s16le "$TARGET"
  echo "pronto: $TARGET"
  echo "agora rode: $0 $TARGET"
  exit 0
fi

AUDIO="${1:?uso: bench.sh <audio.wav|audio.m4a> [agreementSteps] [stepSeconds]   |   bench.sh --gravar [segundos] [destino]}"
STEPS="${2:-}"
STEP_SECONDS="${3:-}"

WAV="$TMP/bench.wav"
/opt/homebrew/bin/ffmpeg -nostdin -hide_banner -loglevel error -y \
  -i "$AUDIO" -ac 1 -ar 16000 -c:a pcm_s16le "$WAV"

echo "== compilando o banco de ensaio =="
swiftc -O -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$TMP/bench" \
  "$ROOT/Sources/Config.swift" \
  "$ROOT/Sources/Stabilizer.swift" \
  "$ROOT/Sources/StreamBuffer.swift" \
  "$ROOT/Sources/FlushGuard.swift" \
  "$ROOT/Sources/WindowedDecoder.swift" \
  "$ROOT/Sources/WhisperBackend.swift" \
  "$ROOT/Sources/ProcessRunner.swift" \
  "$ROOT/Tests/Bench/main.swift"

echo "== referência em lote (whisper -mc 0) =="
REF="$TMP/ref.txt"
/opt/homebrew/bin/whisper-cli -m "$HOME/.cache/whisper/ggml-large-v3-turbo.bin" \
  -f "$WAV" -l pt -mc 0 -np 2>/dev/null | sed 's/\[[^]]*\]//g' > "$REF"
echo "palavras na referência: $(wc -w < "$REF")"

echo "== replay em tempo real =="
BENCH_OUTPUT="$TMP/stream.txt" "$TMP/bench" "$WAV" ${STEPS:+"$STEPS"} ${STEP_SECONDS:+"$STEP_SECONDS"}

echo "== distância do streaming para a referência =="
python3 - "$REF" "$TMP/stream.txt" <<'PY'
import re, sys, difflib
def words(path):
    text = open(path, encoding="utf-8").read().lower()
    return re.findall(r"[0-9a-zà-ÿ]+", text)
ref, hyp = words(sys.argv[1]), words(sys.argv[2])
matcher = difflib.SequenceMatcher(None, ref, hyp, autojunk=False)
kept = sum(block.size for block in matcher.get_matching_blocks())
print(f"referência={len(ref)} streaming={len(hyp)} palavras iguais={kept}")
if ref:
    print(f"WER aproximado: {100 * (1 - kept / len(ref)):.1f}%")
PY
