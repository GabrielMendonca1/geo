#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="ai.garime.whisper"
SRC="$ROOT/build/GarimeWhisper.app"
DEST="$HOME/Applications/Garime Whisper.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs/garime"

"$ROOT/build.sh"

if [ ! -d "$SRC" ]; then
  echo "install: build output missing at $SRC" >&2
  exit 1
fi

mkdir -p "$LOGS" "$HOME/Applications"

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  echo "install: unloading running agent"
  launchctl bootout "gui/$UID/$LABEL" || true
fi
pkill -x GarimeWhisper 2>/dev/null || true

echo "install: copying to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "install: writing $AGENT"
sed -e "s#/Users/biel/Library/Logs/garime#$LOGS#g" \
    -e "s#/Users/biel/Applications#$HOME/Applications#g" \
    "$ROOT/$LABEL.plist" > "$AGENT"
plutil -lint "$AGENT" >/dev/null

echo "install: bootstrapping agent"
launchctl bootstrap "gui/$UID" "$AGENT"
launchctl kickstart "gui/$UID/$LABEL"

echo "install: ok"
launchctl print "gui/$UID/$LABEL" | grep -E 'state =|program =' || true
