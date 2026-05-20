#!/usr/bin/env bash
set -euo pipefail

LABEL="ai.geo.claw"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/GeoClaw"
DIST_ENTRY="$REPO_DIR/dist/index.js"

find_node() {
  local candidates=(
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "/usr/bin/node"
    "$HOME/.volta/bin/node"
    "$HOME/.fnm/aliases/default/bin/node"
    "$HOME/.nvm/versions/node/$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)/bin/node"
    "$HOME/.asdf/shims/node"
    "$HOME/.local/share/mise/installs/node/latest/bin/node"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi
  if [[ -x "$SHELL" ]]; then
    local from_login
    from_login="$("$SHELL" -lc 'command -v node' 2>/dev/null || true)"
    if [[ -n "$from_login" && -x "$from_login" ]]; then
      printf '%s' "$from_login"
      return 0
    fi
  fi
  return 1
}

NODE_BIN="$(find_node || true)"

if [[ -z "$NODE_BIN" ]]; then
  echo "error: node not found. install Node.js 20+ (e.g. brew install node) and retry." >&2
  echo "searched: /opt/homebrew/bin, /usr/local/bin, /usr/bin, ~/.volta, ~/.fnm, ~/.nvm, ~/.asdf, mise, plus the user's login shell." >&2
  exit 1
fi

if [[ ! -x "$NODE_BIN" ]]; then
  echo "error: resolved node binary is not executable: $NODE_BIN" >&2
  exit 1
fi

if [[ ! -f "$DIST_ENTRY" ]]; then
  echo "error: $DIST_ENTRY not found. run 'npm run build' first." >&2
  exit 1
fi

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

NODE_BIN_XML="$(xml_escape "$NODE_BIN")"
DIST_ENTRY_XML="$(xml_escape "$DIST_ENTRY")"
REPO_DIR_XML="$(xml_escape "$REPO_DIR")"
LABEL_XML="$(xml_escape "$LABEL")"
LOG_OUT_XML="$(xml_escape "$LOG_DIR/launchd.out.log")"
LOG_ERR_XML="$(xml_escape "$LOG_DIR/launchd.err.log")"

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL_XML}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN_XML}</string>
    <string>${DIST_ENTRY_XML}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO_DIR_XML}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${LOG_OUT_XML}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_ERR_XML}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST_PATH"

echo "installed ${LABEL} at ${PLIST_PATH}"
echo "node:  ${NODE_BIN}"
echo "entry: ${DIST_ENTRY}"
echo "daemon starting; tail logs with:"
echo "  tail -f \"$LOG_DIR/launchd.out.log\" \"$LOG_DIR/launchd.err.log\""
