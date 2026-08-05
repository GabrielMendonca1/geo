#!/bin/sh
HB="$HOME/.hermes/status/geocapture.heartbeat"
LOG="$HOME/.hermes/logs/geocapture-watchdog.log"
LABEL="gui/$(id -u)/ai.garime.capture"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG"; }

kick() {
  log "$1 -> kickstart"
  launchctl kickstart -k "$LABEL" 2>>"$LOG"
  exit 0
}

now=$(date +%s)
hb=$(cat "$HB" 2>/dev/null || echo 0)
age=$((now - hb))
[ "$age" -gt 180 ] && kick "heartbeat stale (${age}s)"

dir=$(defaults read com.apple.screencapture location 2>/dev/null)
[ -z "$dir" ] && dir="$HOME/Screenshots"
case "$dir" in "~"*) dir="$HOME${dir#\~}";; esac

stale=$(find "$dir" -maxdepth 1 \
  \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.heic' \) \
  -mmin +3 -mmin -55 2>/dev/null | head -1)
[ -n "$stale" ] && kick "unconsumed screenshot: $stale (heartbeat ok, ${age}s)"

exit 0
