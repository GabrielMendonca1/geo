#!/usr/bin/env bash
# geo-tools — install the Hermes plugin.
#   - Plugin:  ~/.hermes/plugins/geo-tools/   (rsync of this dir)
#
# No LaunchAgent: this plugin is pure in-process (tools + a gateway hook).
# Re-run after edits to push code; hermes picks up changes on next restart
# (or `hermes plugins reload geo-tools` if your install supports it).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PLUGIN_DEST="$HERMES_HOME/plugins/geo-tools"

if [[ ! -d "$HERMES_HOME" ]]; then
    echo "ERROR: hermes home not found at $HERMES_HOME" >&2
    echo "       Install hermes first (see hermes/install.sh in the repo root)." >&2
    exit 1
fi

mkdir -p "$HERMES_HOME/plugins"

echo "==> Installing plugin to $PLUGIN_DEST"
rsync -a --delete \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude 'install.sh' \
    --exclude '.state.json' \
    "$SRC_DIR/" "$PLUGIN_DEST/"

echo "==> Enabling plugin in hermes config"
hermes plugins enable geo-tools || true

echo
echo "==> Done."
echo "  Plugin:  $PLUGIN_DEST"
echo "  Verify:  hermes plugins list | grep geo-tools"
