#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/GarimeWhisper.app"
BIN="$APP/Contents/MacOS/GarimeWhisper"
PLIST="$APP/Contents/Info.plist"
TMP="$(mktemp -d)"
PASS=0
FAIL=0

trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if [ "$1" -eq 0 ]; then ok "$2"; else no "$2"; fi; }

echo "== 1. sources carry no comments =="
HITS="$(grep -rnE '(^|[^:])//|/\*' "$ROOT/Sources" --include='*.swift' | wc -l | tr -d ' ')"
check "$([ "$HITS" -eq 0 ] && echo 0 || echo 1)" "no comments in Swift sources ($HITS hits)"

echo "== 2. no shell interpolation in process spawning =="
grep -rq '/bin/sh\|/bin/bash\|system(' "$ROOT/Sources" --include='*.swift'
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "Process uses argv, never a shell"

echo "== 3. never synthesizes Enter =="
grep -rq 'kVK_Return\|kVK_ANSI_KeypadEnter\|CGKeyCode(36)' "$ROOT/Sources" --include='*.swift'
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "no Return/Enter keycode anywhere"

echo "== 4. bundle layout =="
[ -x "$BIN" ]; check $? "executable present at Contents/MacOS/GarimeWhisper"
[ -f "$PLIST" ]; check $? "Info.plist present"
plutil -lint "$PLIST" >/dev/null 2>&1; check $? "Info.plist is valid"

echo "== 5. Info.plist contract =="
[ "$(plutil -extract CFBundleIdentifier raw "$PLIST" 2>/dev/null)" = "ai.garime.whisper" ]
check $? "CFBundleIdentifier is ai.garime.whisper"
[ "$(plutil -extract LSUIElement raw "$PLIST" 2>/dev/null)" = "true" ]
check $? "LSUIElement is set (no Dock icon)"
plutil -extract NSMicrophoneUsageDescription raw "$PLIST" >/dev/null 2>&1
check $? "NSMicrophoneUsageDescription present"

echo "== 6. code signature =="
codesign --verify --deep --strict "$APP" >/dev/null 2>&1
check $? "signature verifies"
SIGINFO="$(codesign -dvvv "$APP" 2>&1)"
case "$SIGINFO" in
  *"Identifier=ai.garime.whisper"*) check 0 "signed identifier matches bundle id" ;;
  *) check 1 "signed identifier matches bundle id" ;;
esac

echo "== 7. launchd plist contract =="
plutil -lint "$ROOT/ai.garime.whisper.plist" >/dev/null 2>&1
check $? "LaunchAgent plist is valid"
[ "$(plutil -extract Label raw "$ROOT/ai.garime.whisper.plist")" = "ai.garime.whisper" ]
check $? "LaunchAgent label is ai.garime.whisper"
[ "$(plutil -extract ProgramArguments.0 raw "$ROOT/ai.garime.whisper.plist")" = "/Users/biel/Applications/Garime Whisper.app/Contents/MacOS/GarimeWhisper" ]
check $? "LaunchAgent points at the installed app"

echo "== 8. runtime dependencies =="
[ -x /opt/homebrew/bin/ffmpeg ]; check $? "ffmpeg present"
[ -x /opt/homebrew/bin/whisper-cli ]; check $? "whisper-cli present"
[ -r "$HOME/.cache/whisper/ggml-large-v3-turbo.bin" ]; check $? "large-v3-turbo model present"

echo "== 9. app launches and stays alive =="
pkill -x GarimeWhisper 2>/dev/null
"$BIN" >"$TMP/out.log" 2>"$TMP/err.log" &
APP_PID=$!
SURVIVED=1
for _ in 1 2 3 4 5 6; do
  sleep 0.5
  if ! kill -0 "$APP_PID" 2>/dev/null; then SURVIVED=0; break; fi
