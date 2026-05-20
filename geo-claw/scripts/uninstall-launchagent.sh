#!/usr/bin/env bash
set -euo pipefail

LABEL="ai.geo.claw"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$UID/${LABEL}" 2>/dev/null || true

if [[ -f "$PLIST_PATH" ]]; then
  rm -f "$PLIST_PATH"
  echo "removed ${PLIST_PATH}"
else
  echo "no plist at ${PLIST_PATH}"
fi

echo "done"
