#!/usr/bin/env bash
# hermes — apply Geo configuration to ~/.hermes/
# Idempotent: existing config.yaml is backed up; existing .env is preserved.

set -euo pipefail

if ! command -v hermes >/dev/null; then
    echo "Install hermes first: curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${HERMES_HOME:-$HOME/.hermes}"
TS="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DEST_DIR" "$DEST_DIR/memories"

copy_with_backup() {
    local src="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        cp "$dest" "${dest}.bak.${TS}"
        echo "  backed up existing $(basename "$dest") -> $(basename "$dest").bak.${TS}"
    fi
    cp "$src" "$dest"
    echo "  wrote $dest"
}

copy_if_absent() {
    local src="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        echo "  kept existing $dest (not overwritten)"
    else
        cp "$src" "$dest"
        echo "  wrote $dest"
    fi
}

echo "==> Installing hermes config into $DEST_DIR"

copy_with_backup "$SRC_DIR/config.yaml" "$DEST_DIR/config.yaml"
copy_with_backup "$SRC_DIR/SOUL.md"     "$DEST_DIR/SOUL.md"
copy_with_backup "$SRC_DIR/memories/MEMORY.md" "$DEST_DIR/memories/MEMORY.md"
copy_with_backup "$SRC_DIR/memories/USER.md"   "$DEST_DIR/memories/USER.md"
copy_if_absent   "$SRC_DIR/.env.template"      "$DEST_DIR/.env"

chmod 644 "$DEST_DIR/config.yaml" "$DEST_DIR/SOUL.md" "$DEST_DIR/memories/MEMORY.md" "$DEST_DIR/memories/USER.md"
chmod 600 "$DEST_DIR/.env"

echo
echo "==> Done. Next steps:"
echo "  1. Open $DEST_DIR/.env and fill in ANTHROPIC_API_KEY (and any platform tokens you plan to use)."
echo "  2. Generate API_SERVER_KEY:  openssl rand -hex 32"
echo "  3. Boot hermes:              hermes gateway start"
echo "  4. (If switching from geo-claw) stop the old daemon first:"
echo "     launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/ai.geo.claw.plist"
