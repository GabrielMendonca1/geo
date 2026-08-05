# GeoBridge — API contract

HTTP daemon on the Mac exposing three local resources to the tailnet for the iPhone app. The bridge is a **dumb pipe over files**: it never re-models data. Reads return file contents **verbatim** (zero re-encode); mutations are minimal field edits; streams are line pass-through. The Mac app (Geo.app) and hermes remain the owners of all state — the bridge only relays it.

Spec version: 4 (v3 + `/vitals/*` health). All facts below were extracted from the live system on 2026-07-01 (real task files, real dispatch dirs, `TaskItem.swift`, `TasksStore.swift`, `HermesKanbanService.swift`, `api_server.py`, `~/.hermes/config.yaml`).

## Principles

1. **Verbatim reads.** `GET /tasks` concatenates the raw bytes of the task files into a JSON array. The bridge never parses-then-re-serializes for reads: field order, number formatting, and unknown keys reach the phone exactly as written by Geo.app.
2. **Minimal mutations.** Complete/reopen change exactly two fields (`status`, `modifiedAt`) and preserve every other key untouched, then write atomically (temp file + rename in the same directory). Geo.app's `FileWatcherService` on the Tasks dir picks the change up and updates its in-memory store and EventKit mirror — the bridge only has to write the file correctly (see "Mac-app integration facts").
3. **Line pass-through streams.** Dispatch logs and hermes chat SSE are relayed line-for-line / byte-for-byte, never interpreted.
4. **No speculative surface.** Task create exists as of v2 because the phone needs it — and even there the bridge stays a dumb pipe (the phone sends the complete task JSON; the bridge validates and writes, never composes). Task delete exists for the same reason (the phone needs it); still no task update, no dispatch spawn, no session management endpoints. Add them only when the phone needs them.

   **Carve-out — the terminal (`/term/*`, v3).** The terminal is the deliberate exception to principle 4: it is *not* a dumb pipe over files, it is an arbitrary interactive shell as the local user, streamed over the tailnet. This is the single largest blast radius in the whole surface — anyone holding the term token can run any command `biel` can (read/exfiltrate the vault, `rm -rf`, `git push`, spend money, pivot). It is justified because the phone genuinely needs a real terminal (agents live in shells), and it is fenced with five independent controls: (1) a **separate** token (`GEO_BRIDGE_TERM_TOKEN_FILE`) so it can be revoked without touching the rest of the bridge; (2) `GEO_TERM_ENABLED=0` by default → `/term/*` is `404` until explicitly turned on in the plist; (3) tailnet-only bind (unchanged); (4) keystrokes are **never** logged (input rides only in the POST body; the log records method+path only — so `open`/`close`/`resize` show up, never typed bytes); (5) the PTY attach is reaped after 10 min with no connected client. Do not extend this surface (session spawn/list, file upload, etc.) without re-justifying the blast radius.

## Configuration (env vars)

