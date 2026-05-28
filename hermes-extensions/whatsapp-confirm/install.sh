#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PLUGIN_DEST="$HERMES_HOME/plugins/whatsapp-confirm"

mkdir -p "$HERMES_HOME/plugins"

echo "==> Installing plugin to $PLUGIN_DEST"
rsync -a --delete \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude 'install.sh' \
    "$SRC_DIR/" "$PLUGIN_DEST/"

echo "==> Enabling plugin in hermes config"
hermes plugins enable whatsapp-confirm || true

echo
echo "==> Done."
echo "  Plugin:  $PLUGIN_DEST"
echo "  Verify:  hermes plugins list | grep whatsapp-confirm"
echo "  Effect:  send_message with target='whatsapp:*' blocks until you reply Y/N on Telegram."
