#!/bin/bash
set -euo pipefail

USER_NAME="$(id -un)"
RULE="/etc/sudoers.d/garime-whisper"
STAGE="$(mktemp -t garime-whisper-sudoers)"

cat > "$STAGE" <<EOF
# Garime Whisper: manter o Mac acordado de tampa fechada.
# Dois comandos fixos, argumentos travados, nada de curinga.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
EOF

if ! /usr/sbin/visudo -c -f "$STAGE" >/dev/null; then
  echo "regra sudoers invalida, nada foi instalado" >&2
  rm -f "$STAGE"
  exit 1
fi

echo "regra validada; o macOS vai pedir sua senha para instalar em $RULE"

/usr/bin/osascript -e "do shell script \"install -m 0440 -o root -g wheel '$STAGE' '$RULE'\" with administrator privileges" >/dev/null

rm -f "$STAGE"

if /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  echo "ok: tampa fechada agora e coberta pelo Manter acordado"
else
  echo "instalou a regra mas o teste falhou; confira $RULE" >&2
  exit 1
fi