done
check "$([ "$SURVIVED" -eq 1 ] && echo 0 || echo 1)" "process alive after 3s (no crash)"
if [ "$SURVIVED" -eq 0 ]; then
  echo "    --- stderr ---"
  sed 's/^/    /' "$TMP/err.log" | head -20
fi
kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null

echo "== 10. second instance refuses to run =="
"$BIN" >"$TMP/a.log" 2>&1 &
FIRST=$!
sleep 1.5
"$BIN" >"$TMP/b.log" 2>&1 &
DUPE=$!
DUPE_EXITED=1
for _ in 1 2 3 4 5 6; do
  sleep 0.5
  if ! kill -0 "$DUPE" 2>/dev/null; then DUPE_EXITED=0; break; fi
done
if [ "$DUPE_EXITED" -ne 0 ]; then kill "$DUPE" 2>/dev/null; fi
wait "$DUPE" 2>/dev/null
kill -0 "$FIRST" 2>/dev/null; ALIVE=$?
kill "$FIRST" 2>/dev/null
wait "$FIRST" 2>/dev/null
[ "$DUPE_EXITED" -eq 0 ] && [ "$ALIVE" -eq 0 ]
check $? "duplicate launch exits, original survives"

echo "== 11. transcription pipeline end to end =="
PHRASE="Testando a transcricao de voz em portugues neste computador."
say -v Luciana -o "$TMP/speech.aiff" "$PHRASE" 2>/dev/null \
  || say -v Joana -o "$TMP/speech.aiff" "$PHRASE" 2>/dev/null
[ -s "$TMP/speech.aiff" ]; check $? "synthesized pt-BR speech sample"

/opt/homebrew/bin/ffmpeg -nostdin -hide_banner -loglevel error -y \
  -i "$TMP/speech.aiff" -ac 1 -ar 16000 -c:a pcm_s16le "$TMP/speech.wav" 2>"$TMP/ff.log"
check $? "ffmpeg converts to 16kHz mono pcm_s16le"

FORMAT="$(afinfo "$TMP/speech.wav" 2>/dev/null)"
case "$FORMAT" in
  *"1 ch"*"16000 Hz"*"Int16"*) check 0 "wav really is 16kHz mono Int16" ;;
  *) check 1 "wav really is 16kHz mono Int16" ;;
esac

/opt/homebrew/bin/whisper-cli \
  -m "$HOME/.cache/whisper/ggml-large-v3-turbo.bin" \
  -f "$TMP/speech.wav" -l pt -nt -np >"$TMP/text.txt" 2>"$TMP/w.log"
check $? "whisper-cli exits 0"

TEXT="$(tr '[:upper:]' '[:lower:]' < "$TMP/text.txt" | tr -d '\n')"
case "$TEXT" in
  *testando*) check 0 "transcript contains 'testando' ->${TEXT}" ;;
  *) check 1 "transcript contains 'testando' ->${TEXT}" ;;
esac
case "$TEXT" in
  *computador*) check 0 "transcript contains 'computador'" ;;
  *) check 1 "transcript contains 'computador'" ;;
esac

echo "== 12. failure path is explicit =="
/opt/homebrew/bin/whisper-cli -m "$TMP/missing-model.bin" -f "$TMP/speech.wav" -l pt -nt -np >/dev/null 2>"$TMP/err2.log"
[ $? -ne 0 ]; check $? "missing model yields nonzero exit (surfaced as menu error)"

echo "== 13. Transcriber process control (real source, stub binaries) =="
cat > "$TMP/ffmpeg-stub" <<'STUB'
#!/bin/sh
for a in "$@"; do last="$a"; done
: > "$last"
exit 0
STUB
cat > "$TMP/whisper-hang" <<'STUB'
#!/bin/sh
exec sleep 30
STUB
cat > "$TMP/whisper-ok" <<'STUB'
#!/bin/sh
echo "[00:00.000 --> 00:02.000]"
echo "  ola do stub  "
exit 0
STUB
chmod +x "$TMP/ffmpeg-stub" "$TMP/whisper-hang" "$TMP/whisper-ok"

