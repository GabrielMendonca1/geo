#!/usr/bin/env bash
# geo-search-tool — install the Hermes plugin.
#   - Plugin:  ~/.hermes/plugins/geo-search-tool/   (rsync of this dir)
#
# Pure in-process (one tool, no LaunchAgent). Imports the search+summarize
# logic from ~/.hermes/hooks/geo-context/handler.py at runtime, so install the
# hermes hooks dir (hermes/install.sh) too. Re-run after edits; hermes picks up
# changes on next restart.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PLUGIN_DEST="$HERMES_HOME/plugins/geo-search-tool"

HERMES_PYTHON="$HERMES_HOME/hermes-agent/venv/bin/python3"
if [[ ! -x "$HERMES_PYTHON" ]]; then
    echo "ERROR: hermes venv python not found at $HERMES_PYTHON" >&2
    echo "       Install hermes first (see hermes/install.sh in the repo root)." >&2
    exit 1
fi

mkdir -p "$HERMES_HOME/plugins"

echo "==> Installing plugin to $PLUGIN_DEST"
rsync -a --delete \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude 'install.sh' \
    "$SRC_DIR/" "$PLUGIN_DEST/"

echo "==> Ensuring httpx is in the hermes venv"
if ! "$HERMES_PYTHON" -c "import httpx" 2>/dev/null; then
    "$HERMES_PYTHON" -m pip install --quiet httpx
fi

echo "==> Enabling plugin in hermes config"
hermes plugins enable geo-search-tool || true

echo
echo "==> Done. Restart hermes to load the tool (hermes gateway restart)."
echo "  Plugin:  $PLUGIN_DEST"
echo "  Verify:  hermes plugins list | grep geo-search-tool"
echo "  Tool:    geo_search_context(query, with_summary?)"
