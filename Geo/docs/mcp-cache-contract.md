# MCP Cache Contract

What this is: the wire contract `scripts/geo-cache-sync.py` (running on the VM) uses to keep `/root/.hermes/geo-cache/` in sync with the Geo macOS app's MCP server.

## Table of Contents

1. [Connecting](#1-connecting)
2. [Pull Phase (Phase 1)](#2-pull-phase-phase-1)
3. [Push Phase (Phase 2)](#3-push-phase-phase-2--subscribe)
4. [Migration Notes](#4-migration-notes-for-geo-cache-syncpy)
5. [Consumption Flow](#5-consumption-flow-recommended-pseudo-code)
6. [Gotchas](#6-gotchas)

---

## 1. Connecting

Transport is JSON-RPC 2.0 over a Unix socket or TCP, line-framed via `MCPFramer`. The first frame on every new connection must be an `initialize` request whose `params` carry the per-endpoint bearer token; the server rejects and closes the socket if the token is missing or invalid, and auth has a 10-second timeout. Full handshake logic lives in `Shared/Infrastructure/MCP/MCPConnection.swift` lines 263-293 (`handleAuthHandshake` + `extractToken`); the VM worker should reproduce the same shape.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "authToken": "<per-endpoint token>",
    "protocolVersion": "2024-11-05",
    "capabilities": {}
  }
}
```

The token may also be supplied at `params._meta.authToken` or `params.auth.token`; pick one and stick with it. The connection has a 120s idle timeout with server-initiated `ping` notifications after 300s of silence; the worker must tolerate and ignore `ping`.

---

## 2. Pull Phase (Phase 1)

Poll every 5 minutes. Track two cursors in `state.json`: `blocks_since` and `tasks_since`, each equal to the max `last_edited` / `modified_at` observed in the last successful response. First run omits the cursor and uses the 30-day snapshot window; every subsequent run uses the 14-day incremental window.

### 2.1 `list_blocks`

Initial snapshot (first run, cold cache):

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "list_blocks",
    "arguments": { "include_content": true, "days": 30 }
  }
}
```

Returns every block edited in — or linked to a day within — the last 30 days, with full markdown inline.

Incremental poll (every run thereafter):

```json
{
  "name": "list_blocks",
  "arguments": {
    "include_content": true,
    "since": "2026-04-18T14:02:11Z",
    "days": 14
  }
}
```

Returns only blocks whose `last_edited > since`, bounded to the 14-day window.

Response shape (per block):

```json
{
  "id": "blk_01H...",
  "title": "Monday review",
  "last_edited": "2026-04-18T14:02:11Z",
  "tag_name": "work",
  "day_id": "2026-04-18",
  "markdown": "# Monday review\n\n- ..."
}
```

`id`, `title`, `last_edited` are always present. `tag_name` and `day_id` are optional. `markdown` is present iff `include_content=true`.

### 2.2 `list_tasks`

Default response is pending-only (not completed, not archived). To retrieve all statuses pass `"status": "all"`. The VM cache stays on pending-only.

Initial snapshot:

```json
{
  "name": "list_tasks",
  "arguments": { "days": 30 }
}
```

Returns pending tasks whose `modified_at` OR `start_time` falls within the last 30 days or next 30 days.

Incremental poll:

```json
{
  "name": "list_tasks",
  "arguments": {
    "since": "2026-04-18T14:02:11Z",
    "days": 14
  }
}
```

Response shape (per task):

```json
{
  "id": "tsk_01H...",
  "title": "Ship cache sync",
  "status": "pending",
  "kind": "task",
  "priority": "high",
  "start_time": "2026-04-18T09:00:00Z",
  "end_time": "2026-04-18T10:00:00Z",
  "modified_at": "2026-04-18T14:02:11Z",
  "linked_block_id": "blk_01H...",
  "parent_id": "tsk_01G..."
}
```

`id`, `title`, `status`, `kind`, `priority`, `start_time`, `modified_at` are always present. `end_time`, `linked_block_id`, and `parent_id` are optional.

**Subtasks:** tasks form a parent/child tree via `parent_id`. When present, it's the UUID of another task in the same `list_tasks` response. Consumers that want to render hierarchies (e.g. briefing bullets with indented children) group by `parent_id` client-side — no separate endpoint needed.

### 2.3 Cursor strategy

`state.json` holds:

```json
{
  "blocks_since": "2026-04-18T14:02:11Z",
  "tasks_since":  "2026-04-18T14:02:11Z"
}
```

After each successful poll, set each cursor to `max(last_edited | modified_at)` across the returned records. If the response is empty, do not advance the cursor. On the first ever poll, omit `since` entirely and use `days: 30`.

---

## 3. Push Phase (Phase 2) — subscribe

Two new methods: `geo/subscribe` and `geo/unsubscribe`. Subscription state is per-connection and discarded on disconnect; the worker must re-subscribe after every reconnect.

Subscribe request:

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "geo/subscribe",
  "params": { "kinds": ["task", "block"] }
}
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": { "ok": true, "subscribed": ["task", "block"] }
}
```

Empty or missing `kinds` subscribes to all kinds.

Unsubscribe:

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "geo/unsubscribe",
  "params": { "kinds": ["task"] }
}
```

Server-pushed change notification (one-way, no `id`):

```json
{
  "jsonrpc": "2.0",
  "method": "geo/changed",
  "params": {
    "kind": "task",
    "id": "tsk_01H...",
    "op": "upsert",
    "modified_at": "2026-04-18T14:03:22Z"
  }
}
```

Consumer pattern:

- `op: "upsert"` -> issue `get_task` or `get_block` by `id` to fetch the full record, then merge into the local cache. To coalesce bursts, batch `ids: [...]` in a single `get_block` / `get_task` call instead of one request per event.
- `op: "delete"` -> remove the record from `snapshot.json` and the corresponding `blocks/<id>.md` file.

Recommendation for Phase 2 rollout: keep Phase 1 polling enabled at a reduced cadence (every 30 min) as a safety net. Subscriptions die silently on reconnect, and events dropped during a network blip will only be recovered by the polling cursor.

---

## 4. Migration Notes for `geo-cache-sync.py`

- `list_blocks` supports `include_content=true` and returns full markdown inline. **Delete the N+1 `get_block` code path.**
- `list_tasks` default is now pending-only. The cache stays on pending-only per the user decision, so no change needed. If a caller wants the old behavior it must pass `"status": "all"`.
- `list_tasks` always returns `modified_at` — use this for `tasks_since` in `state.json`.
- `list_blocks` always returns `last_edited` — use this for `blocks_since` in `state.json`.
- `get_block` and `get_task` now accept `ids: [string]` for batch fetching (single roundtrip for N subscription events). `id` (singular) still works for one-off fetches.
- **Removed tools (v2):** `complete_task` → use `update_task` with `status: "completed"`. `get_today` → `get_day` with no `date` argument. `link_block_to_day` → no replacement; `create_block` auto-links the day.
- **`create_task` schema flattened:** the old nested `recurrence: {type, selected_weekdays}` is now top-level `recurrence_type` + `recurrence_weekdays`. The rarely-used `recurring_reminders` field was removed (set via the app UI if needed).
- On `initialize`, the server now returns an `instructions` string summarising entities, sync model, and conventions. Agents should surface this to their planner so they pick tools correctly.

---

## 5. Consumption Flow (recommended pseudo-code)

```python
state = load_json("/root/.hermes/geo-cache/state.json")
snap  = load_json("/root/.hermes/geo-cache/snapshot.json")

blocks = mcp.call("list_blocks", include_content=True,
                  since=state.get("blocks_since"), days=14)
tasks  = mcp.call("list_tasks",
                  since=state.get("tasks_since"),  days=14)

for b in blocks:
    snap["blocks"][b["id"]] = {k: b[k] for k in b if k != "markdown"}
    write_file(f"/root/.hermes/geo-cache/blocks/{b['id']}.md", b["markdown"])
for t in tasks:
    snap["tasks"][t["id"]] = t

if blocks: state["blocks_since"] = max(b["last_edited"]  for b in blocks)
if tasks:  state["tasks_since"]  = max(t["modified_at"] for t in tasks)

save_json("/root/.hermes/geo-cache/snapshot.json", snap)
save_json("/root/.hermes/geo-cache/state.json",    state)
append_jsonl("/root/.hermes/geo-cache/log/sync.jsonl",
             {"at": now_iso(), "blocks": len(blocks), "tasks": len(tasks)})
```

---

## 6. Gotchas

- Timestamps are ISO8601 UTC with a `Z` suffix (e.g. `2026-04-18T14:02:11Z`). Python 3.11+ accepts this via `datetime.fromisoformat`; on older versions strip the trailing `Z` and append `+00:00`, or use `dateutil.parser.isoparse`.
- `since` is a strict `>` comparison. Re-sending the exact last observed timestamp returns zero records — never treat an empty response as a cursor bug.
- Invalid ISO8601 passed to `since` returns a tool error: `{ "isError": true, "content": [...] }`. Parse defensively and do not advance the cursor.
- `days: 0` disables the window filter entirely. Only use it for a one-shot full resync — do not ship it as the default.
- `tag_name` filter on `list_blocks` is case-insensitive. If the tag does not exist, the server currently returns blocks that have no tag at all (i.e. it collapses to an untagged filter). This is almost never what a caller wants; validate the tag exists before filtering by it.

---

Version: v2 — 2026-04-20
