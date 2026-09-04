#!/bin/sh
BASE="${GARIME_CAPTURE_HOME:-$HOME/Library/Application Support/Garime/GarimeCapture}"
STATUS="$BASE/status"
STRANDED="$STATUS/stranded"
LOG="${GARIME_WATCHDOG_LOG:-$HOME/Library/Logs/garime/garimecapture-watchdog.log}"
LABEL="gui/$(id -u)/ai.garime.capture"
LAUNCHCTL="${GARIME_WATCHDOG_LAUNCHCTL:-launchctl}"
CAPTURE_MAX_AGE=180
RETENTION_MAX_AGE="${GARIME_RETENTION_MAX_AGE:-86400}"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG"; }

if [ "${GARIME_WATCHDOG_SKIP_LAUNCHCTL:-0}" != "1" ] && ! "$LAUNCHCTL" print "$LABEL" >/dev/null 2>&1; then
  log "ERROR: $LABEL is not loaded in launchd — run GarimeCapture/install.sh"
  exit 1
fi

kick() {
  log "$1 -> kickstart"
  "$LAUNCHCTL" kickstart -k "$LABEL" 2>>"$LOG"
  exit 0
}

first_live() {
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$STRANDED" ] && grep -qxF "$(basename "$f")" "$STRANDED"; then continue; fi
    echo "$f"
    return 0
  done
  return 0
}

age_of() {
  hb=$(cat "$1" 2>/dev/null || echo 0)
  case "$hb" in ''|*[!0-9]*) hb=0;; esac
  echo $(($(date +%s) - hb))
}

capture_age=$(age_of "$STATUS/capture.heartbeat")
[ "$capture_age" -gt "$CAPTURE_MAX_AGE" ] && kick "capture heartbeat stale (${capture_age}s)"

if [ -f "$STATUS/retention.heartbeat" ]; then
  retention_age=$(age_of "$STATUS/retention.heartbeat")
  [ "$retention_age" -gt "$RETENTION_MAX_AGE" ] && kick "retention heartbeat stale (${retention_age}s)"
fi

dir="${GARIME_WATCH_DIR:-}"
[ -z "$dir" ] && dir=$(defaults read com.apple.screencapture location 2>/dev/null)
[ -z "$dir" ] && dir="$HOME/Desktop"
case "$dir" in "~"*) dir="$HOME${dir#\~}";; esac

BOOTSTRAP_FILE="$BASE/registry/bootstrap"
bootstrap=$(cat "$BOOTSTRAP_FILE" 2>/dev/null || echo '')
case "$bootstrap" in ''|*[!0-9]*) bootstrap='';; esac

if [ -n "$bootstrap" ]; then
  REF="$(mktemp)"
  touch -t "$(date -r "$bootstrap" +%Y%m%d%H%M.%S)" "$REF" 2>/dev/null
  stale=$(find "$dir" -maxdepth 1 \
    \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.heic' -o -name '*.heif' \) \
    -mmin +3 -newer "$REF" 2>/dev/null | first_live)
  rm -f "$REF"
else
  stale=$(find "$dir" -maxdepth 1 \
    \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.heic' -o -name '*.heif' \) \
    -mmin +3 -mmin -55 2>/dev/null | first_live)
fi
[ -n "$stale" ] && kick "unconsumed screenshot: $stale (heartbeat ok, ${capture_age}s)"

exit 0
