# GeoBridge — API contract

HTTP daemon on the Mac exposing three local resources to the tailnet for the iPhone app. The bridge is a **dumb pipe over files**: it never re-models data. Reads return file contents **verbatim** (zero re-encode); mutations are minimal field edits; streams are line pass-through. The Mac app (Geo.app) and hermes remain the owners of all state — the bridge only relays it.

Spec version: 3 (v2 + `/term/*` terminal). All facts below were extracted from the live system on 2026-07-01 (real task files, real dispatch dirs, `TaskItem.swift`, `TasksStore.swift`, `HermesKanbanService.swift`, `api_server.py`, `~/.hermes/config.yaml`).

## Principles

1. **Verbatim reads.** `GET /tasks` concatenates the raw bytes of the task files into a JSON array. The bridge never parses-then-re-serializes for reads: field order, number formatting, and unknown keys reach the phone exactly as written by Geo.app.
2. **Minimal mutations.** Complete/reopen change exactly two fields (`status`, `modifiedAt`) and preserve every other key untouched, then write atomically (temp file + rename in the same directory). Geo.app's `FileWatcherService` on the Tasks dir picks the change up and updates its in-memory store and EventKit mirror — the bridge only has to write the file correctly (see "Mac-app integration facts").
3. **Line pass-through streams.** Dispatch logs and hermes chat SSE are relayed line-for-line / byte-for-byte, never interpreted.
4. **No speculative surface.** Task create exists as of v2 because the phone needs it — and even there the bridge stays a dumb pipe (the phone sends the complete task JSON; the bridge validates and writes, never composes). Still no task update/delete, no dispatch spawn, no session management endpoints. Add them only when the phone needs them.

   **Carve-out — the terminal (`/term/*`, v3).** The terminal is the deliberate exception to principle 4: it is *not* a dumb pipe over files, it is an arbitrary interactive shell as the local user, streamed over the tailnet. This is the single largest blast radius in the whole surface — anyone holding the term token can run any command `biel` can (read/exfiltrate the vault, `rm -rf`, `git push`, spend money, pivot). It is justified because the phone genuinely needs a real terminal (agents live in shells), and it is fenced with five independent controls: (1) a **separate** token (`GEO_BRIDGE_TERM_TOKEN_FILE`) so it can be revoked without touching the rest of the bridge; (2) `GEO_TERM_ENABLED=0` by default → `/term/*` is `404` until explicitly turned on in the plist; (3) tailnet-only bind (unchanged); (4) keystrokes are **never** logged (input rides only in the POST body; the log records method+path only — so `open`/`close`/`resize` show up, never typed bytes); (5) idle-detach of the live attach after 10 min. Do not extend this surface (session spawn/list, file upload, etc.) without re-justifying the blast radius.

## Configuration (env vars)

