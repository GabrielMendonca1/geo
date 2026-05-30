# geo-http-tools

Authenticated HTTP API client for Gabriel's Geo macOS app, as a Hermes plugin.

## Why not MCP?

Geo already speaks MCP via `geo-mcp-bridge` (stdio). But every MCP tool counts against hermes's MCP tool-budget gate, and the `mcp_` prefix collides with hermes UI conventions. This plugin talks to Geo's localhost HTTP API directly so we get:

- Native `geo_*` tool names (no `mcp_` prefix).
- One persistent HTTP/1.1 keep-alive connection per hermes process (vs. a new MCP subprocess per call).
- Bearer auth in a header — same shape any other localhost service would use.

## What's inside

| File | Role |
|---|---|
| `plugin.yaml` | Manifest: 37 tools. |
| `__init__.py` | Plugin entrypoint. Registers tools + the `pre_gateway_dispatch` hook. |
| `client.py` | Singleton `GeoAPIClient` (async httpx). Keychain bearer, lazy 401 refresh, pid liveness check. |
| `matching.py` | Shared title `normalize()` + fuzzy `score()`/`rank()` (stdlib) for the semantic task tools. |
| `tools_read.py` | 18 read tools. |
| `tools_write.py` | 17 non-destructive write tools (incl. `geo_find_tasks` / `geo_resolve_task` / `geo_upsert_task`). |
| `destructive.py` | 2 destructive tools (`geo_delete_block`, `geo_delete_task`) — two-phase prepare → Telegram confirm → commit. |
| `install.sh` | rsync into `~/.hermes/plugins/geo-http-tools/`. |

## Auth (no secrets on disk)

Geo writes two things at boot:

1. `~/Library/Application Support/Geo/api.json` — `{port, pid, ...}`. The plugin checks the pid is alive (`os.kill(pid, 0)`) before trusting the port.
2. macOS Keychain — `service=geo-api-bootstrap`, `account=hermes-runtime`. The plugin reads it with `security find-generic-password -s … -a … -w` and caches in memory.

Every request sends `Authorization: Bearer <token>` and `X-Caller-Id: hermes-runtime`. The token is cached in process memory.

## Token rotation (lazy refresh)

Rotate from Geo.app → Settings → API Access → Rotate. No restart needed.

When the new token lands in the Keychain, the plugin keeps using the old one until it gets a `401 WWW-Authenticate: Bearer realm="rotated"` response. It then re-reads the Keychain once and retries the request. A second 401 means the Keychain still has the old token — the plugin raises `GeoAuthRotated` instead of looping.

## Destructive flow (Telegram confirm)

`geo_delete_block` and `geo_delete_task` are two-phase:

1. **Prepare.** `POST /destructive/prepare` returns `{transaction_id, diff_preview, block_version}`. Geo holds the transaction for 300 s (server-side backstop — if hermes crashes we lose nothing).
2. **DM Gabriel** via `send_message` tool → `telegram:5225262193`:
   > ⚠️ Agent wants to delete block 'foo' (id abc). Diff preview: … Reply Y within 30 s to confirm.
3. **Wait 30 s** wall-clock, polling the inbound queue every 1 s. At 25 s, send a "still waiting — 5 s left" nudge.
4. **Commit or abort.**
   - `Y` / `yes` → `POST /destructive/commit/{transaction_id}` with the `block_version` from prepare in the body (the transaction id is a path segment). On `409 Conflict`, return `{ok: false, reason: "stale_version"}` (someone wrote to the file between phases — re-fetch and retry).
   - `N` / `no` / timeout → never call commit. Geo's 300-s timer expires the prepare on its own. Return `{ok: false, reason: "user_denied" | "timeout"}`.

Inbound replies are captured by a `pre_gateway_dispatch` hook that drops messages from Gabriel's Telegram chat into an in-memory queue. The hook returns `None` so normal hermes dispatch still sees the message (the confirmation goes to the agent loop too — we only observe it).

## Install

```bash
bash install.sh
```

Idempotent. Re-run after edits. The plugin is pure in-process (no LaunchAgent); hermes picks up changes on next restart.

Verify:

```bash
hermes plugins list | grep geo-http-tools
```

## Failure surfaces

| Condition | Exception → tool result |
|---|---|
| `api.json` missing or pid dead | `GeoUnreachable` → `{error: "..."}` |
| Keychain miss / empty | `GeoUnreachable` → `{error: "..."}` |
| 401 after token refresh | `GeoAuthRotated` → `{error: "..."}` |
| 409 on destructive commit | `{ok: false, reason: "stale_version"}` |
| 4xx/5xx on any call | `GeoAPIError` → `{error: "Geo API <status>: <body>"}` |
| Telegram send fails | `{ok: false, reason: "telegram_send_failed"}` (destructive only) |

The agent sees JSON in every case — no exceptions escape the handler.

## Task dedup (stop duplicate tasks)

Three semantic tools sit in front of task creation/editing:

- **`geo_upsert_task`** — the recommended way to create a task. Fuzzy-matches
  the title against pending tasks; if one scores `>= match_threshold` (default
  0.82, and any provided `kind` agrees) it updates that task instead of making a
  duplicate. Otherwise it creates. `force_new=true` skips the check.
- **`geo_find_tasks`** — search pending (or all) tasks by query, ranked. Call
  before creating if you want to inspect candidates yourself.
- **`geo_resolve_task`** — map a natural-language reference to ONE task id (for
  complete/update/delete by name), or return the top-3 candidates to disambiguate.

Normalization + scoring live in `matching.py` (`normalize`, `score`, `rank`),
stdlib only: accent-stripped, lowercased, punctuation-dropped titles compared via
`difflib.SequenceMatcher` ratio, token Jaccard, and substring — taking the max.

## Server-side dependency

`geo_ai_parse_task` (`POST /tasks/parse`) currently 500s: the server tool
`ai_quick_add_parse` is not registered yet. The client path is correct; the tool
will work once the Lane S server fix lands.
