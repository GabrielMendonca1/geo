# Deploy — bridge + agente único

Tudo aqui é **fonte**; o runtime vive na VM garime em `/opt/garime`. Nenhum script deste diretório roda sozinho: o operador dispara manualmente.

## O que é o agente único

Uma instância `pi` fixa, dona da sessão tmux `garime-agent`, criada pelo `garime-agent.service` — nunca pelo app. O bridge só observa (`GET /term/health`) e conversa com ela pelas rotas `/term/agent-*` já existentes, usando `?session=garime-agent`.

| Arquivo | Papel |
|---|---|
| `agent/garime-agent.service` | cria a sessão tmux (oneshot + `RemainAfterExit`); `ExecStop` mata a sessão |
| `agent/garime-agent-launch.sh` | monta a linha do `pi` (prompt rígido, allowlist de tools, cwd no Vault); idempotente via `tmux has-session` |
| `agent/agent.env` | binários, paths e modelo — único lugar para ajustar |
| `agent/system-prompt.md` | prompt em pt-BR: escopo Vault/Health/zap/e-mail e o que é proibido |
| `agent/garime-agent-reset.sh` | reset diário: `/new` no pane; se a sessão morreu, reinicia o service; pula se há pergunta pendente (`--force` ignora) |
| `agent/garime-agent-reset.{service,timer}` | timer `23:59 America/Sao_Paulo`, `Persistent=true` |
| `agent/install.sh` | instala payload em `/opt/garime/agent` + units em `/etc/systemd/system` |
| `deploy.sh` | rsync do `geobridge.py` + `agent/`, roda `install.sh` e reinicia o bridge |

## Pré-requisitos na VM

- `pi` em `/usr/bin/pi` com suporte a `--system-prompt`, `--tools`, `--session-dir` (`pi --help` confirma).
- `tmux` em `/usr/bin/tmux` e `GEO_TERM_TMUX=/usr/bin/tmux` no ambiente do bridge (o default do código é o caminho do Mac).
- `/mnt/garime` montado (Vault + `pi/agent/sessions`).
- `GEO_TERM_ENABLED=1` e o term token preenchido — sem isso `/term/health` responde 404.

## Rodar

```bash
cd GeoBridge/deploy
./deploy.sh --dry-run          # mostra rsync e comandos remotos, não muda nada
./deploy.sh                    # bridge + agente
./deploy.sh --bridge-only      # só o geobridge.py
```

Só units/prompt, sem tocar no bridge:

```bash
ssh biel@garime '/tmp/garime-deploy/agent/install.sh --check'   # valida sem instalar
ssh biel@garime '/tmp/garime-deploy/agent/install.sh'
```

Ambos os scripts comparam antes de copiar: rodar duas vezes seguidas imprime `já idêntico` e não reinicia nada à toa.

## Rollback

```bash
sudo systemctl disable --now garime-agent-reset.timer garime-agent.service
sudo rm -f /etc/systemd/system/garime-agent*.{service,timer}
sudo systemctl daemon-reload
```

O bridge continua funcionando sem o agente: `/term/health` passa a responder `agent.running=false`.