| Var | Default | Meaning |
|---|---|---|
| `GEO_TASKS_DIR` | `~/GeoVault/Tasks` | One `<id>.json` per task |
| `GEO_DISPATCHES_DIR` | `~/.hermes/dispatches` | One dir per cc-dispatch worker |
| `GEO_BRIDGE_BIND` | `100.123.44.9` | Tailnet address to bind (never `0.0.0.0`) |
| `GEO_BRIDGE_PORT` | `8643` | |
| `GEO_BRIDGE_TOKEN_FILE` | `~/.hermes/geobridge.token` | Bearer token for bridge auth (single line, trimmed) |
| `HERMES_URL` | `http://127.0.0.1:8642` | hermes api_server (loopback; bridge is its only tailnet exposure) |
| `HERMES_KEY_FILE` | `~/.hermes/api_server.key` | File whose trimmed content equals hermes `API_SERVER_KEY` |
| `GEO_TERM_ENABLED` | `0` | `1` enables `/term/*`; anything else → `/term/*` is `404` |
| `GEO_TERM_TMUX` | `/opt/homebrew/bin/tmux` | Absolute path to `tmux` (launchd `PATH` is minimal) |
| `GEO_TERM_SHELL` | *(unset)* | If set, exported as `SHELL` to the tmux child (else tmux's default) |
| `GEO_TERM_SESSION` | `mobile` | Name of the single durable tmux session |
| `GEO_BRIDGE_TERM_TOKEN_FILE` | `~/.hermes/geobridge.term.token` | Second, dedicated bearer token for `/term/*` (single line, trimmed) |

## Auth

Every endpoint except `GET /health` requires:

```
Authorization: Bearer <contents of GEO_BRIDGE_TOKEN_FILE>
```

Constant-time comparison. Missing/wrong token → `401 {"error":"unauthorized"}`. If the token file is missing or empty at startup, the bridge must refuse to start (mirrors hermes: its `connect()` refuses to start without `API_SERVER_KEY`).

**Exception: `/term/*`** authenticate with a *separate* token (`GEO_BRIDGE_TERM_TOKEN_FILE`), are gated behind `GEO_TERM_ENABLED`, and their token being absent does NOT block startup — see the Terminal section.

Path parameters `{id}` (tasks and dispatches) must match `^[A-Za-z0-9._-]+$`; anything else → `400 {"error":"invalid_id"}`. This plus "join under the configured dir only" is the whole anti-path-traversal story.

## Endpoints

### GET /health — no auth

```
200 {"ok":true}
```

### GET /tasks

Returns `Content-Type: application/json`. Body is built by splicing raw file bytes:

```
[ <bytes of file1.json> , <bytes of file2.json> , ... ]
```

- Files: every `*.json` in `GEO_TASKS_DIR` (non-`.json` entries ignored — same filter as `TasksStore.jsonURLs()`).
- Order: filename ascending (deterministic; the app itself sorts in memory by `createdAt`, the phone can too).
- Unreadable or invalid-JSON file → skip it, don't fail the request. Files written by the two known writers (Geo.app `Data.write(options: .atomic)` and this bridge's temp+rename) are always complete JSON, but the bridge still parse-validates each file (splicing the raw bytes on success) so a junk/third-party file can't poison the whole array.
- Empty dir → `[]`.

**Task file shape (observed verbatim; encoded by Swift `JSONEncoder` with `.iso8601` dates — key order is nondeterministic between files):**

```json
{"createdAt":"2026-06-15T15:00:53Z","id":"04E93A54-7E03-4E39-9E8D-0719BBB9B4DA","modifiedAt":"2026-07-01T12:27:07Z","orderIndex":0,"reminders":[],"status":"completed","body":{"due":"2026-06-15T19:00:00Z","kind":"task"},"priority":"unset","title":"Confirmar horário da reunião com Bernardo","externalEKEventID":"E4C077D6-…:78706384-…","tagIds":[]}
```

Facts the client can rely on (from `GeoCore/Sources/GeoCore/TaskItem.swift`):

- Filename = `<id>.json`; `id` is an uppercase UUID string and equals the JSON `id` field (`TasksStore.taskURL(for:)`).
- `status`: exactly `"pending"` or `"completed"` (enum `TaskStatus`).
- `priority`: `"urgent" | "high" | "medium" | "low" | "unset"`.
- `body` is discriminated by `body.kind`:
  - `"task"` → `due` (date), optional `estimatedMinutes` (int)
  - `"event"` → `start`, `end` (dates), optional `externalEKEventID`
  - `"habit"` → `rule` (object: `type` + optional `customFrequency`/`customInterval`/`endDate`/`selectedWeekdays`), `timeOfDay` (date), `occurrences` (date array)
  - `"milestone"` → `target` (date)
- Dates: ISO 8601, second precision, `Z` suffix, e.g. `"2026-07-01T21:15:01Z"`.
- `reminders`: array of `{"id":"<UUID>","trigger":{"kind":"offset","offset":"At time"} | {"kind":"absolute","date":"<iso8601>"},"fired":bool}`. `offset` raw values are human strings (`"At time"`, `"5 minutes before"`, …).
- Optional keys omitted when nil: `linkedBlockId`, `estimatedMinutes`, `externalEKEventID`, `isAllDay`. A legacy top-level duplicate `estimatedMinutes` can coexist with `body.estimatedMinutes` (observed in real files).

