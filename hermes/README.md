# hermes (Geo configuration)

This directory holds the **Geo-specific configuration** for [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), the Python daemon replacing `geo-claw` as Gabriel's always-on personal AI on macOS.

`hermes` itself is upstream code — it is **not** vendored here. This directory only carries the files that get dropped into `~/.hermes/` (or symlinked) so that a fresh hermes install behaves like the geo-claw it succeeds.

## Install hermes (upstream)

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
```

Then apply this directory's config:

```bash
cd hermes
./install.sh
```

`install.sh` is idempotent: existing `~/.hermes/config.yaml` is backed up to `~/.hermes/config.yaml.bak.<timestamp>`; an existing `~/.hermes/.env` is left untouched.

## What lives in this directory

| File | Lands at | Role |
|------|----------|------|
| `config.yaml` | `~/.hermes/config.yaml` | Gateway config: platform toggles, connectors, model defaults, cron. |
| `SOUL.md` | `~/.hermes/SOUL.md` | The persona / identity / tool catalog / guardrails the agent reads every turn. Merge of geo-claw's `SYSTEM_PROMPT` + `soul.default.md`. |
| `memories/MEMORY.md` | `~/.hermes/memories/MEMORY.md` | Persistent world/work memory (2200-char cap). |
| `memories/USER.md` | `~/.hermes/memories/USER.md` | Persistent user profile (1375-char cap). |
| `.env.template` | `~/.hermes/.env` (only if absent) | API keys + runtime flags. |
| `install.sh` | runs from here | Copies the above into `~/.hermes/`. |

## What gets migrated from geo-claw

The cutover from `geo-claw` to `hermes` is not handled by this directory's `install.sh` (it would couple unrelated concerns). The migration steps live in the parent cutover doc, but for reference the bits worth carrying over are:

- **Keychain entries** under service `ai.geo.claw` (Anthropic API key, Telegram token, Google OAuth refresh token, etc.) — re-store under hermes's own keychain service or read directly via `.env`.
- **Baileys auth state** at `~/Library/Application Support/GeoClaw/auth/whatsapp/` — only needed if/when hermes's WhatsApp connector is enabled (it is off by default in `config.yaml`).
- **Gmail OAuth tokens** at `~/Library/Application Support/GeoClaw/auth/gmail/` — re-auth from scratch is usually faster than porting.
- **claw.sqlite** at `~/Library/Application Support/GeoClaw/db/claw.sqlite` — conversation history + FTS5 + kv. Optional; hermes has its own store. Carry over only if you want continuous recall across the switch.
- **LaunchAgent** `ai.geo.claw` — unload (`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.geo.claw.plist`) before booting hermes's own agent to avoid two daemons fighting over WhatsApp/Telegram sessions.

## Cutover steps (high level)

1. Stop geo-claw: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.geo.claw.plist`.
2. Install hermes upstream (see above).
3. Run `./install.sh` from this directory.
4. Fill in `~/.hermes/.env` (Anthropic key + any platform tokens).
5. Boot hermes: `hermes gateway start` (or the LaunchAgent variant the upstream installer provides).
6. Verify MCP wiring: send a Telegram DM and confirm hermes can `list_blocks` via the `geo` MCP server.
7. Once stable, archive `~/Library/Application Support/GeoClaw/` and remove its LaunchAgent plist.

## Hard rules preserved from geo-claw

- **WhatsApp is self-DM only** by default. `config.yaml` ships with WA disabled and an empty allowlist. Read the inline comment before flipping `enabled: true`.
- **The macOS Geo app owns the data on disk.** Hermes reaches blocks/tasks/tags/days through the `geo` MCP server, never by reading files in `~/Library/Application Support/Geo/` directly.
- **Sandbox is off** on the host. Hermes inherits Gabriel's filesystem permissions — same as geo-claw did.

## Upstream

- Repo: <https://github.com/NousResearch/hermes-agent>
- Issues / changelog: track upstream `main` for breaking changes to `config.yaml` schema before bumping.