| Var | Default | Meaning |
|---|---|---|
| `GEO_TASKS_DIR` | `~/Vault/Tasks` | One `<id>.json` per task |
| `GEO_DISPATCHES_DIR` | `~/.hermes/dispatches` | One dir per cc-dispatch worker |
| `GEO_HEALTH_DIR` | `~/Vault/Health` | `protocol.json`, `state.json`, one `log-YYYY-MM-DD.json` per session |
| `GEO_BRIDGE_BIND` | `100.123.44.9` | Tailnet address to bind (never `0.0.0.0`) |
| `GEO_BRIDGE_PORT` | `8643` | |
| `GEO_BRIDGE_TOKEN_FILE` | `~/.hermes/geobridge.token` | Bearer token for bridge auth (single line, trimmed) |
| `HERMES_URL` | `http://127.0.0.1:8642` | hermes api_server (loopback; bridge is its only tailnet exposure) |
| `HERMES_KEY_FILE` | `~/.hermes/api_server.key` | File whose trimmed content equals hermes `API_SERVER_KEY` |
| `GEO_TERM_ENABLED` | `0` | `1` enables `/term/*`; anything else → `/term/*` is `404` |
| `GEO_TERM_TMUX` | `/opt/homebrew/bin/tmux` | Absolute path to `tmux` (launchd `PATH` is minimal) |
| `GEO_TERM_SHELL` | *(unset)* | If set, exported as `SHELL` to the tmux child (else tmux's default) |
| `GEO_TERM_PROFILE_MAC` | *(unset)* | If set, the path (tilde-expanded) run as the command of the session literally named `mac` — a dedicated "my Mac" profile script instead of a bare shell. Ignored for every other session name |
| `GEO_TERM_SESSION` | `mobile` | Default tmux session name (used when `?session=` is absent; also when malformed, but only on the read verbs — see "Session selection") |
| `GEO_TERM_REPLAY_BYTES` | `262144` | Per-session ring buffer of recent PTY output replayed to each new `/term/stream` |
| `GEO_BRIDGE_TERM_TOKEN_FILE` | `~/.hermes/geobridge.term.token` | Second, dedicated bearer token for `/term/*` (single line, trimmed) |
| `GEO_STATUS_UNITS` | `garime-wa syncthing-garime` | Space-separated allowlist of systemd units reported by `/term/agents` |
| `GEO_STATUS_MAC_HOST` | `100.123.44.9` | Host TCP-probed on port 22 (1 s) for `mac_online` in `/term/agents`; also the ssh target of the herdr agent scan |
| `GEO_STATUS_MAC_USER` | `biel` | ssh user on the Mac for the herdr agent scan (`<user>@<GEO_STATUS_MAC_HOST>`) |
| `GEO_STATUS_HERDR` | `/opt/homebrew/bin/herdr` | Absolute path to `herdr` **on the Mac** (its dirname is also prepended to the remote `PATH`) |
| `GEO_STATUS_SSH` | `ssh` | ssh binary used for the Mac scan (resolved via `PATH`) |
| `GEO_STATUS_AGENTS_TTL` | `10` | Seconds the `agents` list of `/term/agents` is cached (the phone polls every 10 s) |
| `GEO_STATUS_AGENTS_TIMEOUT` | `12` | Hard timeout (s) of the single ssh call that scans the Mac |
| `GEO_TERM_ATTACH_SSH_TIMEOUT` | `4` | `ConnectTimeout` (s) of the ssh started **inside tmux** by `/term/attach-agent` and `/term/attach-herdr`, and of the ssh run **in the handler** by `/term/agent-chat` and `/term/agent-prompt` |
| `GEO_AGENT_CHAT_LIMIT` | `40` | Default number of messages returned by `/term/agent-chat` |
| `GEO_AGENT_CHAT_MAX_LIMIT` | `200` | Hard ceiling of `?limit=` on `/term/agent-chat` |
| `GEO_AGENT_CHAT_TEXT_MAX` | `2000` | Per-message character cap on `/term/agent-chat`; longer text is cut and flagged `truncated` |
| `GEO_AGENT_CHAT_TAIL_BYTES` | `131072` | Bytes of the **tail** of the transcript file read on the Mac (`tail -c`) per `/term/agent-chat` call |
| `GEO_AGENT_CHAT_TIMEOUT` | `12` | Hard timeout (s) of the transcript ssh of `/term/agent-chat` |
| `GEO_AGENT_PROMPT_TIMEOUT` | `15` | Hard timeout (s) of the `herdr agent prompt` ssh of `/term/agent-prompt` |

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

1. Validate: body parses to a JSON object with `id` matching the id regex, `title` a non-empty string, `body.kind` ∈ `task | event | habit | milestone`, and `createdAt` a string. Anything else → `400 {"error":"invalid_body"}`. For `body.kind = "task"`, `body.due` is required as a non-empty ISO 8601 datetime string; missing, empty, or invalid → `400 {"error":"task_due_required"}`. The bridge does not validate deeper beyond this rule (dumb pipe); the Mac decoder's documented tolerances absorb shape drift.
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

### DELETE /tasks/{id}

Removes `GEO_TASKS_DIR/<id>.json`.

1. Validate `{id}` regex; anything else → `400 {"error":"invalid_id"}`.
2. `os.unlink(GEO_TASKS_DIR/<id>.json)`. File missing → `404 {"error":"not_found"}`; other OS error → `500 {"error":"internal"}`.
3. `200 {"ok":true}`.

Geo.app's `FileWatcherService` sees the file disappear and removes the task from its in-memory store and EventKit mirror (see "Mac-app integration facts"). Not idempotent: a second delete of the same id returns `404`.

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

## Vitals — `/vitals/*` (added in v4)

The health module of the phone, over `GEO_HEALTH_DIR` (default `~/Vault/Health`). Dumb pipe as in principle 1: reads are verbatim bytes, writes are validate-then-atomic-write of the exact JSON the phone sent. The bridge never computes anything — in particular it does **not** derive today's session; the phone does that from `state.json` (`(anchorIndex + days_since(anchorDate)) mod 6`). Main bridge token, same as `/tasks`.

### GET /vitals/protocol

Verbatim bytes of `GEO_HEALTH_DIR/protocol.json`. Missing/unreadable → `404 {"error":"not_found"}`.

The protocol is authored in the vault (mirror of the Markdown note it names in `source`) and is read-only for the phone:

```json
{"id":"shape-v-fase-2","name":"Shape em V — Fase 2 (Ricardo)","source":"Protocolo shape em V — fase 2 — 2026-07-08 a 2026-08-08.md",
 "sessions":[{"index":0,"name":"Superiores A — Costas & Ombros","short":"Costas & Ombros","rest":false,
              "muscles":["upper-back","trapezius","deltoids"],
              "exercises":[{"id":"puxada-alta","name":"Puxada alta (gravitron ou barra fixa, pegada aberta)",
                            "sets":[[12,15],[10,12],[10,12],[6,8]],"muscles":["upper-back"]}]}]}
```

- `sessions` has exactly 6 entries, `index` 0–5, in cycle order; `rest: true` entries carry empty `muscles`/`exercises`.
- `sets` is one `[min,max]` rep range per série (4 pairs for 4-série exercises, 3 for 3-série ones).
- `muscles` slugs come from the body asset vocabulary: `chest biceps abs obliques quadriceps deltoids forearm trapezius tibialis calves neck upper-back lower-back triceps hamstring gluteal adductors`.

### GET /vitals/state

Verbatim bytes of `GEO_HEALTH_DIR/state.json`. Missing → `404 {"error":"not_found"}` — that is the onboarding signal (the file is created by the first `POST /vitals/state`, never by the bridge on its own).

### POST /vitals/state

```json
{"protocolId":"shape-v-fase-2","anchorDate":"2026-08-04","anchorIndex":3}
```

1. Validate: object with `protocolId` matching the id regex, `anchorDate` matching `^\d{4}-\d{2}-\d{2}$`, `anchorIndex` an int in `0..5`. Anything else → `400 {"error":"invalid_body"}`.
2. Write atomically (temp file in `GEO_HEALTH_DIR`, `fsync`, `rename(2)`) over `state.json`; the dir is created on demand.
3. `200` with the exact bytes written. Overwrite is the normal case (re-anchoring).

### GET /vitals/logs

Same splice as `GET /tasks`: `[ <bytes of log-A.json>, <bytes of log-B.json>, … ]` over every `log-*.json` in `GEO_HEALTH_DIR`, filename ascending (= chronological), `.sync-conflict-*` and unreadable/invalid-JSON files skipped, empty → `[]`.

### POST /vitals/log

```json
{"id":"6D2A7F10-4C3B-4E5A-9F81-0B7C2D3E4F50","date":"2026-08-04","sessionIndex":3,
 "exercises":[{"id":"supino","sets":[{"reps":12,"kg":40.0}]}],"note":""}
```

1. Validate: object with `id` matching the id regex, `date` matching `^\d{4}-\d{2}-\d{2}$`, `sessionIndex` an int in `0..5`, `exercises` a list whose entries are objects with an id-regex `id` and a list `sets`. Deeper shape (`reps`/`kg`, `note`) is not validated — dumb pipe. Anything else → `400 {"error":"invalid_body"}`.
2. Write atomically over `log-<date>.json`. **Overwrite allowed** (unlike `POST /tasks`): the day's log is edited during the session, so there is no `409`.
3. `200` with the exact bytes written.

## Terminal — `/term/*` (added in v3)

A real interactive terminal for the phone. **Not** a dumb pipe over files (see the principle-4 carve-out above for the blast-radius warning). Ten endpoints (`stream`, `input`, `resize`, `winsize`, `list`, `preview`, `agents`, `kill`, `rename`, `upload`), all gated and separately authed. `preview` and `agents` are strictly read-only and never spawn a session.

**Session selection.** Every `/term/*` endpoint takes `?session=<name>`, matched against `\A[A-Za-z0-9_-]{1,32}\Z` (anchored so a trailing newline is rejected, not accepted as `$` would). A **missing** value falls back to `GEO_TERM_SESSION` (default `mobile`) on every endpoint. A **present but malformed** value falls back to that default only on the read verbs (`stream`, `input`, `resize`, `winsize`, `list`, `preview`); on the mutating verbs (`kill`, `rename`) it is `400 {"error":"bad_name"}` — silently redirecting a kill or a rename onto the default session would mutate a session the caller never asked for. The name `mac` is special: if `GEO_TERM_PROFILE_MAC` is set, that script is run as the session's command.

**Targets are exact.** tmux resolves `-t <name>` by exact → fnmatch → **prefix** → substring, so `-t ma` would hit the session `mac`. Every session target the bridge passes to tmux is prefixed with `=` (`=<name>` for session targets, `=<name>:` for pane targets like `capture-pane`/`display-message`), which forces exact matching. Consequence: a name that only *prefixes* a live session resolves to nothing — `rename`/`preview` answer `404 no_session`, `winsize` answers `409 no_session`, `kill` is a no-op, and `has-session` no longer reports a false `409 exists`. Spawning (`new-session -A -s <name>`) is exact by construction and is not prefixed.

**Two layers of persistence.**

1. **tmux** owns the shell. `GEO_TERM_TMUX` (default `/opt/homebrew/bin/tmux`, absolute — launchd `PATH` is minimal) runs `tmux -u new-session -A -s <session>` (`-A` = attach if it exists, else create), so the shell survives bridge restarts and machine-level reconnects. `GEO_TERM_SHELL`, if set, is exported as `SHELL` to the child; `TERM` defaults to `xterm-256color`.

   The exact spawn, in one command line (options apply to a session the bridge creates; on `-A` re-attach tmux keeps the existing session's settings):

   ```
   tmux -u new-session -A -s <session> [<GEO_TERM_PROFILE_MAC> if session == "mac"] \
     \; set-option mouse on \
     \; set-option -g history-limit 100000 \
     \; bind-key -n PageUp copy-mode -u \
     [\; refresh-client -f ignore-size]
   ```

   - `mouse on` — the phone's touch scroll/selection.
   - `history-limit 100000` — deep scrollback (independent of the bridge's ring buffer, which only covers replay).
   - `PageUp → copy-mode -u` — one-key entry into scrollback from the phone keyboard.
   - `refresh-client -f ignore-size` is appended **only when** `tmux list-clients -t <session>` already shows a client without the `ignore-size` flag — i.e. a real terminal on the Mac is sharing this session. The phone then declares itself size-irrelevant so it cannot shrink the Mac's window. Alone on a session, the phone drives the size normally. Same rule for every session name, including `mac`.
2. **The bridge's attach is itself durable** and decoupled from any HTTP request. The `pty.fork()`ed attach lives in a registry keyed by session name, with one reader thread as the single reader of the PTY master. That thread appends output to a per-session ring buffer (last `GEO_TERM_REPLAY_BYTES`, default 256 KiB) and fans it out to every connected subscriber. HTTP requests come and go; the attach does not.

Consequences the client can rely on:

- **Replay on attach.** A new `/term/stream` first receives the ring buffer as a single `event: replay` message, so a phone that locked, backgrounded, or lost the tailnet reconnects with its scrollback intact instead of a blank screen. The buffer is trimmed by **bytes**, so its first bytes can land mid-ANSI-escape or mid-UTF-8-codepoint; the client's terminal emulator must tolerate a truncated leading sequence (a discarded partial escape / replacement char at the top of the replay is expected, not a bug).
- **Broadcast, not takeover.** Multiple `/term/stream` clients on the same session are all fed the same bytes (iPhone + iPad + a curl debug session simultaneously). Opening a new stream never kills an existing one — the v3 "last-writer-wins / SIGKILL the old attach" behavior is **gone**.
- **Spawn on demand.** `/term/input` and `/term/resize` create the attach if none exists; they no longer require a live `/term/stream` first.
- **Attach reap.** The attach is torn down only after `TERM_IDLE_SECONDS` (10 min) with **zero** subscribers. While at least one stream is connected it is never reaped, no matter how long it sits without input. The tmux session always survives the reap; the next request re-attaches (and replays tmux's own scrollback via `-A`).

**Gating and auth (differs from the rest of the bridge).** `/term/*` do **not** use the main bridge token. They require:
1. `GEO_TERM_ENABLED == "1"` **and** a non-empty `GEO_BRIDGE_TERM_TOKEN_FILE`. If either is false, `/term/*` → `404 {"error":"not_found"}` (indistinguishable from "route doesn't exist"). A missing/empty term-token file keeps `/term/*` at `404` **even when `GEO_TERM_ENABLED=1`**.
2. `Authorization: Bearer <contents of GEO_BRIDGE_TERM_TOKEN_FILE>` (constant-time compare). Enabled + token present but wrong/absent header → `401 {"error":"unauthorized"}`.

The term token is generated by `install.sh` alongside the main token (`openssl rand -hex 32`, `chmod 600`). Its absence does **not** block bridge startup (only the main token does); it simply leaves `/term/*` dark.

**Framing.** All PTY bytes are **base64** in both directions — raw terminal I/O is binary (ANSI/control bytes, UTF-8 fragments) and does not survive SSE's line protocol or JSON otherwise.

### GET /term/stream — SSE

Subscribes to the session's durable attach (creating it if needed) and streams its output.

- Content-Type: `text/event-stream`.
- **Replay first:** if the ring buffer is non-empty, the first message is the whole buffer as one `event: replay\ndata: <base64>\n\n`. Empty buffer (freshly spawned attach) → no replay message. The replay carries the PTY's raw history, **including terminal queries** the programs on the other side emitted (DA1 `ESC[c`, DA2 `ESC[>c`, DSR `ESC[5n`/`ESC[6n`, XTVERSION, OSC 10/11 `?`…). A client that feeds the replay to an emulator must **suppress the emulator's automatic responses** while doing so — otherwise every reconnect types the stale answers (`65;20;1c…`) into the shell. Live chunks are answered normally. A legacy client that ignores the event name still gets the bytes (`data:` is unchanged), so replay stays backward compatible — it just re-answers the queries.
- Then each chunk of PTY output as it arrives: `data: <base64 of raw bytes>\n\n`. Identical bytes go to every subscriber of that session.
- Keepalive: `: keepalive\n\n` every 15 s of no output (covers the client's 90 s stream timeout).
- Terminal: `event: done\ndata: {"status":"closed"}\n\n`, then close — sent when the attach itself dies: PTY `EIO`/child exit, `POST /term/kill`, or the idle reap. It is **not** sent when another client connects (no takeover) and it is **not** sent while any client is connected (no idle reap). The tmux session survives all of these; reconnect to re-attach.
- **Overflow → `event: done\ndata: {"status":"dropped"}\n\n`.** Each subscriber has a 256-chunk queue. A client that stops reading (backgrounded, throttled link) fills it; the bridge then drops it from the fan-out so one slow phone cannot stall output for the other clients, and the stream is closed with `dropped` within ~1 s instead of silently freezing. `dropped` is the client's signal to **reconnect immediately** — the ring buffer replay closes the gap, so the reconnected terminal is correct, not merely resumed. `closed` means the shell/attach went away; `dropped` means only this connection did.
- Disconnecting a stream never kills the attach. When the last subscriber leaves, the 10-min reap clock starts.

### POST /term/input

Writes raw keystrokes to the session's PTY master, spawning the attach on demand if there is none.

- Request body: **base64 of the raw bytes** to write (not JSON) — e.g. `Aw==` for Ctrl-C (`0x03`), `G1tB` for `ESC[A` (up arrow). Invalid base64 → `400 {"error":"invalid_body"}`.
- No `/term/stream` needed first: the bridge attaches (`tmux new-session -A`) and writes. Output produced by that input lands in the ring buffer and is visible to whoever streams next.
- `409 {"error":"no_attach"}` only when the write itself fails (`OSError` — the attach died between lookup and write); the client should retry. `404` remains reserved for "terminal disabled".
- Success → `200 {"ok":true}`.
- **The body is never logged** (only method+path reach the log).

### POST /term/resize

Resizes the PTY window (`ioctl TIOCSWINSZ`), spawning the attach on demand like `/term/input`.

- Request body: JSON `{"rows":<int>,"cols":<int>}`, both in `1..9999`. Anything else → `400 {"error":"invalid_body"}`.
- `409 {"error":"no_attach"}` only if the `ioctl` fails.
- Success → `200 {"ok":true}`.
- Note: with multiple simultaneous streams, the PTY has one size — the last resize wins for everyone.

### GET /term/winsize

Reports the tmux window geometry for the session (`display-message -p`).

- `200 {"cols":<int>,"rows":<int>,"shared":<bool>}`. `shared` is true when a tmux client without the `ignore-size` flag is attached **and that client is not one of the bridge's own durable attaches** (their ttys are known from the registry and excluded). So `shared` means "a real terminal outside the bridge is sharing the session, the phone must not force its own size" — the bridge's own attach, which is always there while a session is live, never triggers it.
- No such tmux session → `409 {"error":"no_session"}`.

### GET /term/list

- `200 {"sessions":["mobile","mac",…]}` — `tmux list-sessions`, tmux server down or erroring → `{"sessions":[]}`.

### GET /term/preview

Read-only snapshot of a session's tail, for the sessions home on the phone. **Never spawns anything**: it is `tmux capture-pane` only — no `new-session -A`, no attach, no registry entry. A preview of a session that does not exist leaves the tmux server exactly as it was.

- `?session=<name>` follows the usual rule (malformed → falls back to `GEO_TERM_SESSION`). `?lines=<n>` is clamped to `1..40`, default `12`, unparseable → default.
- `tmux capture-pane -p -e -t <session> -S -<n>` (subprocess timeout 5 s). `-e` **keeps the ANSI escapes**, so a client that wants plain text must strip them (the iOS home does, v1 is colorless).
- `200 {"text":"<lines>"}`. The text is the whole visible pane plus `n` lines of scrollback, so it can be longer than `n` lines and usually ends in blank lines — trimming is the client's job.
- No such session (non-zero exit) or tmux missing/timeout → `404 {"error":"no_session"}`.

### GET /term/agents

Read-only service/host status for the "agentes" section of the sessions home. Touches nothing: `systemctl show`, one TCP probe, one read-only ssh scan of the Mac's herdr sessions and a `ps` scan of the VM.

- `200 {"units":[{"name":"garime-wa","active":true,"since":"Tue 2026-08-04 10:36:49 -03"},…],"mac_online":true}`.
- The unit list is fixed by `GEO_STATUS_UNITS` (space-separated, default `garime-wa syncthing-garime`) — the client cannot ask about an arbitrary unit.
- Per unit: `systemctl show <u> -p ActiveState -p ActiveEnterTimestamp` (timeout 5 s). `active` is `ActiveState == "active"`; `since` is the raw `ActiveEnterTimestamp` string (systemd format, empty when never active). Any failure (no systemd, timeout, unknown unit) → `{"active":false,"since":""}`, never a 5xx.
- `mac_online`: TCP connect to `100.123.44.9:22` (`GEO_STATUS_MAC_HOST`) with a 1 s timeout — always a boolean, failures are `false`.
- `agents`: the **AI agent sessions actually running**, Mac + VM. Added after `units`/`mac_online`, which keep their exact shape — an older client that ignores the key keeps working, and a client that expects it must tolerate its absence (older bridge).

```json
{"units":[…],"mac_online":true,
 "agents":[{"host":"mac","agent":"claude","status":"idle",
            "title":"tech stack audit macbook vault","project":"garime","pane":"w1:p3",
            "cwd":"/Users/biel/Garime"}]}
```

- Per entry: `host` is `mac`|`vm`; `agent` is the agent binary (`claude`, `pi`, `codex`, `kimi`, `opencode`); `status` is `idle`|`working`|`unknown` on the Mac and always `running` on the VM; `title` is the herdr `terminal_title_stripped` (fallback `terminal_title`, else `""`); `project` is the herdr session the pane belongs to (empty on the VM); `cwd` when herdr reports one.
- `pane` is the herdr `pane_id` of the entry (`w<n>:p<n>`), `""` when herdr does not report one and always `""` on the VM. Together with `project` it is the exact pair `/term/attach-agent` takes — the client never builds it, it echoes what this endpoint gave it.
- **Mac side**: one `ssh -o BatchMode=yes -o ConnectTimeout=4 <GEO_STATUS_MAC_USER>@<GEO_STATUS_MAC_HOST>` (argv list, never `shell=True`, hard timeout `GEO_STATUS_AGENTS_TIMEOUT`). The remote script lists the `running` herdr sessions and, per session, prints a `##session <name>` marker followed by the single-line JSON of `herdr --session <name> agent list`; the marker is what makes `project` exact instead of guessed. Each stdout line is parsed independently — unparseable lines are skipped, panes without an `agent` key (`agent_status:"unknown"`, no agent attached) are discarded.
- **The Mac side fails silently**: ssh down, host unreachable, timeout, no herdr, garbage output → it contributes an empty list. `/term/agents` never 5xxs because of it, and `units`/`mac_online` are unaffected.
- **VM side**: a `ps -eo comm=` scan for local `pi`/`claude`/`codex`/`kimi`/`opencode` processes, `status:"running"`, `project`/`title`/`cwd` empty (that data is not available cheaply and is not invented). The WhatsApp bot runs as `node` and is *not* listed here — it is already the `garime-wa` unit.
- **Cost and cache**: the ssh round trip is ~1.3 s, the phone polls every 10 s. The whole `agents` list is memoized for `GEO_STATUS_AGENTS_TTL` seconds. Refreshes are serialized by a second lock, so two concurrent requests produce **one** ssh (the loser waits and reads the fresh cache); the cache lock is never held during the ssh, so a slow refresh cannot deadlock other routes. A failed refresh caches the degraded result for the TTL — the last good value survives only as long as it is fresh, and there is no stale replay beyond it.

### POST /term/kill

Kills the tmux session **and** the bridge's attach.

- `?session=` absent → the `GEO_TERM_SESSION` default; present but malformed → `400 {"error":"bad_name"}`, nothing is killed.
- `tmux kill-session -t =<session>`, then teardown of the durable attach: every connected `/term/stream` receives `event: done` and closes.
- `200 {"ok":true}` regardless (idempotent — killing an absent session still returns ok).

### POST /term/rename

Renames a tmux session in place (`tmux rename-session`). The shell, its scrollback and the bridge's durable attach all survive — the attach is bound to the tmux session, not to its name, so it is only re-keyed in the registry under the new name (no teardown, no `event: done`).

- `?session=` absent → the `GEO_TERM_SESSION` default; present but malformed → `400 {"error":"bad_name"}`, nothing is renamed. `?to=<name>` is the new name and is **strict**: it must match `\A[A-Za-z0-9_-]{1,32}\Z`, otherwise `400 {"error":"bad_name"}` — there is no fallback for the destination.
- `mac` is reserved (it is the session that runs `GEO_TERM_PROFILE_MAC`): renaming **from** `mac` or **to** `mac` → `409 {"error":"reserved"}`. The reserved check is a plain string comparison and is sound only because targets are exact: `?session=ma` cannot reach the `mac` session, it resolves to nothing → `404 {"error":"no_session"}`.
- `to == session` → `200 {"ok":true}` (idempotent no-op, no tmux call).
- A session already named `to` (`tmux has-session -t =<to>` exits 0) → `409 {"error":"exists"}`. Never merges or overwrites.
- Source session absent (non-zero exit) or tmux missing/timeout → `404 {"error":"no_session"}`.
- Success → `200 {"session":"<to>"}`.

### POST /term/attach-agent · POST /term/attach-herdr

Open a **Mac-side herdr view** inside a bridge tmux session, so the phone terminal can watch a single agent's pane (`attach-agent`) or the whole herdr TUI with its agent sidebar (`attach-herdr`). Both only *create* the session and answer; the client then opens `GET /term/stream?session=<returned name>` as usual.

- Auth: the terminal token (`_term_gate`), same as every other `/term/*` route. Terminal disabled → `404`.
- Params — each validated by its own anchored regex (`\A…\Z`, never `$`, which matches before a trailing `\n`):
  - `project` (both routes): `\A[A-Za-z0-9_-]{1,24}\Z` — a herdr session name, as reported by `/term/agents` `project`.
  - `pane` (`attach-agent` only): `\Aw[0-9]{1,3}:p[0-9]{1,3}\Z` — the `/term/agents` `pane`. `attach-herdr` ignores any `pane` given.
  - Anything else (missing, empty, wrong shape, trailing newline, shell metacharacters, over-length) → `400 {"error":"bad_target"}` and **nothing is spawned**.
- **Derived session name** — deterministic, never chosen by the client: `ag-<project>-<pane without the colon>` (e.g. `ag-garime-w1p3`) and `hd-<project>` (e.g. `hd-garime`). If the name would exceed the 32-char `TERM_SESSION_RE` budget, the project is truncated and a 4-hex-char sha1 of the full project is appended, so two long projects never collapse onto one session. The `ag-`/`hd-` prefixes are a namespace: a derived name can never equal the reserved `mac`, and a user session only collides if the user deliberately names one `ag-…`/`hd-…`.
- **Reuse**: the spawn is the ordinary `tmux new-session -A -s <derived>` path, so a second call with the same `project`/`pane` returns the same name and attaches to the session already running — no second ssh, no second tmux session.
- **The remote command** runs inside tmux, never in the HTTP handler (the handler returns as soon as the session exists):
  ```
  <GEO_STATUS_SSH> -tt -o BatchMode=yes -o ConnectTimeout=<GEO_TERM_ATTACH_SSH_TIMEOUT> \
    <GEO_STATUS_MAC_USER>@<GEO_STATUS_MAC_HOST> \
    'export PATH=<dirname GEO_STATUS_HERDR>:$PATH; <GEO_STATUS_HERDR> --session <project> [agent attach <pane>]'
  ```
  argv list, never `shell=True`; every interpolated part is `shlex.quote`d on top of the strict regexes. `-tt` is mandatory — herdr panics (`failed to initialize terminal`) without a TTY and renders empty on a zero-sized one, which is why this only works from inside a real tmux session. No `--takeover`: herdr accepts several simultaneous clients, so attaching from the VM does **not** kick the Mac's own herdr window.
- Success → `200 {"session":"<derived name>"}`. The bridge does not wait for ssh: an unreachable Mac, a dead herdr or a wrong project surfaces as the error text *inside the terminal stream*, not as an HTTP code.
- **Ephemeral by nature.** These sessions are ordinary bridge sessions: they show up in `/term/list`, `/term/preview` and `/term/winsize`, and `POST /term/kill?session=<derived>` kills them like any other. When the remote ssh/herdr exits, tmux tears the session down on its own. The 600 s idle reaper (no `/term/stream` client) tears the bridge's attach down as usual; re-issuing `attach-agent`/`attach-herdr` is always the way back in and is idempotent.

### GET /term/agent-chat

The **agent GUI** read side: the recent conversation of one Mac agent as structured data, so the phone can talk to an agent by request/response instead of holding a PTY open. This is the answer to the terminal being unusable on 4G (`/term/stream` reopened 19× in one hour on the street) — nothing here streams, nothing here is stateful, every call is a self-contained poll.

- Auth: the terminal token (`_term_gate`), same as every other `/term/*` route. Main bridge token → `401`. Terminal disabled → `404`.
- Params — the exact `project`/`pane` pair `/term/agents` reported, validated by the same anchored regexes as `/term/attach-agent` (`\A[A-Za-z0-9_-]{1,24}\Z` and `\Aw[0-9]{1,3}:p[0-9]{1,3}\Z`, never `$`). Both are **required**; anything else → `400 {"error":"bad_target"}` and no ssh happens.
- `?limit=<n>`: number of **messages** (not records) returned, counted from the end. Default `40`, clamped to `1..200`, unparseable → default.

```json
{"agent":"claude","status":"working","messages":[
  {"role":"user","text":"roda os testes","ts":"2026-08-05T02:10:01"},
  {"role":"assistant","text":"51 verdes, gate fechou","ts":"2026-08-05T02:10:05"},
  {"role":"tool","tool":"Bash","ts":"2026-08-05T02:10:05"}
]}
```

- **Resolution** costs zero extra ssh: the pane is looked up in the same memoized `agent list` scan that backs `/term/agents` (`GEO_STATUS_AGENTS_TTL`), matching `host=="mac"` **and** exact `project` **and** exact `pane`. That scan now also keeps each entry's herdr `agent_session` (`{"agent","kind","value"}`); it is used only here and is **stripped from the `/term/agents` payload**, whose per-agent shape is unchanged (`host agent status title project pane cwd`).
- **Transcript location** — from `agent_session`:
  - `kind:"id"` (claude): the id (`\A[A-Za-z0-9._-]{1,80}\Z`) is resolved by **glob**, `$HOME/.claude/projects/*/<id>.jsonl`. The project dir is *not* derivable from the agent's `cwd` (a live example has `cwd=/Users/biel/Garime` and the file under `-Users-biel/`), so it is never guessed.
  - `kind:"path"` (pi): the absolute `.jsonl` path herdr already hands over, used as-is.
  - Any other/absent `agent_session` → `200` with `messages: []`.
- **Only the tail is read.** The remote command is `tail -c <GEO_AGENT_CHAT_TAIL_BYTES> <file>` (128 KiB), so a 1.4 MB / 5000-record transcript costs one bounded read on the Mac, one bounded transfer, and one bounded parse on the VM — the file never grows the response or the bridge's memory. The first line of the tail is usually a partial record; it simply fails to parse and is dropped like any other garbage line.
- **Conversion** (JSONL → messages, in file order): records of `type` `attachment`, `custom-title`, `mode`, `last-prompt`, `summary`, `system` are dropped, as is anything without a `user`/`assistant` role. Within a message's `content` blocks, `text` blocks are concatenated (`\n`) into one message; each `tool_use` block becomes its own `{"role":"tool","tool":"<name>"}` entry **carrying no payload** (no input, no id, no output) at its position in the block order; `tool_result` blocks are discarded, so a user turn that is only tool results yields nothing. Whitespace-only messages are dropped. Unparseable lines are skipped, never invented.
- **Truncation**: message text over `GEO_AGENT_CHAT_TEXT_MAX` (2000) chars is cut to the cap and the message gets `"truncated":true`. The key is absent otherwise.
- **pi is read defensively**: its schema is not assumed to be claude's — `message` may be the record itself, `content` may be a plain string, `timestamp` may sit either level. A record matching no known shape is discarded rather than guessed.
- Codes:
  - `200` — the conversation (possibly `[]`: a fresh session that has not written a transcript yet is **not** an error).
  - `400 {"error":"bad_target"}` — malformed `project`/`pane`.
  - `404 {"error":"no_agent"}` — that pane has no agent in the current scan.
  - `503 {"error":"unavailable"}` — **we could not find out**: the Mac scan failed (ssh down/timeout/no herdr) or the transcript ssh failed or timed out. This code is semantically distinct from `200 []` on purpose: the client must render "sem conexão", never "conversa vazia". `/term/agents` keeps its old silent-fail behaviour (empty Mac list, never 5xx); the distinction lives only here.

### POST /term/agent-prompt

The agent GUI write side: send one prompt to one Mac agent. Fire-and-forget — it never blocks on the agent's answer; the client watches `agent_status` via `/term/agents` and re-polls `/term/agent-chat`.

- Auth and `project`/`pane` validation: identical to `/term/agent-chat` (`400 {"error":"bad_target"}`, nothing sent).
- Request body: the **raw UTF-8 bytes** of the prompt (not JSON, not base64). Empty, whitespace-only, invalid UTF-8, a body shorter than `Content-Length`, or over **8 KiB** (8192 bytes) → `400 {"error":"invalid_body"}`.
- **Resolution before sending**, the same lookup `/term/agent-chat` does (memoized `agent list` scan, `host=="mac"` + exact `project` + exact `pane`, zero extra ssh): a pane with no agent → `404 {"error":"no_agent"}` and **no `herdr agent prompt` is issued**. It runs *after* the `400` validations, so malformed input never costs a scan.
- **The body is never logged** (only method+path reach the log, like `/term/input` and `/term/upload`). The connection is closed after the response.
- Remote command, argv list locally, never `shell=True`:
  ```
  <GEO_STATUS_SSH> -o BatchMode=yes -o ConnectTimeout=<GEO_TERM_ATTACH_SSH_TIMEOUT> \
    <GEO_STATUS_MAC_USER>@<GEO_STATUS_MAC_HOST> \
    'export PATH=<dirname GEO_STATUS_HERDR>:$PATH; <GEO_STATUS_HERDR> --session <project> agent prompt <pane> <text>'
  ```
  **Every** interpolated part — herdr path, project, pane and the arbitrary user text — is `shlex.quote`d, so the text reaches herdr as one literal argument: `'; rm -rf …; echo '`, `$(id)`, backticks, quotes and newlines are inert (proven in the smoke against a sentinel file that survives). The strict regexes on `project`/`pane` are defence in depth, not the quoting.
- **No `--wait`/`--until`.** The HTTP handler must not block on an agent that can think for minutes; the timeout is `GEO_AGENT_PROMPT_TIMEOUT` (15 s) and covers only the delivery.
- `200 {"ok":true}` — herdr accepted the prompt. Delivery ≠ answer: what the agent does with it shows up in the next `/term/agent-chat`.
- `404 {"error":"no_agent"}` — that pane has no agent in the current scan (Mac answered). Same meaning as on `/term/agent-chat`; the client renders "esse agente não existe", not a connection problem.
- `503 {"error":"unavailable"}` — the Mac is unreachable at either step: the scan failed (ssh down/timeout/no herdr) or the delivery ssh failed/timed out or herdr exited non-zero. Nothing was sent, or we cannot tell; the client must not assume delivery.

### POST /term/upload

Drops a file into a fixed inbox on the Mac so the phone can paste its path into a shell. **It never executes anything and never sets the executable bit.**

- Auth: the terminal token (`_term_gate`), same as every other `/term/*` route. Main bridge token → `401`. Terminal disabled → `404`.
- Request body: the **raw bytes** of the file (not base64, not multipart).
- Header `X-Geo-Filename`: the destination basename. Validated against `\A[A-Za-z0-9._-]{1,80}\Z` (anchored so a trailing newline is rejected), must equal its own `os.path.basename`, and must not start with `.` (blocks empty, `.`, `..`, `...`, dotfiles, and anything containing `/`). Any violation → `400 {"error":"invalid_filename"}`. There is no sanitizing rewrite: a bad name is rejected, never "cleaned" into a valid one.
- Destination is fixed: `~/garime-uploads/` (override only via `GEO_TERM_UPLOAD_DIR`), created `0700` on demand. The final path is re-checked against `realpath(dir)` and opened `O_CREAT|O_EXCL|O_NOFOLLOW` at `0600`, so an existing symlink in the inbox cannot be used to write outside it (→ `400`).
- Collision → suffix before the extension: `nome.txt`, `nome-1.txt`, `nome-2.txt`, … Existing files are never overwritten. More than 1000 collisions → `409 {"error":"name_conflict"}`.
- Size cap 32 MiB (33554432 bytes) measured from `Content-Length`. Larger → `413 {"error":"too_large"}`. Missing/zero/unparseable length, or a body shorter than announced → `400 {"error":"invalid_body"}`.
- Success → `200 {"path":"/Users/<user>/garime-uploads/<name>"}`. The client types that path into the terminal as input; running it is the user's decision.
- **The body is never logged** (only method+path reach the log). The connection is closed after the response.

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

All bridge-originated errors: `{"error":"<snake_case_code>"}` with the appropriate status (`400` invalid_id/invalid_body/bad_target, `401` unauthorized, `404` not_found/no_agent, `409` task_exists/no_attach, `502` hermes_unreachable, `503` unavailable, `500` internal). Proxied hermes errors pass through untouched.

`503 {"error":"unavailable"}` exists only on `/term/agent-chat` and `/term/agent-prompt` and means **the bridge could not reach the Mac** — it is never interchangeable with an empty `200`. Every other route keeps its historical behaviour of degrading silently to empty/false.