### POST /tasks — added in v2

Creates `GEO_TASKS_DIR/<id>.json`. The phone owns composition: it generates the id (uppercase UUID string, same as Geo.app's `UUID().uuidString`) and sends the **complete task JSON** in the request body — the bridge validates, writes the bytes, and never fills in or rewrites fields.

Request body: one task object in the exact file shape documented under `GET /tasks`, e.g.:

```json
{"id":"5B8F3C21-9D4E-4A07-B1C6-2E8D0F7A3941","title":"Comprar filtro","status":"pending","priority":"unset","tagIds":[],"orderIndex":0,"createdAt":"2026-07-01T18:30:00Z","modifiedAt":"2026-07-01T18:30:00Z","body":{"kind":"task","due":"2026-07-02T14:00:00Z"},"reminders":[{"id":"0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9","trigger":{"kind":"offset","offset":"At time"},"fired":false}]}
```

1. Validate: body parses to a JSON object with `id` matching the id regex, `title` a non-empty string, `body.kind` ∈ `task | event | habit | milestone`, and `createdAt` a string. Anything else → `400 {"error":"invalid_body"}`. The bridge does not validate deeper (dumb pipe); the Mac decoder's documented tolerances absorb shape drift.
2. Reserve the filename with `open(O_CREAT|O_EXCL)`; file already exists → `409 {"error":"task_exists"}`.
3. Write atomically exactly like the mutations: temp file **in the same directory**, `fsync`, `rename(2)` over `<id>.json`.
4. `201` with the exact bytes written.

Facts the phone must honor:

- Dates: ISO 8601, second precision, `Z` suffix, **no fractional seconds** — the Mac decodes with Swift `JSONDecoder.dateDecodingStrategy = .iso8601`, which rejects fractions (`TasksStore.swift:394,494`).
- iOS never sends `externalEKEventID` — the Mac fills it via the EventKit mirror after `FileWatcherService` picks the new file up (`handleExternalChanges` → `scheduleMirror`), so the phone sees it on a later `GET /tasks`.

### POST /tasks/{id}/complete and POST /tasks/{id}/reopen

Minimal mutation of `GEO_TASKS_DIR/<id>.json`:

1. Validate `{id}` regex. File missing → `404 {"error":"not_found"}`.
2. Read the file, parse into a generic JSON map (unknown keys preserved as-is; task files contain only strings/ints/bools/arrays/objects, so a generic round-trip is byte-stable for everything not touched).
3. Set exactly:
   - `status` → `"completed"` (complete) or `"pending"` (reopen)
   - `modifiedAt` → now, ISO 8601 UTC second precision with `Z` (e.g. `"2026-07-01T22:04:09Z"`) — must parse under Swift `JSONDecoder.dateDecodingStrategy = .iso8601`, so no fractional seconds.
4. Serialize and write atomically: write to a temp file **in the same directory**, `fsync`, `rename(2)` over `<id>.json`. Same-directory temp is mandatory (rename must be atomic on the same volume, and `FileWatcherService` watches this directory). Before the rename the bridge re-stats `<id>.json`; if mtime/size changed since the read (Geo.app wrote concurrently), it discards the temp and redoes the read-modify-write once.
5. `200` with the exact bytes just written (the new task JSON).

Idempotent: completing a completed task rewrites `modifiedAt` only.

### GET /dispatches

`200` JSON array, **newest-first** (sort key: `meta.started_at` descending, fallback directory name — dir names start with the same unix timestamp, e.g. `1781189063-cond-alpha-deploy-vm-vercel`):

```json
[{"id":"<dirname>","meta":<verbatim bytes of meta.json>,"status":"running"}]
```

- One entry per subdirectory of `GEO_DISPATCHES_DIR` containing a parseable `meta.json` (dirs without it are skipped — same rule as `HermesKanbanService.task(in:)`).
- `meta` is spliced verbatim (it is pretty-printed JSON written by cc-dispatch). Observed shape: `{"id","title","dir","model","prompt","started_at":<unix seconds number>}`.
- `status` = trimmed content of the `status` file; values written by the CLI are `running | done | failed`; missing/empty file → `"running"` (matches `HermesKanbanService`). The bridge does NOT remap `failed`→`blocked` (that is a Mac-UI concern).
- Other files in the dir (`pid`, `ended_at` unix-seconds string, `result.json` with `result`/`error` string) exist but are not surfaced in v1.

### GET /dispatches/{id}/stream

SSE (`Content-Type: text/event-stream`). Validate `{id}` regex; dir or `meta.json` missing → `404`.

1. **Replay:** emit every existing line of `log.jsonl`, one SSE message per line, data = the raw line verbatim:

   ```
   data: {"type":"system","subtype":"init","cwd":"…","session_id":"…", …}

   ```

   Lines are `claude -p --output-format stream-json` events — JSON objects with a `type` discriminator (`"system"` with `subtype` `init`/`thinking_tokens`, `"rate_limit_event"`, `"assistant"`, `"user"`, `"result"`, …), each carrying `uuid` and `session_id`. The bridge never parses them.
2. **Follow:** poll `log.jsonl` size every ~0.5 s, emitting new complete lines (buffer partial trailing lines until the newline arrives).
3. **Terminate:** when the `status` file reads anything other than `running`, flush remaining lines, then:

   ```
   event: done
   data: {"status":"done"}

   ```

   and close. `log.jsonl` absent → skip straight to follow/terminate logic.

### POST /chat/stream

Proxy to hermes' **session chat stream** — chosen endpoint: `POST {HERMES_URL}/api/sessions/{session_id}/chat/stream`.

Why this one over `/v1/chat/completions` + `X-Hermes-Session-Id`: history is persisted server-side in hermes' SessionDB (the phone sends only the new message, never a transcript), the SSE events are named and richer (tool progress, run lifecycle) which a chat UI wants, and `GET /api/sessions/{id}/messages` exists upstream for history hydration later. `/v1/chat/completions` is OpenAI-shape for third-party frontends; for a first-party personal channel the sessions API is strictly better.

Bridge request:

```json
{"session_id":"iphone-main","message":"oi geo"}
```

- `session_id` must match the id regex; missing/invalid → `400`. `message` required (hermes also accepts `input` and multimodal content arrays; the bridge forwards the body's `message` untouched).
- Bridge forwards `{"message": …}` to `POST {HERMES_URL}/api/sessions/{session_id}/chat/stream` with header `Authorization: Bearer <contents of HERMES_KEY_FILE>`.
- If hermes answers `404` code `session_not_found`, the bridge issues `POST {HERMES_URL}/api/sessions` with body `{"id":"<session_id>"}` (201 expected, 409 `session_exists` acceptable) and retries the stream once.
- The hermes SSE response is relayed **byte-for-byte** (including `: keepalive` comment lines, sent every 30 s upstream). Response headers to copy: `Content-Type: text/event-stream`; upstream also sets `X-Hermes-Session-Id`.
- hermes unreachable (connect error/timeout before first byte) → `502 {"error":"hermes_unreachable"}`. Upstream non-2xx → relay upstream status and JSON body as-is.

**Upstream SSE contract (from `api_server.py::_handle_session_chat_stream`)** — messages are `event: <name>\ndata: <json>\n\n`; every payload carries `session_id`, `run_id`, `seq` (monotonic int), `ts` (unix float):

| event | payload extras |
|---|---|
| `run.started` | `user_message: {role:"user", content}` |
| `message.started` | `message: {id:"msg_<hex>", role:"assistant"}` |
| `assistant.delta` | `message_id`, `delta` (text chunk) |
| `tool.started` / `tool.completed` / `tool.failed` | `message_id`, `tool_name`, `preview`, `args` |
| `tool.progress` | `message_id`, `tool_name` (`"_thinking"` for reasoning), `delta` |
| `assistant.completed` | `message_id`, `content` (full text), `completed`, `partial`, `interrupted` |
| `run.completed` | `message_id`, `completed`, `messages` (turn transcript), `usage` |
| `error` | `message` (redacted) |
| `done` | terminal, always sent (finally block) |

## Terminal — `/term/*` (added in v3)

A real interactive terminal for the phone. **Not** a dumb pipe over files (see the principle-4 carve-out above for the blast-radius warning). Three endpoints, all gated and separately authed.

**Persistence = tmux.** The durable layer is a single tmux session named `GEO_TERM_SESSION` (default `mobile`) on `GEO_TERM_TMUX` (default `/opt/homebrew/bin/tmux`, absolute — launchd `PATH` is minimal). Each `/term/stream` is an **ephemeral attach**: the bridge `pty.fork()`s and `exec`s `tmux -u new-session -A -s <session>` (`-A` = attach if it exists, else create). The tmux server owns the session; the PTY/attach the bridge forks is disposable. So the session survives phone lock, tab switch, app kill, idle-detach, and even a bridge restart — reconnecting re-attaches the same live shell. `GEO_TERM_SHELL`, if set, is exported as `SHELL` to the child so tmux picks that shell; otherwise tmux's default.

**Gating and auth (differs from the rest of the bridge).** `/term/*` do **not** use the main bridge token. They require:
1. `GEO_TERM_ENABLED == "1"` **and** a non-empty `GEO_BRIDGE_TERM_TOKEN_FILE`. If either is false, `/term/*` → `404 {"error":"not_found"}` (indistinguishable from "route doesn't exist"). A missing/empty term-token file keeps `/term/*` at `404` **even when `GEO_TERM_ENABLED=1`**.
2. `Authorization: Bearer <contents of GEO_BRIDGE_TERM_TOKEN_FILE>` (constant-time compare). Enabled + token present but wrong/absent header → `401 {"error":"unauthorized"}`.

The term token is generated by `install.sh` alongside the main token (`openssl rand -hex 32`, `chmod 600`). Its absence does **not** block bridge startup (only the main token does); it simply leaves `/term/*` dark.

**Framing.** All PTY bytes are **base64** in both directions — raw terminal I/O is binary (ANSI/control bytes, UTF-8 fragments) and does not survive SSE's line protocol or JSON otherwise.

**last-writer-wins.** A single session has at most one live attach. Opening a new `/term/stream` for a session that already has one **takes over**: the bridge forks the new attach, swaps it into the registry, then `SIGKILL`s the old attach's PTY child. The old stream detects it is no longer the registered attach (or its PTY hits `EIO`), emits `event: done` and closes. The tmux session itself is untouched — only the attach is stolen. There is no queuing or rejection; the newest connection always wins.

### GET /term/stream — SSE

Attaches to the session and streams its output.

- Content-Type: `text/event-stream`.
- Each chunk of PTY output: `data: <base64 of raw bytes>\n\n`.
- Keepalive: `: keepalive\n\n` every 15 s of no output (covers the client's 90 s stream timeout).
- Terminal: on PTY `EIO`/child exit, on idle-detach, or on takeover by a newer stream → `event: done\ndata: {"status":"closed"}\n\n`, then close. The tmux session survives all of these.
- **Idle-detach:** after `10 min` with no client **input** (`/term/input` or `/term/resize` resets the timer; output does **not**), the attach is killed and `done` is sent. Reconnect to re-attach. tmux keeps running whatever was launched (e.g. a `while true; do date; sleep 1; done` is still there on reconnect).

### POST /term/input

Writes raw keystrokes to the session's PTY master.

- Request body: **base64 of the raw bytes** to write (not JSON) — e.g. `Aw==` for Ctrl-C (`0x03`), `G1tB` for `ESC[A` (up arrow). Invalid base64 → `400 {"error":"invalid_body"}`.
- No live attach for the session → `409 {"error":"no_attach"}`. (`409`, not `404`: the *route* exists and the tmux session may well be alive; what is missing is a live PTY attach to write into — the client should (re)open `/term/stream` and retry. `404` is reserved for "terminal disabled".) A write that races the attach dying returns the same `409`.
- Success → `200 {"ok":true}`.
- **The body is never logged** (only method+path reach the log).

### POST /term/resize

Resizes the PTY window (`ioctl TIOCSWINSZ`).

- Request body: JSON `{"rows":<int>,"cols":<int>}`, both in `1..9999`. Anything else → `400 {"error":"invalid_body"}`.
- No live attach → `409 {"error":"no_attach"}` (same rationale as input).
- Success → `200 {"ok":true}`.

## Mac-app integration facts (why writing the file is enough)

From `Geo/Features/Tasks/Data/TasksStore.swift` (READ-ONLY reference):

- The store watches `GEO_TASKS_DIR` via `FileWatcherService`; external `.json` changes are decoded (`JSONDecoder`, `.iso8601` dates) and replace/insert the in-memory task, then re-mirror to EventKit. Deletion of a file removes the task.
- The app's own writes use `.atomic` and are self-suppressed via a 0.8 s `externalWriteGracePeriod` keyed on its own write timestamps — bridge writes are always outside that map, so they are always picked up.
- Decoder tolerances: unknown `status`/`priority` fall back to `pending`/`unset`; missing `modifiedAt` falls back to `createdAt`; so a bridge write that keeps the documented shapes can never brick the store (worst case a bad file logs and is skipped).

From `Geo/Features/Nano/Data/HermesKanbanService.swift`: the Mac app polls `~/.hermes/dispatches` every 2 s, requires `meta.json`, defaults status to `running`, sorts running-first then `started_at` desc, caps at 80. The bridge mirrors the same directory semantics; it does not cap.

## Turning on hermes api_server (documented, NOT applied)

`~/.hermes/config.yaml` currently has (lines 565–568):

```yaml
platforms:
  api_server:
    enabled: false
    bind: 127.0.0.1
    port: 8642
```

Required change — enable it, keep loopback bind, and set the key. Per `api_server.py` (`extra = config.extra or {}`; `self._api_key = extra.get("key", os.getenv("API_SERVER_KEY", ""))`; `self._host = extra.get("host", os.getenv("API_SERVER_HOST", "127.0.0.1"))`), the adapter reads **only** the nested `extra` dict (or `API_SERVER_*` env vars). The existing top-level `bind:`/`port:` keys are inert — `PlatformConfig.from_dict` copies only `data["extra"]` into `extra` — and the compiled-in defaults are already `127.0.0.1:8642`, which is exactly what we want (loopback only; the bridge is the tailnet face):

```yaml
platforms:
  api_server:
    enabled: true
    bind: 127.0.0.1
    port: 8642
    extra:
      key: "<same value as the contents of HERMES_KEY_FILE>"
```

The exact config field is `platforms.api_server.extra.key`; the env-var equivalent is `API_SERVER_KEY` in `~/.hermes/.env` (which additionally force-enables the platform: `if api_server_enabled or api_server_key:` in `gateway/config.py`). `API_SERVER_KEY` is not currently set in `~/.hermes/.env`. The server refuses to start without a key. After editing, restart the gateway (`launchctl kickstart -k gui/$UID/ai.hermes.gateway`).

## Error shape

All bridge-originated errors: `{"error":"<snake_case_code>"}` with the appropriate status (`400` invalid_id/invalid_body, `401` unauthorized, `404` not_found, `409` task_exists/no_attach, `502` hermes_unreachable, `500` internal). Proxied hermes errors pass through untouched.
