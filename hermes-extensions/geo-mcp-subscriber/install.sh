#!/usr/bin/env bash
# geo-mcp-subscriber — install the push-subscriber LaunchAgent daemon.
#   - Code:   ~/.hermes/daemons/geo-mcp-subscriber/   (rsync of this dir)
#   - Daemon: ~/Library/LaunchAgents/ai.hermes.geo-mcp-subscriber.plist
#
# Deployed under daemons/ (NOT plugins/) on purpose: it provides no MCP tools,
# so it must stay out of the hermes plugin scanner. Run by absolute path from
# the LaunchAgent. Re-run after edits; the launchctl bootout/bootstrap reloads it.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DAEMON_DEST="$HERMES_HOME/daemons/geo-mcp-subscriber"

HERMES_PYTHON="$HERMES_HOME/hermes-agent/venv/bin/python3"
if [[ ! -x "$HERMES_PYTHON" ]]; then
    echo "ERROR: hermes venv python not found at $HERMES_PYTHON" >&2
    echo "       Install hermes first (see hermes/install.sh in the repo root)." >&2
    exit 1
fi

mkdir -p "$HERMES_HOME/daemons" "$HERMES_HOME/logs" "$LAUNCH_AGENTS_DIR"

echo "==> Installing daemon code to $DAEMON_DEST"
rsync -a --delete \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude 'install.sh' \
    --exclude 'ai.hermes.geo-mcp-subscriber.plist' \
    "$SRC_DIR/" "$DAEMON_DEST/"

echo "==> Templating LaunchAgent plist"
PLIST_DEST="$LAUNCH_AGENTS_DIR/ai.hermes.geo-mcp-subscriber.plist"
PATH_VAL="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$HOME/.local/bin"

sed \
    -e "s|__HERMES_PYTHON__|${HERMES_PYTHON}|g" \
    -e "s|__DAEMON_PATH__|${DAEMON_DEST}/daemon.py|g" \
    -e "s|__HERMES_HOME__|${HERMES_HOME}|g" \
    -e "s|__PATH__|${PATH_VAL}|g" \
    "$SRC_DIR/ai.hermes.geo-mcp-subscriber.plist" > "$PLIST_DEST"
chmod 644 "$PLIST_DEST"
echo "  wrote $PLIST_DEST"

echo "==> Enabling the daemon"
UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DEST"

echo
echo "==> Done."
echo "  Code:   $DAEMON_DEST"
echo "  Daemon: $PLIST_DEST"
echo "  Cache:  $HERMES_HOME/geo-cache/snapshot.json"
echo "  Logs:   $HERMES_HOME/logs/geo-mcp-subscriber.{out,err}.log"
echo "  Verify: launchctl list ai.hermes.geo-mcp-subscriber"
