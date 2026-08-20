#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${GARIME_AGENT_ENV:-/opt/garime/agent/agent.env}"
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

SESSION="${GARIME_AGENT_SESSION:-garime-agent}"
TMUX_BIN="${GARIME_AGENT_TMUX:-/usr/bin/tmux}"
PI_BIN="${GARIME_AGENT_BIN:-/usr/bin/pi}"
WORKDIR="${GARIME_AGENT_WORKDIR:-/mnt/garime/Vault}"
SESSION_DIR="${GARIME_AGENT_SESSION_DIR:-/mnt/garime/pi/agent/sessions}"
PROMPT="${GARIME_AGENT_PROMPT:-/opt/garime/agent/system-prompt.md}"
TOOLS="${GARIME_AGENT_TOOLS:-read,write,edit,bash}"
PROVIDER="${GARIME_AGENT_PROVIDER:-openai-codex}"
MODEL="${GARIME_AGENT_MODEL:-gpt-5.6-luna}"
THINKING="${GARIME_AGENT_THINKING:-medium}"

fail() { echo "ERRO: $*" >&2; exit 1; }

[ -x "$TMUX_BIN" ] || fail "tmux ausente em $TMUX_BIN"
[ -x "$PI_BIN" ] || fail "pi ausente em $PI_BIN"
[ -f "$PROMPT" ] || fail "system prompt ausente em $PROMPT"
[ -d "$WORKDIR" ] || fail "workdir ausente: $WORKDIR (mount /mnt/garime?)"
mkdir -p "$SESSION_DIR"

if "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
  echo "==  sessao $SESSION ja existe; nada a fazer"
  exit 0
fi

"$TMUX_BIN" -u new-session -d -s "$SESSION" -c "$WORKDIR" -- \
  "$PI_BIN" \
  --provider "$PROVIDER" \
  --model "$MODEL" \
  --thinking "$THINKING" \
  --system-prompt "$(cat "$PROMPT")" \
  --tools "$TOOLS" \
  --no-extensions \
  --no-prompt-templates \
  --no-context-files \
  --session-dir "$SESSION_DIR" \
  --name "$SESSION"

"$TMUX_BIN" set-option -t "=$SESSION" -g history-limit 100000
echo "OK  sessao $SESSION criada com pi ($PROVIDER/$MODEL, tools=$TOOLS)"