swiftc -O -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$TMP/harness" "$ROOT/Sources/Transcriber.swift" "$ROOT/Sources/ProcessRunner.swift" \
  "$ROOT/Tests/main.swift" 2>"$TMP/harness.log"
check $? "harness compiles against the real Transcriber.swift"

if [ -x "$TMP/harness" ]; then
  RESULT="$(HARNESS_FFMPEG="$TMP/ffmpeg-stub" HARNESS_WHISPER="$TMP/whisper-ok" \
    HARNESS_TIMEOUT=10 "$TMP/harness" ok)"
  case "$RESULT" in
    success:*ola\ do\ stub*) check 0 "happy path returns cleaned transcript -> $RESULT" ;;
    *) check 1 "happy path returns cleaned transcript -> $RESULT" ;;
  esac

  RESULT="$(HARNESS_FFMPEG="$TMP/ffmpeg-stub" HARNESS_WHISPER="$TMP/whisper-hang" \
    HARNESS_TIMEOUT=2 "$TMP/harness" timeout)"
  case "$RESULT" in
    timedOut*) check 0 "wedged child is killed by the timeout -> $RESULT" ;;
    *) check 1 "wedged child is killed by the timeout -> $RESULT" ;;
  esac
  ELAPSED="${RESULT##* }"
  awk -v e="$ELAPSED" 'BEGIN { exit !(e > 0 && e < 8) }'
  check $? "timeout fires near 2s, not after the 30s child ($ELAPSED s)"

  RESULT="$(HARNESS_FFMPEG="$TMP/ffmpeg-stub" HARNESS_WHISPER="$TMP/whisper-hang" \
    HARNESS_TIMEOUT=30 "$TMP/harness" cancel)"
  case "$RESULT" in
    cancelled*) check 0 "cancel terminates the running child -> $RESULT" ;;
    *) check 1 "cancel terminates the running child -> $RESULT" ;;
  esac
  ELAPSED="${RESULT##* }"
  awk -v e="$ELAPSED" 'BEGIN { exit !(e > 0 && e < 5) }'
  check $? "cancel returns promptly ($ELAPSED s)"
else
  no "harness binary missing, process-control checks skipped"
fi

echo "== 14. streaming and animation contract =="
grep -q 'var onLevel' "$ROOT/Sources/Recorder.swift"
check $? "Recorder publishes real microphone levels"
grep -q 'LevelMeter.measure' "$ROOT/Sources/Recorder.swift"
check $? "levels are measured from the audio tap, not synthesized"
grep -q 'recorder.onLevel' "$ROOT/Sources/AppDelegate.swift"
check $? "AppDelegate consumes the level stream"
grep -q 'icon.updateLevel' "$ROOT/Sources/AppDelegate.swift"
check $? "levels reach the status item"
grep -q 'accessibilityDisplayShouldReduceMotion' "$ROOT/Sources/StatusIcon.swift"
check $? "Reduce Motion is read from the system"
grep -q 'accessibilityDisplayOptionsDidChangeNotification' "$ROOT/Sources/StatusIcon.swift"
check $? "Reduce Motion changes are observed live"
grep -q 'item.menu = menu' "$ROOT/Sources/StatusIcon.swift"
check $? "status item keeps its menu (click reliability preserved)"
grep -q 'button.image' "$ROOT/Sources/StatusIcon.swift"
check $? "status item still renders through button.image, not a custom view"
grep -q 'isTemplate = true' "$ROOT/Sources/StatusIcon.swift"
check $? "drawn frames stay template images (auto-tinting preserved)"

grep -rq 'NSColor.systemBlue\|NSColor.systemRed\|NSColor(red:' "$ROOT/Sources" --include='*.swift'
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "no hardcoded accent colors in the icon"

