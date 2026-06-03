# geo-mcp-subscriber

A LaunchAgent daemon that replaces the `geo-context` hook's session-start HTTP
poll with **MCP push**. It holds one persistent Unix-socket connection to the
Geo macOS app, subscribes to `block`/`task` changes, and keeps the boot-bundle
cache warm so every hermes session starts from a local file read instead of a
burst of HTTP round-trips.

## Why

Before: on every `session:start`/`session:reset`, the hook made 4 HTTP GETs to
Geo (User Profile, Memory, Interaction Protocol, Today), TTL-gated at 60s.

After: this daemon subscribes once (`geo/subscribe {kinds:["block","task"]}`)
and, on every `geo/changed` push, refetches those 4 pieces over the **same
socket** and atomically rewrites `~/.hermes/geo-cache/snapshot.json`. The hook
reads that snapshot (freshness-gated) and only falls back to HTTP if the cache
is missing or stale.

Net: session start is a local read; the bundle is always push-fresh; one
long-lived connection replaces per-session HTTP + token-refresh + ephemeral-port
reconnect logic. The socket is the fastest local transport (it beat HTTP
keepalive ~3x on a no-work op in the transport benchmark).

## Design

- **Single transport.** The socket carries both the change *signal*
  (`geo/changed`) and the *fetch* (`tools/call get_block_by_title` / `get_today`
  / `list_tasks`). No token, keychain, httpx, or ephemeral HTTP port — the unix
  transport has no auth (0600, owner-only).
- **Render-ready snapshot (schema v2).** The daemon does the parsing once, at
  write time: blocks are unwrapped + frontmatter-stripped, today and open tasks
  are pre-formatted to their final lines. The hook just concatenates — no
  per-turn re-parse. Shape:
  ```json
  {"v": 2, "fetched_at": 1733250000.0,
   "profile_md": "...", "memory_md": "...", "protocol_md": "...",
   "today_line": "date: ... · ...", "tasks_md": "- task (date · priority)\n..."}
  ```
  Any pre-v2 snapshot is treated as a cache miss by the hook, so the daemon and
  hook can ship in either order.
- **Pure accelerator.** If the daemon is down or Geo is closed, the cache goes
  stale and the hook falls back to live HTTP — identical to the old behavior.
  Nothing breaks; it only gets slower.
- **Resilient.** Reconnects with capped backoff, re-subscribes on every
  reconnect (subscriptions are per-connection), tolerates server `ping`,
  coalesces bursts (1.5s debounce), and re-fetches every 10 min as a
  missed-event safety net.

Wire contract: `Geo/docs/mcp-cache-contract.md`. Reference client:
`Geo/scripts/mcp-unix-smoke.py`.

## Install

```bash
bash hermes-extensions/geo-mcp-subscriber/install.sh
launchctl list ai.hermes.geo-mcp-subscriber     # verify
tail -f ~/.hermes/logs/geo-mcp-subscriber.out.log
cat ~/.hermes/geo-cache/snapshot.json
```

Requires the Geo app running (so `~/Library/Application Support/Geo/mcp.sock`
exists) and the hermes venv (`~/.hermes/hermes-agent/venv`).

## Files

| File | Role |
|---|---|
| `daemon.py` | The subscriber loop (stdlib only). |
| `ai.hermes.geo-mcp-subscriber.plist` | LaunchAgent template (`__VAR__` placeholders). |
| `install.sh` | rsync to `~/.hermes/daemons/` (NOT `plugins/` — no tools, stays out of the plugin scanner), template plist, bootstrap. |
| `plugin.yaml` | Metadata (`kind: daemon`, no tools). |
| `__init__.py` | No-op plugin shell; the daemon does the work. |

The consumer side lives in `hermes/hooks/geo-context/handler.py`
(`_read_cache_bundle` → cache-first in `_fetch_geo_blocks`).
