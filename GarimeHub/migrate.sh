#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLD="ai.garime.whisper"
NEW="ai.garime.hub"
OLD_APP="$HOME/Applications/Garime Whisper.app"
OLD_AGENT="$HOME/Library/LaunchAgents/$OLD.plist"

if pgrep -x GarimeWhisper >/dev/null; then
  echo "migrate: Garime Whisper está aberto. Use Sair no menu dele." >&2
  exit 1
fi
BK="$HOME/Library/Application Support/Garime/Backups/Whisper/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
[ -d "$OLD_APP" ] && cp -R "$OLD_APP" "$BK/"
[ -f "$OLD_AGENT" ] && cp "$OLD_AGENT" "$BK/"
defaults export "$OLD" "$BK/defaults.plist" 2>/dev/null || true
echo "migrate: backup em $BK"

copied=0
for key in enabled volume; do
  if value="$(defaults read "$OLD" "$OLD.feedback.$key" 2>/dev/null)"; then
    case "$key" in
      enabled) defaults write "$NEW" "$NEW.feedback.$key" -bool "$value" ;;
      volume) defaults write "$NEW" "$NEW.feedback.$key" -float "$value" ;;
    esac
    copied=$((copied + 1))
  fi
done
echo "migrate: $copied ajuste(s) de Sons copiados para $NEW"

launchctl bootout "gui/$UID/$OLD" 2>/dev/null || true
rm -f "$OLD_AGENT"
rm -rf "$OLD_APP"
echo "migrate: $OLD removido (LaunchAgent e app)"

"$ROOT/install.sh"

cat <<'EOF'

migrate: conceda de novo ao Garime Hub (o macOS liga permissões ao bundle id):
  - Microfone (pedido no primeiro ⌥Space)
  - Acessibilidade (menu: Ativar colagem automática…)
Remova "Garime Whisper" das listas em Ajustes › Privacidade e Segurança.
EOF
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
