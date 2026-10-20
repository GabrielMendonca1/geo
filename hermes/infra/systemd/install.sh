#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${DEST_DIR:-/etc/systemd/system}"
CURATOR_SCRIPT="${CURATOR_SCRIPT:-/opt/garime-curator/context_scraping.py}"

UNITS=(
  "garime-curator.service"
  "garime-curator.timer"
  "garime-curator.service.d/whisper.conf"
)

CHECK_ONLY=0
SKIP_RESTART=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --no-restart) SKIP_RESTART=1 ;;
    *) echo "uso: $0 [--check] [--no-restart]" >&2; exit 2 ;;
  esac
done

fail() { echo "ERRO: $*" >&2; exit 1; }

assert_payload_safe() {
  local stray
  stray="$(find "$SRC_DIR" -type f ! -name '*.service' ! -name '*.timer' ! -name '*.conf' \
    ! -name 'install.sh' ! -name 'README.md' -print)"
  if [ -n "$stray" ]; then
    fail "payload contem arquivos fora da allowlist de units:"$'\n'"$stray"
  fi
  for u in "${UNITS[@]}"; do
    case "$u" in
      *.py) fail "unit list contem codigo python ($u); este script nunca faz deploy de codigo" ;;
    esac
    [ -f "$SRC_DIR/$u" ] || fail "arquivo ausente no repo: $u"
  done
  local dropin name
  while IFS= read -r dropin; do
    [ -n "$dropin" ] || continue
    name="$(basename "$dropin")"
    case " ${UNITS[*]} " in
      *" garime-curator.service.d/$name "*) ;;
      *) fail "drop-in nao declarado em UNITS: garime-curator.service.d/$name -- todo drop-in muda o Environment do service; declare-o ou remova-o" ;;
    esac
  done < <(find "$SRC_DIR/garime-curator.service.d" -type f 2>/dev/null || true)
  echo "OK  payload = apenas unit files declarados; $CURATOR_SCRIPT nao e tocado por este script"
}

verify_static() {
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    echo "SKIP systemd-analyze indisponivel; verificacao estatica limitada a sintaxe ini"
    grep -q '^\[Timer\]' "$SRC_DIR/garime-curator.timer" || fail "secao [Timer] ausente"
    grep -q '^\[Service\]' "$SRC_DIR/garime-curator.service" || fail "secao [Service] ausente"
    return 0
  fi

  local cal
  cal="$(sed -n 's/^OnCalendar=//p' "$SRC_DIR/garime-curator.timer")"
  [ -n "$cal" ] || fail "OnCalendar ausente no timer"
  echo "--- systemd-analyze calendar '$cal'"
  systemd-analyze calendar --iterations=9 "$cal" || fail "expressao OnCalendar invalida"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  cp "$SRC_DIR/garime-curator.service" "$SRC_DIR/garime-curator.timer" "$tmp/"
  echo "--- systemd-analyze verify"
  if systemd-analyze verify "$tmp/garime-curator.service" "$tmp/garime-curator.timer"; then
    echo "OK  systemd-analyze verify sem erros"
  else
    echo "AVISO systemd-analyze verify reportou pendencias (dependencias fora do tmpdir sao esperadas)"
  fi
}

sync_units() {
  local sudo=""
  [ "$(id -u)" -eq 0 ] || sudo="sudo"
  local changed=0
  for u in "${UNITS[@]}"; do
    local src="$SRC_DIR/$u" dst="$DEST_DIR/$u"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      echo "==  $u ja identico"
      continue
    fi
    $sudo install -D -m 0644 "$src" "$dst"
    echo "->  $u instalado"
    changed=1
  done
  if [ "$changed" -eq 0 ]; then
    echo "OK  nada mudou; daemon-reload dispensado"
    return 0
  fi
  $sudo systemctl daemon-reload
  echo "OK  daemon-reload"
  if [ "$SKIP_RESTART" -eq 1 ]; then
    echo "SKIP restart do timer por --no-restart"
    return 0
  fi
  $sudo systemctl enable --now garime-curator.timer
  $sudo systemctl restart garime-curator.timer
  echo "OK  timer reiniciado (um catch-up imediato e possivel com Persistent=true)"
}

report_live() {
  command -v systemctl >/dev/null 2>&1 || return 0
  echo "--- Environment efetivo do service"
  systemctl show garime-curator.service -p Environment
  echo "--- proximo disparo"
  systemctl list-timers garime-curator.timer --no-pager || true
}

assert_payload_safe
verify_static

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK  --check: nenhuma alteracao feita"
  exit 0
fi

command -v systemctl >/dev/null 2>&1 || fail "systemctl ausente; rode este script na VM garime"
sync_units
report_live
