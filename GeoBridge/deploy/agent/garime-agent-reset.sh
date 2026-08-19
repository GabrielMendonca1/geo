#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${GARIME_AGENT_ENV:-/opt/garime/agent/agent.env}"
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

SESSION="${GARIME_AGENT_SESSION:-garime-agent}"
TMUX_BIN="${GARIME_AGENT_TMUX:-/usr/bin/tmux}"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "uso: $0 [--force]" >&2; exit 2 ;;
  esac
done

restart_unit() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart garime-agent.service
    echo "OK  garime-agent.service reiniciado"
  else
    echo "AVISO systemctl ausente; sessao continua morta" >&2
    exit 1
  fi
}

if ! "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
  echo "==  sessao $SESSION ausente; reiniciando o service"
  restart_unit
  exit 0
fi

TAIL="$("$TMUX_BIN" capture-pane -p -t "=$SESSION:" -S -12 2>/dev/null || true)"

if [ -z "$TAIL" ]; then
  echo "==  pane sem conteudo; reiniciando o service"
  restart_unit
  exit 0
fi

if [ "$FORCE" -eq 0 ] && printf '%s' "$TAIL" | grep -qiE '\(y/n\)|\[y/n\]|❯ 1\.|allow\?|permitir\?'; then
  echo "SKIP pergunta pendente no pane; contexto preservado (rode com --force para zerar mesmo assim)"
  exit 0
fi

"$TMUX_BIN" send-keys -t "=$SESSION:" Escape
"$TMUX_BIN" send-keys -t "=$SESSION:" "/new" Enter
echo "OK  /new enviado para $SESSION"