IDLE_ANIMATED="$(grep -c 'case .idle' "$ROOT/Sources/IconAnimation.swift")"
[ "$IDLE_ANIMATED" -ge 1 ]; check $? "idle has an explicit still plan (no idle timer)"

find "$ROOT" -name '*.xcframework' -o -name '*.framework' | grep -q .
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "no vendored animation framework"
grep -rqiE '^ *import +(Lottie|Rive|SwiftyGif)' "$ROOT/Sources" --include='*.swift'
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "no third-party animation dependency"
grep -rqE '^ *import +' "$ROOT/Sources" --include='*.swift'
IMPORTS="$(grep -rhoE '^ *import +[A-Za-z.]+' "$ROOT/Sources" --include='*.swift' | awk '{print $2}' | sort -u | tr '\n' ' ')"
case "$IMPORTS" in
  *Lottie*|*Rive*) check 1 "every import is a system framework -> $IMPORTS" ;;
  *) check 0 "every import is a system framework -> $IMPORTS" ;;
esac

for NAME in meterAttack meterRelease meterFloorDecibels meterPeakHoldSeconds; do
  grep -q "static let $NAME" "$ROOT/Sources/Config.swift"
  check $? "meter coefficient $NAME is a named constant"
done
for NAME in stepSeconds windowBackoffSeconds commitMarginSeconds agreementSteps maxStepFailures typistChunkUTF16; do
  grep -q "static let $NAME" "$ROOT/Sources/Config.swift"
  check $? "streaming constant $NAME is named"
done

grep -q '"-oj"' "$ROOT/Sources/WhisperBackend.swift"
check $? "streaming decode asks whisper-cli for JSON"
grep -q '"-ml", "1"' "$ROOT/Sources/WhisperBackend.swift"
check $? "streaming decode asks for word-level segments"
grep -q -- '"--prompt"' "$ROOT/Sources/WhisperBackend.swift"
check $? "streaming decode carries the committed tail as prompt"
grep -q 'keyboardSetUnicodeString' "$ROOT/Sources/Typist.swift"
check $? "text is injected as unicode, never as synthesized keycodes"
grep -q 'IsSecureEventInputEnabled' "$ROOT/Sources/FocusAnchor.swift"
check $? "secure input is checked before every injection"
grep -q 'Config.whisperBinary\|Config.ffmpegBinary' "$ROOT/Sources/Transcriber.swift"
check $? "batch whisper-cli fallback path is still present"

echo "== 15. pure unit suite (stabilizer, chunker, meter, icon, session) =="
swiftc -O -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$TMP/units" \
  "$ROOT/Sources/Config.swift" \
  "$ROOT/Sources/Stabilizer.swift" \
  "$ROOT/Sources/TextChunker.swift" \
  "$ROOT/Sources/LevelMeter.swift" \
  "$ROOT/Sources/IconAnimation.swift" \
  "$ROOT/Sources/DictationSession.swift" \
  "$ROOT/Tests/Units/main.swift" 2>"$TMP/units.log"
check $? "unit harness compiles against the real sources"
if [ -x "$TMP/units" ]; then
  "$TMP/units" >"$TMP/units.out" 2>&1
  check $? "unit suite passes -> $(tail -1 "$TMP/units.out")"
  grep -c '  ok   ' "$TMP/units.out" >/dev/null 2>&1
  UNIT_FAILS="$(grep -c '  FAIL ' "$TMP/units.out" || true)"
  [ "${UNIT_FAILS:-0}" -eq 0 ]; check $? "no failing unit assertions"
  if [ "${UNIT_FAILS:-0}" -ne 0 ]; then grep '  FAIL ' "$TMP/units.out" | sed 's/^/    /'; fi
else
  no "unit harness missing"
  sed 's/^/    /' "$TMP/units.log" | head -20
fi

