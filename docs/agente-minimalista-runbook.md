# Runbook — agente minimalista (garime-agent)

> entrega de 2026-08-19 · branches `omni/garime-agente-minimalista/impl-{2,3}` mescladas

## O que mudou

- **Bridge** (`GeoBridge/geobridge.py`): `GET /term/health` (status combinado VM ok + Mac alcançável + agente rodando) e `POST /term/agent-ensure` (garante a sessão tmux `garime-agent`, idempotente). Rotas `/term/*` antigas intactas — o app velho continua funcionando.
- **VM** (`GeoBridge/deploy/`): units systemd da instância única `pi` (`garime-agent.service`), prompt rígido em pt-BR (`agent/system-prompt.md`), allowlist mínima de tools, reset diário do contexto às **23:59 America/Sao_Paulo** (`garime-agent-reset.timer`, `Persistent=true`), deploy idempotente via `deploy.sh`.
- **App iOS** (`Garime/`): aba do terminal virou `AgentHomeView` — 2 dots de status (mac / vm, com latência) + card "conversar" que abre o `AgentChatView` direto na sessão fixa `garime-agent`. Navegação de sessões/panes ficou atrás do toggle **modo avançado** em Ajustes.

## Deploy na VM (manual, nesta ordem)

```bash
cd GeoBridge/deploy
./deploy.sh --dry-run   # inspecionar
./deploy.sh             # rsync geobridge.py + agent/ → /opt/garime, install.sh, restart do bridge
```

Verificação:

```bash
curl -s https://garime.tail091418.ts.net/term/health | jq .        # ok, mac_online, agent.running
ssh garime 'systemctl status garime-agent.service; systemctl list-timers | grep garime-agent-reset'
```

Pré-requisitos e detalhes: `GeoBridge/deploy/README.md`.

## Instalar o app no iPhone

```bash
export DEVELOPER_DIR=/Users/biel/Applications/Xcode-beta.app/Contents/Developer
cd Garime && ruby gen_project.rb
xcodebuild -project Garime.xcodeproj -scheme Garime -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/resign-device \
  -allowProvisioningUpdates -skipPackagePluginValidation build
xcrun devicectl device install app --device 2C856086-CE1B-5E7B-9B09-4F98117576FA \
  build/resign-device/Build/Products/Debug-iphoneos/Garime.app
```

iPhone no cabo, desbloqueado, "Confiar" aceito. Conta gratuita: perfil expira em **7 dias** — reinstalar antes.

## Estado dos gates (2026-08-19)

- `python3 tests/bridge_agent_contract.py` → **0 failing**
- `xcodebuild … generic/platform=iOS` → **BUILD SUCCEEDED**
- Deploy na VM: **ainda não executado** (aguardando operador)
