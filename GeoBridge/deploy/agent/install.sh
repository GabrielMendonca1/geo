#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
AGENT_DIR="${AGENT_DIR:-/opt/garime/agent}"

UNITS=(
  "garime-agent.service"
  "garime-agent-reset.service"
  "garime-agent-reset.timer"
)
PAYLOAD=(
  "garime-agent-launch.sh:0755"
  "garime-agent-reset.sh:0755"
  "system-prompt.md:0644"
  "agent.env:0644"
)

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    *) echo "uso: $0 [--check]" >&2; exit 2 ;;
  esac
done

fail() { echo "ERRO: $*" >&2; exit 1; }

verify_static() {
  for f in "${UNITS[@]}"; do
    [ -f "$SRC_DIR/$f" ] || fail "unit ausente no repo: $f"
  done
  for entry in "${PAYLOAD[@]}"; do
    [ -f "$SRC_DIR/${entry%%:*}" ] || fail "payload ausente no repo: ${entry%%:*}"
  done
  bash -n "$SRC_DIR/garime-agent-launch.sh" || fail "sintaxe invalida em garime-agent-launch.sh"
  bash -n "$SRC_DIR/garime-agent-reset.sh" || fail "sintaxe invalida em garime-agent-reset.sh"
  if command -v systemd-analyze >/dev/null 2>&1; then
    local cal
    cal="$(sed -n 's/^OnCalendar=//p' "$SRC_DIR/garime-agent-reset.timer")"
    echo "--- systemd-analyze calendar '$cal'"
    systemd-analyze calendar --iterations=3 "$cal" || fail "expressao OnCalendar invalida"
  else
    echo "SKIP systemd-analyze indisponivel; verificacao limitada a sintaxe"
    grep -q '^\[Timer\]' "$SRC_DIR/garime-agent-reset.timer" || fail "secao [Timer] ausente"
    grep -q '^\[Service\]' "$SRC_DIR/garime-agent.service" || fail "secao [Service] ausente"
  fi
  echo "OK  payload estatico verificado"
}

sync_files() {
  local sudo=""
  [ "$(id -u)" -eq 0 ] || sudo="sudo"
  local changed=0 entry name mode src dst
  for entry in "${PAYLOAD[@]}"; do
    name="${entry%%:*}"; mode="${entry##*:}"
    src="$SRC_DIR/$name"; dst="$AGENT_DIR/$name"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      echo "==  $name ja identico"
      continue
    fi
    $sudo install -D -m "$mode" -o biel -g biel "$src" "$dst"
    echo "->  $name instalado em $dst"
    changed=1
  done
  for name in "${UNITS[@]}"; do
    src="$SRC_DIR/$name"; dst="$UNIT_DIR/$name"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      echo "==  $name ja identico"
      continue
    fi
    $sudo install -D -m 0644 "$src" "$dst"
    echo "->  $name instalado em $dst"
    changed=1
  done
  if [ "$changed" -eq 0 ]; then
    echo "OK  nada mudou; daemon-reload dispensado"
  else
    $sudo systemctl daemon-reload
    echo "OK  daemon-reload"
  fi
  $sudo systemctl enable --now garime-agent.service
  $sudo systemctl enable --now garime-agent-reset.timer
  [ "$changed" -eq 0 ] || $sudo systemctl restart garime-agent.service
}

report_live() {
  command -v systemctl >/dev/null 2>&1 || return 0
  echo "--- estado do agente"
  systemctl is-active garime-agent.service || true
  systemctl list-timers garime-agent-reset.timer --no-pager || true
  echo "--- sessoes tmux"
  sudo -u biel tmux list-sessions 2>/dev/null || true
}

verify_static
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK  --check: nenhuma alteracao feita"
  exit 0
fi
command -v systemctl >/dev/null 2>&1 || fail "systemctl ausente; rode este script na VM garime"
sync_files
report_live
