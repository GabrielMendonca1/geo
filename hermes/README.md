# hermes (Geo layer)

Geo-specific layer over [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — Gabriel's always-on personal agent on macOS. Upstream is **not** vendored here; `~/.hermes/hermes-agent` carries the upstream code plus the minimal fork patches documented in [`PATCHES.md`](PATCHES.md) (reapply after every upstream update — cherry-pick does not survive releases).

This directory holds the files that land in `~/.hermes/` (copied or symlinked by `install.sh`):

| Path | Lands at | Role |
|------|----------|------|
| `config.yaml` | `~/.hermes/config.yaml` | Gateway config: platforms, connectors, model lanes, cron |
| `SOUL.md` | `~/.hermes/SOUL.md` (symlink) | Identity / guardrails — single copy, repo is truth |
| `hooks/geo-context/` | `~/.hermes/hooks/` | Auto-injection of vault context (profile, memory, today, tasks) |
| `scripts/` | `~/.hermes/scripts/` | `geo_indexer.py` (vault → FTS index), `context_scraping.py` (WhatsApp → life-context), `close-day.py`, `todo-command.py` |
| `whatsapp-ingest/` | `~/.hermes/whatsapp-ingest/` | Baileys sidecar: message log + media download (v3) |
| `launch-agents/` | `~/Library/LaunchAgents/` | plists dos daemons |
| `memories/`, `.env.template` | `~/.hermes/` | Seeds (existing `.env` untouched) |

`install.sh` is idempotent (existing config backed up with timestamp).

## Hard rules

- **The vault (`~/Vault/`) is reached only via the filesystem** — geo-tools plugin for reads/writes under the layer guard. MCP and the HTTP API are retired; the old app-owned path `~/Library/Application Support/Geo/` is a frozen backup nothing touches.
- **Two live copies**: this directory (source) and `~/.hermes/` (runtime). Check drift (md5) before editing either side.
- **WhatsApp allowlist discipline** — read the inline comments in `config.yaml` before widening.