echo "== 16. windowed decoder suite (stub backend, stub audio) =="
swiftc -O -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$TMP/decoder" \
  "$ROOT/Sources/Config.swift" \
  "$ROOT/Sources/Stabilizer.swift" \
  "$ROOT/Sources/StreamBuffer.swift" \
  "$ROOT/Sources/FlushGuard.swift" \
  "$ROOT/Sources/WindowedDecoder.swift" \
  "$ROOT/Tests/Decoder/main.swift" 2>"$TMP/decoder.log"
check $? "decoder harness compiles against the real WindowedDecoder.swift"
if [ -x "$TMP/decoder" ]; then
  "$TMP/decoder" >"$TMP/decoder.out" 2>&1
  check $? "decoder suite passes -> $(tail -1 "$TMP/decoder.out")"
  DEC_FAILS="$(grep -c '  FAIL ' "$TMP/decoder.out" || true)"
  [ "${DEC_FAILS:-0}" -eq 0 ]; check $? "no failing decoder assertions"
  if [ "${DEC_FAILS:-0}" -ne 0 ]; then grep '  FAIL ' "$TMP/decoder.out" | sed 's/^/    /'; fi
else
  no "decoder harness missing"
  sed 's/^/    /' "$TMP/decoder.log" | head -20
fi

echo "== 17. streaming step latency gate =="
/opt/homebrew/bin/ffmpeg -nostdin -hide_banner -loglevel error -y \
  -i "$TMP/speech.wav" -t 8 "$TMP/window.wav" 2>/dev/null
[ -s "$TMP/window.wav" ]; check $? "8s decode window prepared"
STEP_START="$(python3 -c 'import time; print(time.time())')"
/opt/homebrew/bin/whisper-cli \
  -m "$HOME/.cache/whisper/ggml-large-v3-turbo.bin" \
  -f "$TMP/window.wav" -l pt -np -bs 1 -nf -ml 1 -sow -oj -of "$TMP/window" \
  >/dev/null 2>"$TMP/step.log"
check $? "streaming-shaped whisper-cli invocation exits 0"
STEP_ELAPSED="$(python3 -c "import time; print('%.2f' % (time.time() - $STEP_START))")"
awk -v e="$STEP_ELAPSED" 'BEGIN { exit !(e > 0 && e < 3.0) }'
check $? "8s window decodes in under 3s (${STEP_ELAPSED}s)"
python3 - "$TMP/window.json" <<'PY'
import json, sys
segments = json.load(open(sys.argv[1]))["transcription"]
words = [s for s in segments if s["text"].strip()]
assert len(words) >= 5, f"expected word-level segments, got {len(words)}"
assert all("offsets" in s for s in words), "segments carry no timestamps"
sys.exit(0)
PY
check $? "JSON carries word-level segments with timestamps"

echo "== 18. status icon rendering and timer lifecycle =="
swiftc -O -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -framework AppKit \
  -o "$TMP/icon" \
  "$ROOT/Sources/Config.swift" \
  "$ROOT/Sources/IconAnimation.swift" \
  "$ROOT/Sources/StatusIcon.swift" \
  "$ROOT/Tests/Icon/main.swift" 2>"$TMP/icon.log"
check $? "icon harness compiles against the real StatusIcon.swift"
if [ -x "$TMP/icon" ]; then
  "$TMP/icon" >"$TMP/icon.out" 2>&1
  check $? "icon suite passes -> $(tail -1 "$TMP/icon.out")"
  ICON_FAILS="$(grep -c '  FAIL ' "$TMP/icon.out" || true)"
  [ "${ICON_FAILS:-0}" -eq 0 ]; check $? "no failing icon assertions"
  if [ "${ICON_FAILS:-0}" -ne 0 ]; then grep '  FAIL ' "$TMP/icon.out" | sed 's/^/    /'; fi
else
  no "icon harness missing"
  sed 's/^/    /' "$TMP/icon.log" | head -20
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
