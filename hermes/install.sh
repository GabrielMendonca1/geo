#!/usr/bin/env bash
# hermes — apply Geo configuration to ~/.hermes/
# Idempotent: existing config.yaml is backed up; existing .env is preserved.
# Daemon code (status-poller, whatsapp-ingest, hooks, scripts) is rsync'd
# WITHOUT --delete because the daemons write runtime state into those dirs
# (Baileys auth at whatsapp-ingest/auth/, hook .state.json, node_modules).

set -euo pipefail

if ! command -v hermes >/dev/null; then
    echo "Install hermes first: curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SRC_DIR/.." && pwd)"
DEST_DIR="${HERMES_HOME:-$HOME/.hermes}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
TS="$(date +%Y%m%d-%H%M%S)"

GEO_MCP_BRIDGE_BIN="${GEO_MCP_BRIDGE_BIN:-$REPO_ROOT/geo-mcp-bridge/geo-mcp-bridge}"

mkdir -p "$DEST_DIR" "$DEST_DIR/memories" "$DEST_DIR/logs" "$LAUNCH_AGENTS_DIR"

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

template_config() {
    local src="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        cp "$dest" "${dest}.bak.${TS}"
        echo "  backed up existing $(basename "$dest") -> $(basename "$dest").bak.${TS}"
    fi
    local bin_escaped="${GEO_MCP_BRIDGE_BIN//\//\\/}"
    sed "s/__GEO_MCP_BRIDGE_BIN__/${bin_escaped}/g" "$src" > "$dest"
    echo "  wrote $dest (GEO_MCP_BRIDGE_BIN=$GEO_MCP_BRIDGE_BIN)"
}

sync_daemon_dir() {
    local src="$1" dest="$2"
    if [[ ! -d "$src" ]]; then
        echo "  ERROR: missing source dir $src" >&2
        exit 1
    fi
    mkdir -p "$dest"
    # No --delete: daemons write runtime state (auth/, .state.json, logs/, node_modules/) here.
    rsync -a "$src/" "$dest/"
    echo "  synced $src/ -> $dest/"
}

install_plist() {
    local src="$1"
    if [[ ! -f "$src" ]]; then
        echo "  ERROR: missing plist $src" >&2
        exit 1
    fi
    local name; name="$(basename "$src")"
    local dest="$LAUNCH_AGENTS_DIR/$name"
    cp "$src" "$dest"
    chmod 644 "$dest"
    echo "  wrote $dest"
}

echo "==> Installing hermes config into $DEST_DIR"
template_config "$SRC_DIR/config.yaml"           "$DEST_DIR/config.yaml"
ln -sfn "$SRC_DIR/SOUL.md"                       "$DEST_DIR/SOUL.md"
echo "  symlinked SOUL.md -> $SRC_DIR/SOUL.md"
copy_with_backup "$SRC_DIR/memories/MEMORY.md"   "$DEST_DIR/memories/MEMORY.md"
copy_with_backup "$SRC_DIR/memories/USER.md"     "$DEST_DIR/memories/USER.md"
copy_if_absent   "$SRC_DIR/.env.template"        "$DEST_DIR/.env"

if grep -q "^GEO_MCP_BRIDGE_BIN=$" "$DEST_DIR/.env" 2>/dev/null; then
    sed -i.bak "s|^GEO_MCP_BRIDGE_BIN=$|GEO_MCP_BRIDGE_BIN=$GEO_MCP_BRIDGE_BIN|" "$DEST_DIR/.env"
    rm -f "$DEST_DIR/.env.bak"
    echo "  populated GEO_MCP_BRIDGE_BIN in $DEST_DIR/.env"
fi

chmod 644 "$DEST_DIR/config.yaml" "$DEST_DIR/memories/MEMORY.md" "$DEST_DIR/memories/USER.md"
chmod 600 "$DEST_DIR/.env"

echo "==> Syncing vendored daemon code"
sync_daemon_dir "$SRC_DIR/status-poller"    "$DEST_DIR/status-poller"
sync_daemon_dir "$SRC_DIR/whatsapp-ingest"  "$DEST_DIR/whatsapp-ingest"
sync_daemon_dir "$SRC_DIR/hooks"            "$DEST_DIR/hooks"
sync_daemon_dir "$SRC_DIR/scripts"          "$DEST_DIR/scripts"

echo "==> Installing LaunchAgent plists into $LAUNCH_AGENTS_DIR"
for plist in "$SRC_DIR"/launch-agents/*.plist; do
    [[ -e "$plist" ]] || continue
    install_plist "$plist"
done

echo
echo "==> Done. Next steps:"
echo "  1. Open $DEST_DIR/.env and fill in ANTHROPIC_API_KEY (and any platform tokens you plan to use)."
echo "  2. Generate API_SERVER_KEY:  openssl rand -hex 32"
echo "  3. Build geo-mcp-bridge if missing:  (cd $REPO_ROOT/geo-mcp-bridge && ./build.sh)"
echo "  4. Boot hermes:              hermes gateway start"
echo "  5. Load the sidecar LaunchAgents (re-run after every install.sh to pick up plist/code changes):"
for plist in "$SRC_DIR"/launch-agents/*.plist; do
    [[ -e "$plist" ]] || continue
    name="$(basename "$plist" .plist)"
    echo "       launchctl bootout gui/\$(id -u) $LAUNCH_AGENTS_DIR/$(basename "$plist") 2>/dev/null || true"
    echo "       launchctl bootstrap gui/\$(id -u) $LAUNCH_AGENTS_DIR/$(basename "$plist")"
done
echo "  6. (If switching from geo-claw) stop the old daemon first:"
echo "     launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/ai.geo.claw.plist"
