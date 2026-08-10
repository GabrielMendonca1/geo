#!/bin/sh
BASE="${GARIME_CAPTURE_HOME:-$HOME/Library/Application Support/Garime/GarimeCapture}"
STATUS="$BASE/status"
LOG="${GARIME_WATCHDOG_LOG:-$HOME/Library/Logs/garime/garimecapture-watchdog.log}"
LABEL="gui/$(id -u)/ai.garime.capture"
CAPTURE_MAX_AGE=180
UPLOAD_MAX_AGE=1800
RETENTION_MAX_AGE="${GARIME_RETENTION_MAX_AGE:-86400}"
UPLOAD_STALL_MAX="${GARIME_UPLOAD_STALL_MAX:-3600}"
UPLOAD_FAIL_ALERT="${GARIME_UPLOAD_FAIL_ALERT:-10}"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG"; }

if [ "${GARIME_WATCHDOG_SKIP_LAUNCHCTL:-0}" != "1" ] && ! launchctl print "$LABEL" >/dev/null 2>&1; then
  log "ERROR: $LABEL is not loaded in launchd — run GarimeCapture/install.sh"
  exit 1
fi

kick() {
  log "$1 -> kickstart"
  launchctl kickstart -k "$LABEL" 2>>"$LOG"
  exit 0
}

age_of() {
  hb=$(cat "$1" 2>/dev/null || echo 0)
  case "$hb" in ''|*[!0-9]*) hb=0;; esac
  echo $(($(date +%s) - hb))
}

capture_age=$(age_of "$STATUS/capture.heartbeat")
[ "$capture_age" -gt "$CAPTURE_MAX_AGE" ] && kick "capture heartbeat stale (${capture_age}s)"

upload_age=$(age_of "$STATUS/upload.heartbeat")
[ "$upload_age" -gt "$UPLOAD_MAX_AGE" ] && kick "upload heartbeat stale (${upload_age}s)"

if [ -f "$STATUS/retention.heartbeat" ]; then
  retention_age=$(age_of "$STATUS/retention.heartbeat")
  [ "$retention_age" -gt "$RETENTION_MAX_AGE" ] && kick "retention heartbeat stale (${retention_age}s)"
fi

num_of() {
  v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1)
  case "$v" in ''|*[!0-9]*) v=0;; esac
  echo "$v"
}

STATUS_FILE="$STATUS/upload.status"
if [ -f "$STATUS_FILE" ]; then
  failures=$(num_of "$STATUS_FILE" failures)
  last_success=$(num_of "$STATUS_FILE" last_success)
  spool_files=$(num_of "$STATUS_FILE" spool_files)
  spool_oldest=$(num_of "$STATUS_FILE" spool_oldest_age)
  stall=$(($(date +%s) - last_success))
  if [ "$spool_files" -gt 0 ] && [ "$stall" -gt "$UPLOAD_STALL_MAX" ]; then
    log "ERROR: upload not progressing — ${spool_files} markdown file(s) pending (oldest ${spool_oldest}s), no successful upload in ${stall}s, ${failures} consecutive failure(s)"
    exit 2
  fi
  if [ "$failures" -ge "$UPLOAD_FAIL_ALERT" ]; then
    log "ERROR: uploader failing — ${failures} consecutive failure(s), ${spool_files} markdown file(s) pending (oldest ${spool_oldest}s)"
    exit 2
  fi
fi

RETENTION_FILE="$STATUS/retention.status"
if [ -f "$RETENTION_FILE" ]; then
  stuck_files=$(num_of "$RETENTION_FILE" pending_images)
  archive_files=$(num_of "$RETENTION_FILE" archive_files)
  archive_oldest=$(num_of "$RETENTION_FILE" archive_oldest_age_days)
  if [ "$stuck_files" -gt 0 ]; then
    log "ERROR: ${stuck_files} file(s) stuck in the spool that are never uploaded — never archived either (archive holds ${archive_files} image(s), oldest ${archive_oldest}d)"
    exit 2
  fi
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
    \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.heic' \) \
    -mmin +3 -newer "$REF" 2>/dev/null | head -1)
  rm -f "$REF"
else
  stale=$(find "$dir" -maxdepth 1 \
    \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.heic' \) \
    -mmin +3 -mmin -55 2>/dev/null | head -1)
fi
[ -n "$stale" ] && kick "unconsumed screenshot: $stale (heartbeat ok, ${capture_age}s)"

exit 0
