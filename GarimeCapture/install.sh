#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="ai.garime.capture"
WATCHDOG_LABEL="ai.garime.capture-watchdog"
BIN_DIR="${GARIME_BIN_DIR:-$HOME/.local/bin}"
BIN="$BIN_DIR/garimecapture"
WATCHDOG="$BIN_DIR/garimecapture-watchdog.sh"
AGENTS="${GARIME_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LOGS="$HOME/Library/Logs/garime"
SKIP_LAUNCHCTL="${GARIME_INSTALL_SKIP_LAUNCHCTL:-0}"

"$ROOT/build.sh"

if [ ! -x "$ROOT/build/garimecapture" ]; then
  echo "install: build output missing at $ROOT/build/garimecapture" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$AGENTS" "$LOGS"

unload() {
  [ "$SKIP_LAUNCHCTL" = "1" ] && return 0
  if launchctl print "gui/$UID/$1" >/dev/null 2>&1; then
    echo "install: unloading $1"
    launchctl bootout "gui/$UID/$1" 2>/dev/null || true
  fi
}

unload "$LABEL"
unload "$WATCHDOG_LABEL"

echo "install: copying binary to $BIN"
rm -f "$BIN"
cp "$ROOT/build/garimecapture" "$BIN"
chmod 755 "$BIN"

echo "install: copying watchdog to $WATCHDOG"
cp "$ROOT/garimecapture-watchdog.sh" "$WATCHDOG"
chmod 755 "$WATCHDOG"

write_agent() {
  label="$1"
  target="$AGENTS/$label.plist"
  echo "install: writing $target"
  sed -e "s#/Users/biel/.local/bin#$BIN_DIR#g" \
      -e "s#/Users/biel/Library/Logs/garime#$LOGS#g" \
      "$ROOT/$label.plist" > "$target"
  plutil -lint "$target" >/dev/null
}

write_agent "$LABEL"
write_agent "$WATCHDOG_LABEL"

if [ "$SKIP_LAUNCHCTL" = "1" ]; then
  echo "install: GARIME_INSTALL_SKIP_LAUNCHCTL=1, not touching launchd"
  exit 0
fi

for label in "$LABEL" "$WATCHDOG_LABEL"; do
  echo "install: bootstrapping $label"
  launchctl bootstrap "gui/$UID" "$AGENTS/$label.plist"
  launchctl kickstart "gui/$UID/$label"
done

echo "install: ok"
launchctl print "gui/$UID/$LABEL" | grep -E 'state =|program =' || true
