#!/bin/bash
set -euo pipefail

LABEL="ai.geo.bridge"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$HOME/.hermes/geobridge.token"
TERM_TOKEN_FILE="$HOME/.hermes/geobridge.term.token"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

mkdir -p "$HOME/.hermes" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

if [ ! -s "$TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi

if [ ! -s "$TERM_TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TERM_TOKEN_FILE"
  chmod 600 "$TERM_TOKEN_FILE"
fi

cp "$SRC_DIR/$LABEL.plist" "$PLIST_DST"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "geobridge loaded: $DOMAIN/$LABEL"
echo "token: $TOKEN_FILE"
echo "term token: $TERM_TOKEN_FILE"
