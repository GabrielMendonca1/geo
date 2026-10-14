#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$ROOT/build/GarimeWhisper.app}"
NAME="$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
SETTLE="${PERF_SETTLE:-20}"
SAMPLES="${PERF_SAMPLES:-12}"
MAX_WAKEUPS="${PERF_MAX_WAKEUPS:-0.5}"
MAX_FOOTPRINT_MB="${PERF_MAX_FOOTPRINT_MB:-25}"

if pgrep -x "$NAME" >/dev/null; then
  echo "perf: $NAME is already running; quit it first so the numbers are ours" >&2
  exit 2
fi

open -g "$APP"
trap 'osascript -e "tell application id \"$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")\" to quit" >/dev/null 2>&1' EXIT
sleep "$SETTLE"
PID="$(pgrep -x "$NAME" | head -1)"
[ -n "$PID" ] || { echo "perf: $NAME did not start" >&2; exit 1; }

WAKEUPS="$(top -l $((SAMPLES + 1)) -s 5 -pid "$PID" -stats pid,idlew \
  | awk -v pid="$PID" -v n="$SAMPLES" '$1==pid { if (seen++) { gsub(/[^0-9]/, "", $2); s += $2 } } END { printf "%.2f", s / (n * 5) }')"
CPU="$(ps -o %cpu= -p "$PID" | tr -d ' ')"
FOOTPRINT="$(footprint "$PID" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") { v = $(i+1); u = $(i+2) } } END { if (u == "KB") v /= 1024; if (u == "GB") v *= 1024; printf "%.1f", v }')"
LEAKS="$(leaks "$PID" 2>/dev/null | awk '/leaks for/ { print $3; exit }')"

echo "perf: $NAME pid $PID"
echo "  footprint      ${FOOTPRINT} MB   (max ${MAX_FOOTPRINT_MB})"
echo "  idle wakeups   ${WAKEUPS} /s    (max ${MAX_WAKEUPS})"
echo "  cpu            ${CPU} %"
echo "  leaks          ${LEAKS:-?}"

FAIL=0
awk "BEGIN { exit !($WAKEUPS <= $MAX_WAKEUPS) }" || { echo "  FAIL idle wakeups"; FAIL=1; }
awk "BEGIN { exit !($FOOTPRINT <= $MAX_FOOTPRINT_MB) }" || { echo "  FAIL footprint"; FAIL=1; }
[ "${LEAKS:-x}" = "0" ] || [ -z "$LEAKS" ] || { echo "  FAIL leaks"; FAIL=1; }
exit "$FAIL"
