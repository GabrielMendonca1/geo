#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${GARIME_VM_HOST:-garime}"
USER_="${GARIME_VM_USER:-biel}"
REMOTE_DIR="${GARIME_REMOTE_DIR:-/opt/garime}"
BRIDGE_UNIT="${GARIME_BRIDGE_UNIT:-garime-bridge.service}"
STAGE="${GARIME_REMOTE_STAGE:-/tmp/garime-deploy}"

DRY=0
SKIP_AGENT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --bridge-only) SKIP_AGENT=1 ;;
    *) echo "uso: $0 [--dry-run] [--bridge-only]" >&2; exit 2 ;;
  esac
done

fail() { echo "ERRO: $*" >&2; exit 1; }
run() { echo "+ $*"; [ "$DRY" -eq 1 ] || "$@"; }

[ -f "$SRC_DIR/geobridge.py" ] || fail "geobridge.py ausente em $SRC_DIR"
python3 -m py_compile "$SRC_DIR/geobridge.py" || fail "geobridge.py nao compila; deploy abortado"
bash -n "$SRC_DIR/deploy/agent/install.sh"
echo "OK  fontes verificadas"

RSYNC_OPTS=(-a --checksum --itemize-changes)
[ "$DRY" -eq 1 ] && RSYNC_OPTS+=(--dry-run)

run ssh "$USER_@$HOST" mkdir -p "$STAGE/agent"
run rsync "${RSYNC_OPTS[@]}" "$SRC_DIR/geobridge.py" "$USER_@$HOST:$STAGE/geobridge.py"
run rsync "${RSYNC_OPTS[@]}" --delete "$SRC_DIR/deploy/agent/" "$USER_@$HOST:$STAGE/agent/"

REMOTE_SCRIPT=$(cat <<EOF
set -euo pipefail
sudo install -D -m 0755 -o $USER_ -g $USER_ "$STAGE/geobridge.py" "$REMOTE_DIR/geobridge.py"
sudo systemctl restart $BRIDGE_UNIT
systemctl is-active $BRIDGE_UNIT
EOF
)
if [ "$SKIP_AGENT" -eq 0 ]; then
  REMOTE_SCRIPT="chmod +x $STAGE/agent/*.sh
$STAGE/agent/install.sh
$REMOTE_SCRIPT"
fi

if [ "$DRY" -eq 1 ]; then
  echo "--- comandos remotos (dry-run)"
  echo "$REMOTE_SCRIPT"
  exit 0
fi

ssh "$USER_@$HOST" bash -s <<EOF
$REMOTE_SCRIPT
EOF
echo "OK  deploy concluido em $USER_@$HOST:$REMOTE_DIR"
