# geo-claw

24/7 always-on Claude agent that handles WhatsApp + Gmail autoreply on macOS. Connects to the Geo MCP server for tool access (tasks, calendar, blocks, tags, etc.).

## What it does

- Reads incoming WhatsApp messages from any chat. **Only sends** to the chat with your own number (self-DM) — hard guarded.
- Reads Gmail and auto-replies in-thread.
- Calls Geo's MCP tools to answer "what's on my plate today", "create a task to X", "summarize my notes about Y", etc.
- Runs as a macOS LaunchAgent — starts at login, restarts on crash, lives even when the Geo Mac app is closed.

## Requirements

- Node.js 20+
- macOS (LaunchAgent + Keychain)
- `ANTHROPIC_API_KEY` exported
- Gmail OAuth credentials (Desktop client from Google Cloud Console) — `GEO_CLAW_GOOGLE_CLIENT_ID` and `GEO_CLAW_GOOGLE_CLIENT_SECRET`

## Install + build

```bash
cd geo-claw
npm install
npm run build
```

## Run

```bash
node dist/index.js          # full daemon, watches signals, starts adapters if creds exist
node dist/index.js --repl   # interactive REPL for LLM testing (no adapters)
npm run dev                 # tsx watch
```

## Pair WhatsApp / authorize Gmail

The daemon watches `~/Library/Application Support/GeoClaw/signals/` for action files. Either trigger them from the Geo macOS app's Nano Claw settings card, or by hand:

```bash
# Pair WhatsApp (writes a QR PNG to signals/qr.png; scan from Linked Devices)
touch ~/Library/Application\ Support/GeoClaw/signals/request-pair-whatsapp

# Authorize Gmail (opens browser for OAuth)
touch ~/Library/Application\ Support/GeoClaw/signals/request-auth-gmail
```

Other signals: `disconnect-whatsapp`, `disconnect-gmail`, `bootstrap-token` (drop a base64 MCP auth token to enroll the daemon).

## LaunchAgent

```bash
./scripts/install-launchagent.sh
./scripts/uninstall-launchagent.sh
```

## Paths

- App support: `~/Library/Application Support/GeoClaw/`
  - `auth/whatsapp/` — Baileys multi-device session
  - `auth/gmail/` — reserved
  - `db/claw.sqlite` — conversation memory + kv
  - `signals/` — input signal files + QR output
  - `status.json` — current state (read by Geo Swift UI)
- Logs: `~/Library/Logs/GeoClaw/claw.log`
- MCP socket (read): `~/Library/Application Support/Geo/mcp.sock`
- Keychain service: `ai.geo.claw` (accounts: `mcp`, `gmail-refresh`, `gmail-access`)

## Env

Required:
- `ANTHROPIC_API_KEY`
- `GEO_CLAW_GOOGLE_CLIENT_ID`, `GEO_CLAW_GOOGLE_CLIENT_SECRET` (Gmail)

Optional:
- `GEO_CLAW_DEV=1` enables pretty stdout logging
- `GEO_CLAW_LOG_LEVEL=debug|info|warn|error` (default `info`)

The daemon loads `~/Library/Application Support/GeoClaw/env` at boot (KEY=VALUE per line, `#` comments OK, quotes optional). Existing process env wins, so `launchctl setenv` and shell exports take precedence. Example:

```
ANTHROPIC_API_KEY=sk-ant-...
GEO_CLAW_GOOGLE_CLIENT_ID=...apps.googleusercontent.com
GEO_CLAW_GOOGLE_CLIENT_SECRET=...
```

Set perms to `0600` (`chmod 600 ~/Library/Application\ Support/GeoClaw/env`).
