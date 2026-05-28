#!/usr/bin/env bash
# claude-code-lane — install the Hermes plugin + LaunchAgent daemon.
#   - Plugin:  ~/.hermes/plugins/claude-code-lane/   (rsync of this dir)
#   - Daemon:  ~/Library/LaunchAgents/ai.hermes.claude-code-lane.plist
#
# Re-run after edits to pick up changes. The launchctl bootout/bootstrap
# pair at the end reloads the daemon.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLUGIN_DEST="$HERMES_HOME/plugins/claude-code-lane"

HERMES_PYTHON="$HERMES_HOME/hermes-agent/venv/bin/python3"
if [[ ! -x "$HERMES_PYTHON" ]]; then
    echo "ERROR: hermes venv python not found at $HERMES_PYTHON" >&2
    echo "       Install hermes first (see hermes/install.sh in the repo root)." >&2
    exit 1
fi

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -z "$CLAUDE_BIN" ]]; then
    echo "ERROR: \`claude\` CLI not on PATH. Install Claude Code first." >&2
    exit 1
fi

mkdir -p "$HERMES_HOME/plugins" "$HERMES_HOME/logs" "$LAUNCH_AGENTS_DIR"

echo "==> Installing plugin to $PLUGIN_DEST"
rsync -a --delete \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude 'install.sh' \
    --exclude 'ai.hermes.claude-code-lane.plist' \
    "$SRC_DIR/" "$PLUGIN_DEST/"

echo "==> Enabling plugin in hermes config"
hermes plugins enable claude-code-lane || true

echo "==> Templating LaunchAgent plist"
PLIST_DEST="$LAUNCH_AGENTS_DIR/ai.hermes.claude-code-lane.plist"
PATH_VAL="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$HOME/.local/bin"

sed \
    -e "s|__HERMES_PYTHON__|${HERMES_PYTHON}|g" \
    -e "s|__DAEMON_PATH__|${PLUGIN_DEST}/daemon.py|g" \
    -e "s|__HERMES_HOME__|${HERMES_HOME}|g" \
    -e "s|__PATH__|${PATH_VAL}|g" \
    -e "s|__CLAUDE_BIN__|${CLAUDE_BIN}|g" \
    "$SRC_DIR/ai.hermes.claude-code-lane.plist" > "$PLIST_DEST"
chmod 644 "$PLIST_DEST"
echo "  wrote $PLIST_DEST"

echo "==> Enabling the daemon"
UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DEST"

echo
echo "==> Done."
echo "  Plugin:  $PLUGIN_DEST"
echo "  Daemon:  $PLIST_DEST"
echo "  Logs:    $HERMES_HOME/logs/claude-code-lane.{out,err}.log"
echo "  Verify:  launchctl list ai.hermes.claude-code-lane"
echo
echo "  To enqueue a run from the CLI:"
echo "    hermes kanban create --assignee claude-code \\"
echo "        --workspace dir:/abs/dir \\"
echo "        --body 'list files in the current directory' \\"
echo "        'test run'"
echo
echo "  From hermes chat, the agent can call the MCP tool:"
echo "    claude_code_run(directory='/abs/dir', prompt='list files...')"
