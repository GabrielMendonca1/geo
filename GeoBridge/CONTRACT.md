# GeoBridge — API contract

HTTP daemon on the VM `garime` exposing three local resources to the tailnet for the iPhone app. The bridge is a **dumb pipe over files**: it never re-models data. Reads return file contents **verbatim** (zero re-encode); mutations are minimal field edits; streams are line pass-through. The Mac app (Geo.app) and hermes remain the owners of all state — the bridge only relays it.

Spec version: 4 (v3 + `/vitals/*` health). All facts below were extracted from the live system on 2026-07-01 (real task files, real dispatch dirs, `TaskItem.swift`, `TasksStore.swift`, `HermesKanbanService.swift`, `api_server.py`, `~/.hermes/config.yaml`).

## Deployment

The bridge runs on the Oracle VM `garime` (tailnet), as the systemd unit `garime-bridge.service` (`/etc/systemd/system/garime-bridge.service`): `ExecStart=/usr/bin/python3 /opt/garime/geobridge.py`, `User=biel`, `Restart=always`. The Mac is no longer a host of the bridge — the LaunchAgent `ai.geo.bridge` was retired on 2026-08-03 (unloaded from launchd, kept under `legacy/`); it stays a *target* of `/term/*` over ssh, which is what every "on the Mac" note below means.

Exposure: `tailscale serve` on the VM publishes `https://garime.tail091418.ts.net` (tailnet only) proxying to `http://127.0.0.1:8643` — that URL is what the iOS app talks to. Tokens live in `/etc/garime/` (`bridge.token`, `bridge.term.token`).

Deploy: `scp` the repo's `geobridge.py` to `/opt/garime/geobridge.py`, then `systemctl restart garime-bridge`.

## Principles

1. **Verbatim reads.** `GET /tasks` concatenates the raw bytes of the task files into a JSON array. The bridge never parses-then-re-serializes for reads: field order, number formatting, and unknown keys reach the phone exactly as written by Geo.app.
2. **Minimal mutations.** Complete/reopen change exactly two fields (`status`, `modifiedAt`) and preserve every other key untouched, then write atomically (temp file + rename in the same directory). Geo.app's `FileWatcherService` on the Tasks dir picks the change up and updates its in-memory store and EventKit mirror — the bridge only has to write the file correctly (see "Mac-app integration facts").
3. **Line pass-through streams.** Dispatch logs and hermes chat SSE are relayed line-for-line / byte-for-byte, never interpreted.
4. **No speculative surface.** Task create exists as of v2 because the phone needs it — and even there the bridge stays a dumb pipe (the phone sends the complete task JSON; the bridge validates and writes, never composes). Task delete exists for the same reason (the phone needs it); still no task update, no dispatch spawn, no session management endpoints. Add them only when the phone needs them.

   **Carve-out — the terminal (`/term/*`, v3).** The terminal is the deliberate exception to principle 4: it is *not* a dumb pipe over files, it is an arbitrary interactive shell as the local user, streamed over the tailnet. This is the single largest blast radius in the whole surface — anyone holding the term token can run any command `biel` can (read/exfiltrate the vault, `rm -rf`, `git push`, spend money, pivot). It is justified because the phone genuinely needs a real terminal (agents live in shells), and it is fenced with five independent controls: (1) a **separate** token (`GEO_BRIDGE_TERM_TOKEN_FILE`) so it can be revoked without touching the rest of the bridge; (2) `GEO_TERM_ENABLED=0` by default → `/term/*` is `404` until explicitly turned on in the unit; (3) tailnet-only bind (unchanged); (4) keystrokes are **never** logged (input rides only in the POST body; the log records method+path only — so `open`/`close`/`resize` show up, never typed bytes); (5) the PTY attach is reaped after 10 min with no connected client. Do not extend this surface (session spawn/list, file upload, etc.) without re-justifying the blast radius.

## Configuration (env vars)

Defaults below are the code's; the **effective** values come from the `Environment=` lines of `garime-bridge.service` (VM paths: `GEO_TASKS_DIR=/mnt/garime/Vault/Tasks`, `GEO_BRIDGE_BIND=127.0.0.1` behind `tailscale serve`, tokens under `/etc/garime/`, `GEO_TERM_ENABLED=1`, `GEO_TERM_TMUX=/usr/bin/tmux`). `GEO_HEALTH_DIR` is not set in the unit — it resolves from `biel`'s `HOME` to `/home/biel/Vault/Health`.

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
| `GEO_TERM_SESSION` | `mobile` | Default tmux session name (used **only** when `?session=` is absent; a malformed value is `400` on every verb — see "Session selection") |
| `GEO_TERM_REPLAY_BYTES` | `262144` | Per-session ring buffer of recent PTY output replayed to each new `/term/stream` |
| `GEO_BRIDGE_TERM_TOKEN_FILE` | `~/.hermes/geobridge.term.token` | Second, dedicated bearer token for `/term/*` (single line, trimmed) |
| `GEO_STATUS_UNITS` | `garime-wa syncthing-garime` | Space-separated allowlist of systemd units reported by `/term/agents` |
| `GEO_STATUS_MAC_HOST` | `100.123.44.9` | Host TCP-probed on port 22 (1 s) for `mac_online` in `/term/agents`; also the ssh target of the herdr agent scan |
| `GEO_STATUS_MAC_USER` | `biel` | ssh user on the Mac for the herdr agent scan (`<user>@<GEO_STATUS_MAC_HOST>`) |
| `GEO_STATUS_HERDR` | `/opt/homebrew/bin/herdr` | Absolute path to `herdr` **on the Mac** (its dirname is also prepended to the remote `PATH`) |
| `GEO_STATUS_SSH` | `ssh` | ssh binary used for the Mac scan (resolved via `PATH`) |
| `GEO_STATUS_AGENTS_TTL` | `10` | Seconds the Mac herdr scan (`agents` of `/term/agents` **and** the panes of `/term/panes`) is cached (the phone polls every 10 s) |
| `GEO_STATUS_AGENTS_TIMEOUT` | `12` | Hard timeout (s) of the single ssh call that scans the Mac |
| `GEO_TERM_ATTACH_SSH_TIMEOUT` | `4` | `ConnectTimeout` (s) of the ssh started **inside tmux** by `/term/attach-agent` and `/term/attach-herdr`, and of the ssh run **in the handler** by `/term/agent-chat` and `/term/agent-prompt` |
| `GEO_AGENT_CHAT_LIMIT` | `40` | Default number of messages returned by `/term/agent-chat` |
| `GEO_AGENT_CHAT_MAX_LIMIT` | `200` | Hard ceiling of `?limit=` on `/term/agent-chat` |
| `GEO_AGENT_CHAT_TEXT_MAX` | `2000` | Per-message character cap on `/term/agent-chat`; longer text is cut and flagged `truncated` |
| `GEO_AGENT_CHAT_TAIL_BYTES` | `131072` | Bytes of the **tail** of the transcript file read on the Mac (`tail -c`) per `/term/agent-chat` call |
| `GEO_AGENT_CHAT_TIMEOUT` | `12` | Hard timeout (s) of the transcript ssh of `/term/agent-chat` |
| `GEO_AGENT_PROMPT_TIMEOUT` | `15` | Hard timeout (s) of the `herdr agent prompt` ssh of `/term/agent-prompt` |
| `GEO_AGENT_COMMANDS_TTL` | `120` | Seconds the per-agent command list of `/term/agent-commands` is cached (own cache, deliberately longer than `GEO_STATUS_AGENTS_TTL`: skills change rarely) |
| `GEO_AGENT_COMMANDS_TIMEOUT` | `15` | Hard timeout (s) of the single skills-listing ssh of `/term/agent-commands` |
| `GEO_AGENT_COMMANDS_CACHE_MAX` | `64` | Maximum `(project, pane, agent, cwd)` entries kept by the `/term/agent-commands` cache before the oldest is evicted |
| `GEO_AGENT_COMMANDS_HEAD_LINES` | `12` | How many leading lines of each `SKILL.md`/`*.md` are scanned **on the Mac** for the `description:` line |
| `GEO_AGENT_WORK_TTL` | `5` | Seconds the parallel-work snapshot of `/term/agent-work` is cached (own cache; deliberately short — this is the fastest-moving state the bridge serves) |
| `GEO_AGENT_WORK_TIMEOUT` | `12` | Hard timeout (s) of the single ssh of `/term/agent-work` |
| `GEO_AGENT_WORK_RUNNING_WINDOW` | `120` | Seconds of mtime freshness that make a **direct sub-agent** count as `running:true` (see the heuristic below) |
| `GEO_AGENT_WORK_STALE_AFTER` | `3600` | Seconds after which a workflow with no activity at all (neither journal nor any sub-agent transcript touched) stops counting its unfinished `started` events as running: `running:0`, `stale:true` |
| `GEO_AGENT_WORK_WORKFLOWS_MAX` | `10` | Workflows returned by `/term/agent-work` (newest first); a cut sets `truncated:true` |
| `GEO_AGENT_WORK_SUBAGENTS_MAX` | `20` | Direct sub-agents returned by `/term/agent-work` (newest first); a cut sets `truncated:true` |
| `GEO_AGENT_WORK_SCAN_MAX` | `200` | Workflow dirs / sub-agent metas the **remote** script looks at before ordering happens on the VM |
| `GEO_AGENT_WORK_CACHE_MAX` | `64` | Maximum `(project, pane, session-id, cwd)` entries kept by the `/term/agent-work` cache before the oldest is evicted |
| `GEO_AGENT_UPLOAD_DIR` | `garime-uploads` | Inbox **on the Mac**, always relative to the ssh user's `$HOME`, for `/term/agent-upload` (a bare name, never a path) |
| `GEO_AGENT_UPLOAD_TIMEOUT` | `120` | Hard timeout (s) of the `/term/agent-upload` ssh (covers streaming up to 32 MiB over stdin) |
| `GEO_AGENT_ASK_SCAN_LINES` | `60` | How many lines from the **bottom** of the captured pane `/term/agent-ask` scans for a question block; an older block above that window is not reported |
| `GEO_AGENT_ASK_TIMEOUT` | `5` | Hard timeout (s) of the `tmux capture-pane` of `/term/agent-ask` and `/term/agent-answer` |
| `GEO_AGENT_ASK_OPTION_GAP` | `6` | Max lines between two consecutive option lines still chained into the same question block (absorbs tmux wrapping and border-only pad lines at narrow pane widths) |
| `GEO_AGENT_ASK_TAIL_BODY` | `4` | Max non-blank, non-chrome, non-hint lines tolerated **between** the option block and the affordance footer (dialog body lines such as `● High effort (default) ←/→ to adjust` — or its degraded sibling `○ Effort not supported for Haiku` — and the wrap continuation of the last option). Zero are tolerated *after* the footer |
| `GEO_AGENT_PI_SKILLS_DIR` | `/mnt/garime/pi/skills` | Where the **VM's** pi keeps its skills. Globbed by `/term/agent-commands` in addition to `$HOME/.pi/agent/skills`, which does not exist on the VM |
| `GEO_AGENT_INTERRUPT_KEY` | `Escape` | tmux key name sent by `/term/agent-interrupt` on the **VM** path (see the rationale there before changing it to `C-c`) |
| `GEO_AGENT_INTERRUPT_KEY_MAC` | `esc` | herdr logical key name sent by `/term/agent-interrupt` on the **Mac** path. herdr's canonical name is `esc` (`escape` is also accepted); it is *not* the tmux spelling, which is why this is a separate var |
| `GEO_AGENT_ASK_MAC_TIMEOUT` | `12` | Hard timeout (s) of each `herdr pane` ssh of the Mac path of `/term/agent-ask`, `/term/agent-answer` and `/term/agent-interrupt` (same budget as `/term/agent-chat`: 4 s ssh connect + the herdr socket round-trip) |
| `GEO_AGENT_WATCH` | `0` | Master switch of the **agent-ask watcher** (below). **Off by default on purpose** — a watcher that comes up armed on a deploy sends WhatsApp the owner never asked for. Arming it is a deliberate act: add `Environment=GEO_AGENT_WATCH=1` to `garime-bridge.service` and `daemon-reload` + `restart`. As of 2026-08-06 that line is **not** in the unit on the VM and the deployed `/opt/garime/geobridge.py` predates the watcher |
| `GEO_AGENT_WATCH_INTERVAL` | `30` | Seconds between watcher ticks. Floored at `5` |
| `GEO_AGENT_WATCH_COOLDOWN` | `300` | Minimum seconds between two notifications **for the same tmux session**. A notification suppressed by the cooldown is **dropped, never queued** |
| `GEO_AGENT_WATCH_MAX_HOUR` | `12` | Global ceiling of notifications per sliding hour across all sessions. Over the ceiling the event is logged and **dropped, never queued** |
| `GEO_AGENT_WATCH_MIN_COLS` | `40` | Minimum `#{pane_width}` the watcher will judge a pane at. Narrower (or an unreadable width) = "could not find out": the tick skips that session without notifying **and without clearing** |
| `GEO_AGENT_WATCH_SEEN_TTL` | `86400` | Seconds a seen question fingerprint is remembered after it was last observed. Only this TTL forgets it — an agent missing from a degraded scan never does |
| `GEO_AGENT_WATCH_STATE` | `~/.garime/agent-watch.json` | Persisted watcher state (seen keys, per-session last-sent, hourly ledger). Survives `Restart=always`, so a restart while an agent is blocked does not re-send |
| `GEO_WA_OUTBOX` | `/mnt/garime/pi/wa-outbox` | Directory drained by `garime-wa.service`. Writing a `*.txt` there = sending a WhatsApp message to the group |
| `GEO_AGENT_PI_SESSIONS_DIR` | `/mnt/garime/pi/agent/sessions` | Where the **VM's** pi keeps its transcripts (`<cwd-encoded>/<ts>_<uuid>.jsonl`). Used only by the `session=` selector; a missing dir falls back to `$HOME/.pi/agent/sessions` |
| `GEO_AGENT_PRIME_SESSIONS_DIR` | *(empty)* | Where the **VM's** `prime-agent` keeps its transcripts (flat `<uuid>.jsonl`, no per-project directory). Used only by the `session=` selector; empty — the default — or a missing dir falls back to `$HOME/.prime/agent/sessions` |
| `GEO_AGENT_PRIME_SCAN_MAX` | `50` | How many of the newest `*.jsonl` of that flat directory have their first line read while looking for the pane's `cwd`. A session older than that window reads as empty instead of blowing past `GEO_AGENT_CHAT_TIMEOUT` |
| `GEO_AGENT_VM_DEPTH` | `3` | How many process generations below a tmux pane are inspected when detecting which agent runs in a VM session (the pane's own command is generation 0) |

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

A real interactive terminal for the phone. **Not** a dumb pipe over files (see the principle-4 carve-out above for the blast-radius warning). Eleven endpoints (`stream`, `input`, `resize`, `winsize`, `list`, `preview`, `agents`, `panes`, `kill`, `rename`, `upload`), all gated and separately authed. `preview`, `agents` and `panes` are strictly read-only and never spawn a session.

**Session selection.** Every `/term/*` endpoint takes `?session=<name>`, matched against `\A[A-Za-z0-9_-]{1,32}\Z` (anchored so a trailing newline is rejected, not accepted as `$` would). A **missing** value falls back to `GEO_TERM_SESSION` (default `mobile`) on every endpoint. A **present but malformed** value is `400 {"error":"bad_name"}` on **every** verb, reading or mutating (`stream`, `input`, `resize`, `winsize`, `list`, `preview`, `kill`, `rename`, and the `agent-*` verbs). One validator, no silent fallback: redirecting a request onto the default session — a stream just as much as a kill — answers about a session the caller never asked for. `/term/list` ignores the value but still validates it. The name `mac` is special: if `GEO_TERM_PROFILE_MAC` is set, that script is run as the session's command.

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

The term token lives alongside the main token in `/etc/garime/` (`openssl rand -hex 32`, `chmod 600`). Its absence does **not** block bridge startup (only the main token does); it simply leaves `/term/*` dark.

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

- `?session=<name>` follows the usual rule (absent → `GEO_TERM_SESSION`; malformed → `400 {"error":"bad_name"}`). `?lines=<n>` is clamped to `1..40`, default `12`, unparseable → default.
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

- Per entry: `host` is `mac`|`vm`; `agent` is the agent binary (`claude`, `pi`, `prime-agent`, `codex`, `kimi`, `opencode`); `status` is `idle`|`working`|`unknown` on the Mac and always `running` on the VM; `title` is the herdr `terminal_title_stripped` (fallback `terminal_title`, else `""`); `project` is the herdr session the pane belongs to (empty on the VM); `cwd` when herdr reports one.
- `pane` is the herdr `pane_id` of the entry (`w<n>:p<n>`), `""` when herdr does not report one and always `""` on the VM. Together with `project` it is the exact pair `/term/attach-agent` takes — the client never builds it, it echoes what this endpoint gave it.
- **Mac side**: one `ssh -o BatchMode=yes -o ConnectTimeout=4 <GEO_STATUS_MAC_USER>@<GEO_STATUS_MAC_HOST>` (argv list, never `shell=True`, hard timeout `GEO_STATUS_AGENTS_TIMEOUT`). The remote script lists the `running` herdr sessions and, per session, prints a `##session <name>` marker followed by the single-line JSON of `herdr --session <name> agent list` **and** of `herdr --session <name> pane list`; the marker is what makes `project` exact instead of guessed. Each stdout line is parsed independently — unparseable lines are skipped. The `agent list` half feeds `agents` here: panes without an `agent` key (`agent_status:"unknown"`, no agent attached) are not agents and are discarded. The `pane list` half is the whole workspace and is served by `/term/panes`; it never enters the `/term/agents` payload, whose per-entry shape is unchanged.
- **The Mac side fails silently**: ssh down, host unreachable, timeout, no herdr, garbage output → it contributes an empty list. `/term/agents` never 5xxs because of it, and `units`/`mac_online` are unaffected.
- **VM side**: a `ps -eo pid= -o ppid= -o comm=` scan for local `pi`/`prime-agent`/`claude`/`codex`/`kimi`/`opencode` processes, `status:"running"`, `project`/`title`/`cwd` empty (that data is not available cheaply and is not invented), ordered by pid. The WhatsApp bot runs as `node` and is *not* listed here — it is already the `garime-wa` unit.
- **`session` (VM entries only)**: the name of the **tmux session** the process lives in, `""` when it runs outside tmux. It is the selector the client hands back to `/term/agent-chat`, `/term/agent-prompt` and `/term/agent-work` (`?session=<name>`) — the VM has no herdr, so `project`/`pane` stay empty there and an entry with an empty `session` is **not** openable. Mapping comes from one `tmux list-panes -a -F '#{session_name}\t#{pane_pid}…'` plus the same `ps` tree, walking up to `GEO_AGENT_VM_DEPTH` (3) generations below each pane pid; a failing/absent tmux degrades to `""`, never to a 5xx. **Only panes that are both `#{pane_active}` and `#{window_active}` are mapped**, so this listing agrees with the whole `/term/agent-*` family, which reads and writes the active pane of the session's current window and nothing else: an agent sitting in a background pane or window used to be advertised here with a `session` on which every `agent-chat`/`agent-answer`/`agent-interrupt` call then answered `404 no_agent` (or, worse before the fix, typed into the shell next to it). Such an agent is still listed — it is really running — but with `session:""`, i.e. explicitly not openable.

```json
{"host":"vm","agent":"claude","status":"running","title":"","project":"","pane":"","cwd":"","session":"claude"}
```

- The key is **added only to `host:"vm"` entries** and always last; the `host:"mac"` shape is byte-identical to before (`host agent status title project pane cwd`), asserted in the smoke against the previous build.
- **Cost and cache**: the ssh round trip is ~1.3 s, the phone polls every 10 s. The whole scan (`agents` **and** the panes behind `/term/panes`) is memoized for `GEO_STATUS_AGENTS_TTL` seconds. Refreshes are serialized by a second lock, so two concurrent requests produce **one** ssh (the loser waits and reads the fresh cache); the cache lock is never held during the ssh, so a slow refresh cannot deadlock other routes. A failed refresh caches the degraded result for the TTL — the last good value survives only as long as it is fresh, and there is no stale replay beyond it.

### GET /term/panes

The **project GUI**: every pane of one herdr session — agents *and* plain shells (lazygit, gh dash, a bare zsh) — so the phone can draw the project screen instead of attaching to herdr's TUI. Read-only, spawns nothing.

- Auth: the terminal token (`_term_gate`). Main bridge token → `401`. Terminal disabled → `404`.
- `?project=<name>`, required, validated by the same anchored regex as `/term/attach-agent` (`\A[A-Za-z0-9_-]{1,24}\Z`, never `$`) → otherwise `400 {"error":"bad_target"}` and no ssh happens.

```json
{"project":"garime","panes":[
 {"pane":"w1:p1","agent":"claude","status":"working","title":"tech stack audit",
  "cwd":"/Users/biel/Garime","tab":"w1:t1"},
 {"pane":"w1:p4","agent":"","status":"unknown","title":"","cwd":"/Users/biel/Garime","tab":"w1:t4"}
]}
```

- Per entry: `pane` is the herdr `pane_id` (`w<n>:p<n>`) — the exact value `/term/attach-agent` takes; `agent` is the herdr `agent` field and is **`""` when the pane has no agent** (a shell) — nothing is invented; `status` is `idle`|`working`|`unknown` (`unknown` for shells); `title` is `terminal_title_stripped` (fallback `terminal_title`, else `""`); `cwd` and `tab` (herdr `tab_id`) are `""` when not reported. Entries with no `pane_id` are dropped.
- **Order is herdr's order** — the visual order of its workspace — and is never re-sorted, so the screen matches the Mac.
- Same memoized scan as `/term/agents` (`GEO_STATUS_AGENTS_TTL`, same locks): polling this screen costs **no** extra ssh, and two concurrent requests produce one ssh.
- Codes:
  - `200` — the pane list. A project with no panes, and a project herdr does not know, are both `200` with `panes: []`: `herdr session list` simply does not emit an unknown session, so the bridge cannot tell "empty" from "does not exist" and refuses to invent a `404`.
  - `400 {"error":"bad_target"}` — malformed/absent `project`.
  - `503 {"error":"unavailable"}` — **we could not find out**: the Mac scan failed (ssh down, host unreachable, timeout, no herdr). Never `200` with an empty list — the client must render "sem conexão", not "projeto vazio". Same rule as `/term/agent-chat`; `/term/agents` keeps its own silent-fail behaviour.

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
- **`attach-agent` resolves the pane before spawning** (the same memoized scan `/term/agent-chat` uses, zero extra ssh). `herdr agent attach` on a pane with no agent fails *inside* tmux and the session dies seconds later — the phone used to get a `200`, a session name, and a terminal that 404s on the next `/term/preview`. So:
  - pane with an agent → spawn as below;
  - pane that exists in `/term/panes` but has **no agent** (a shell) → `409 {"error":"no_agent_in_pane"}`, **no tmux session created**;
  - pane that does not exist in the project → `404 {"error":"no_agent"}`, nothing created;
  - Mac scan failed → `503 {"error":"unavailable"}`, nothing created.
  `attach-herdr` is unaffected: it targets the whole project, not a pane, and never resolves anything.
- **Derived session name** — deterministic, never chosen by the client: `ag-<project>-<pane without the colon>` (e.g. `ag-garime-w1p3`) and `hd-<project>` (e.g. `hd-garime`). If the name would exceed the 32-char `TERM_SESSION_RE` budget, the project is truncated and a 4-hex-char sha1 of the full project is appended, so two long projects never collapse onto one session. The `ag-`/`hd-` prefixes are a namespace: a derived name can never equal the reserved `mac`, and a user session only collides if the user deliberately names one `ag-…`/`hd-…`.
- **Reuse**: the spawn is the ordinary `tmux new-session -A -s <derived>` path, so a second call with the same `project`/`pane` returns the same name and attaches to the session already running — no second ssh, no second tmux session.
- **The remote command** runs inside tmux, never in the HTTP handler (the handler returns as soon as the session exists):
  ```
  <GEO_STATUS_SSH> -tt -o BatchMode=yes -o ConnectTimeout=<GEO_TERM_ATTACH_SSH_TIMEOUT> \
    <GEO_STATUS_MAC_USER>@<GEO_STATUS_MAC_HOST> \
    'export PATH=<dirname GEO_STATUS_HERDR>:$PATH; <GEO_STATUS_HERDR> --session <project> [agent attach <pane>]'
  ```
  argv list, never `shell=True`; every interpolated part is `shlex.quote`d on top of the strict regexes. `-tt` is mandatory — herdr panics (`failed to initialize terminal`) without a TTY and renders empty on a zero-sized one, which is why this only works from inside a real tmux session. No `--takeover`: herdr accepts several simultaneous clients, so attaching from the VM does **not** kick the Mac's own herdr window.
- Success → `200 {"session":"<derived name>"}`. The bridge does not wait for ssh: a herdr that dies for any other reason, or a wrong project on `attach-herdr`, still surfaces as the error text *inside the terminal stream*, not as an HTTP code.
- **Ephemeral by nature.** These sessions are ordinary bridge sessions: they show up in `/term/list`, `/term/preview` and `/term/winsize`, and `POST /term/kill?session=<derived>` kills them like any other. When the remote ssh/herdr exits, tmux tears the session down on its own. The 600 s idle reaper (no `/term/stream` client) tears the bridge's attach down as usual; re-issuing `attach-agent`/`attach-herdr` is always the way back in and is idempotent.

### GET /term/agent-chat

The **agent GUI** read side: the recent conversation of one Mac agent as structured data, so the phone can talk to an agent by request/response instead of holding a PTY open. This is the answer to the terminal being unusable on 4G (`/term/stream` reopened 19× in one hour on the street) — nothing here streams, nothing here is stateful, every call is a self-contained poll.

- Auth: the terminal token (`_term_gate`), same as every other `/term/*` route. Main bridge token → `401`. Terminal disabled → `404`.
- Params — the exact `project`/`pane` pair `/term/agents` reported, validated by the same anchored regexes as `/term/attach-agent` (`\A[A-Za-z0-9_-]{1,24}\Z` and `\Aw[0-9]{1,3}:p[0-9]{1,3}\Z`, never `$`). Both are **required**; anything else → `400 {"error":"bad_target"}` and no ssh happens.
- `?limit=<n>`: number of **messages** (not records) returned, counted from the end. Default `40`, clamped to `1..200`, unparseable → default.

```json
{"agent":"claude","status":"working","resolved":"reported","messages":[
  {"role":"user","text":"roda os testes","ts":"2026-08-05T02:10:01"},
  {"role":"assistant","text":"51 verdes, gate fechou","ts":"2026-08-05T02:10:05"},
  {"role":"tool","tool":"Bash","ts":"2026-08-05T02:10:05"}
]}
```

- **Resolution** costs zero extra ssh: the pane is looked up in the same memoized `agent list` scan that backs `/term/agents` (`GEO_STATUS_AGENTS_TTL`), matching `host=="mac"` **and** exact `project` **and** exact `pane`. That scan now also keeps each entry's herdr `agent_session` (`{"agent","kind","value"}`); it is used only here and is **stripped from the `/term/agents` payload**, whose per-agent shape is unchanged (`host agent status title project pane cwd`).
- **Transcript location** — from `agent_session`, two steps, both inside the **same single ssh** (never a second round trip):
  - `kind:"id"` (claude): the id (`\A[A-Za-z0-9._-]{1,80}\Z`) is resolved by **glob**, `$HOME/.claude/projects/*/<id>.jsonl`. The project dir is *not* derivable from the agent's `cwd` (a live example has `cwd=/Users/biel/Garime` and the file under `-Users-biel/`), so it is never guessed *for this step*.
  - `kind:"path"` (pi): the absolute `.jsonl` path herdr already hands over, used as-is.
  - Any other/absent `agent_session` → `200` with `messages: []`.
- **Fallback for a stale session id** — herdr reports the id it saw when it registered the pane, and Claude Code **rotates** it (resume, context compaction). A live measurement had herdr reporting `fb213408-…` for a working pane while no `~/.claude/projects/*/fb213408-….jsonl` existed on disk at all; the symptom was a busy agent showing one message or none. So when the reported id resolves to nothing:
  - claude: fall back to the **most recently modified** `*.jsonl` **inside the single project dir of that pane's `cwd`**, derived as `$HOME/.claude/projects/<cwd with every char outside `[A-Za-z0-9-]` replaced by `-`>` (confirmed against the real dir names: `/Users/biel/Garime` → `-Users-biel-Garime`, `/Users/biel/Omni/_run/locadora` → `-Users-biel-Omni--run-locadora`). No `cwd`, or a project dir that does not exist → nothing is read.
  - pi: fall back to the most recently modified `*.jsonl` in the **same session directory** as the dead path.
  - **The fallback never crosses projects.** It is scoped to that one directory, so a newer transcript of another `cwd` can never be served; an empty answer is always preferred over the wrong conversation. The cost is one `ls -1t` guarded by `2>/dev/null` — no file content is listed or read beyond the tail below.
  - The whole remote command is a single `/bin/sh -c '…'` (the Mac login shell is **zsh**, where an unmatched glob is a fatal error; the `sh` wrapper plus `2>/dev/null` makes the script produce byte-identical output under `sh -c` and `zsh -c` — asserted in the smoke).
- **`resolved`** reports which path was taken, so the client (and the owner) can tell a heuristic answer from an exact one: `"reported"` = the id/path herdr gave resolved to a real file; `"fallback"` = it did not and the newest transcript of that pane's project dir was used; `""` = nothing was resolved (no session, or nothing on disk) and `messages` is `[]`. The key is always present.
- **Only the tail is read.** The remote command is `tail -c <GEO_AGENT_CHAT_TAIL_BYTES> <file>` (128 KiB), so a 1.4 MB / 5000-record transcript costs one bounded read on the Mac, one bounded transfer, and one bounded parse on the VM — the file never grows the response or the bridge's memory. The first line of the tail is usually a partial record; it simply fails to parse and is dropped like any other garbage line.
- **Conversion** (JSONL → messages, in file order): records of `type` `attachment`, `custom-title`, `mode`, `last-prompt`, `summary`, `system` are dropped, as is anything without a `user`/`assistant` role. Within a message's `content` blocks, `text` blocks are concatenated (`\n`) into one message; each `tool_use` block becomes its own `{"role":"tool","tool":"<name>"}` entry **carrying no payload** (no input, no id, no output) at its position in the block order; `tool_result` blocks are discarded, so a user turn that is only tool results yields nothing. Whitespace-only messages are dropped. Unparseable lines are skipped, never invented.
- **Truncation**: message text over `GEO_AGENT_CHAT_TEXT_MAX` (2000) chars is cut to the cap and the message gets `"truncated":true`. The key is absent otherwise.
- **pi is read defensively**: its schema is not assumed to be claude's — `message` may be the record itself, `content` may be a plain string, `timestamp` may sit either level. A record matching no known shape is discarded rather than guessed.
- Codes:
  - `200` — the conversation (possibly `[]`: a fresh session that has not written a transcript yet is **not** an error).
  - `400 {"error":"bad_target"}` — malformed `project`/`pane`.
  - `404 {"error":"no_agent"}` — that pane has no agent in the current scan.
  - `503 {"error":"unavailable"}` — **we could not find out**: the Mac scan failed (ssh down/timeout/no herdr) or the transcript ssh failed or timed out. This code is semantically distinct from `200 []` on purpose: the client must render "sem conexão", never "conversa vazia". `/term/agents` keeps its old silent-fail behaviour (empty Mac list, never 5xx); the distinction lives only here.

#### VM agents — `?session=<tmux-session>` (alternative selector)

Agents that run **on the VM itself** have no herdr, so no `project`/`pane` exists for them. Their natural identity is the **tmux session name** they live in, which is what `/term/agents` now reports as `session`. The three agent endpoints (`/term/agent-chat`, `/term/agent-prompt`, `/term/agent-work`) accept `?session=<name>` **instead of** `project`+`pane`:

- `session` is validated by the same anchored session regex as the rest of `/term/*` (`\A[A-Za-z0-9_-]{1,32}\Z`, never `$`) → `400 {"error":"bad_target"}`. Sending `session` **together with** `project` and/or `pane` (or repeating `session`) is also `400`: the two selectors are mutually exclusive, never merged.
- **Agent detection is local** (this is the same machine — no ssh anywhere on this path): `tmux list-panes -t '=<session>:' -F '#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}'` — **always the exact target** `=<name>:`, never a prefix match — then, per pane, the pane command; if it is not an agent (it usually is the shell), the pane pid's descendants up to `GEO_AGENT_VM_DEPTH` (3) generations, from one `ps -eo pid= -o ppid= -o comm=` snapshot. The first pane whose command *or* descendant basename is in `pi`/`prime-agent`/`claude`/`codex`/`kimi`/`opencode` wins, and that pane's `#{pane_current_path}` is the `cwd` everything else is scoped by.
- **Transcript** — the resolver and the `cwd` scoping are the Mac ones, reused: claude reads the newest `*.jsonl` of `$HOME/.claude/projects/<cwd with every char outside [A-Za-z0-9-] replaced by ->`; pi reads the newest `*.jsonl` of `<GEO_AGENT_PI_SESSIONS_DIR>/-<same encoding>-` (`/mnt/garime` → `--mnt-garime--`), falling back to `$HOME/.pi/agent/sessions/` when that root does not exist. `prime-agent` has **no per-project directory at all** — it writes every session flat into `<GEO_AGENT_PRIME_SESSIONS_DIR>` (unset — the default — or a non-existent root falls back to `$HOME/.prime/agent/sessions`), so the scoping is done by **content**: the newest `*.jsonl` whose **first line** (the `{"type":"session",…}` header) contains the literal `"cwd":"<pane cwd>"` — the closing quote is part of the match, so `/a/b` never selects `/a/b2`. The literal is matched in **both** its raw form and its `\uXXXX`-escaped form (prime serializes the header ASCII-only), so an accented project dir still resolves. Any other agent → `200` with `messages: []`. Same single `/bin/sh -c '…'` script as the Mac, run locally instead of over ssh, same `tail -c` cap, same parser — prime's assistant blocks are camelCase `toolCall`, read as tool entries exactly like claude's `tool_use`; `thinking` blocks are dropped on both.
- **`resolved` on the VM is always `"fallback"`** — and that is honest, not cosmetic: there is no herdr to report a session id, so the newest transcript of that `cwd` is *by construction* a heuristic. `""` still means nothing was resolved (no transcript on disk yet, or an agent with no readable transcript). **`"reported"` can never appear on this path.**
- **The fallback never crosses projects here either**: it is scoped to the single directory derived from that pane's `cwd`; another `cwd`'s newer transcript is never served (asserted in the smoke). For `prime-agent` the same invariant holds through the header match instead of a directory: **no header match → nothing is emitted** (`resolved:""`, `messages: []`); the flat directory's newest file is *never* served as a blind fallback. An empty `cwd` skips the lookup entirely (empty script).
- **The `prime-agent` scan is bounded**: `ls -1t` of that directory is cut to `GEO_AGENT_PRIME_SCAN_MAX` (50) newest files, and only the first line of each is read (`head -n 1 | grep -qF`), so the cost stays flat as the flat directory grows — a session older than the 50 newest reads as empty rather than blowing past `GEO_AGENT_CHAT_TIMEOUT` on an endpoint that has no cache. Measured with 1000 files: ~0.11 s worst case.
- `status` is always `"running"` (same as `/term/agents` for VM entries — the VM has no idle/working signal).
- Codes: `200` (possibly `[]`) · `400 bad_target` · `404 {"error":"no_session"}` (no tmux session by that name) · `404 {"error":"no_agent"}` (the session exists but no agent process was found in it — we never invent a conversation) · `503 {"error":"unavailable"}` when the **local** lookup itself blew up (tmux binary missing, `tmux`/`ps` timeout, transcript script non-zero). On this path `503` never means "the Mac is down"; it still means "we could not find out".

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

#### VM agents — `?session=<tmux-session>`

Same selector rules as `/term/agent-chat` (`400 bad_target` for a malformed name or for `session` mixed with `project`/`pane`), same local detection, same `404 no_session` / `404 no_agent`. **There is no herdr on the VM, so the channel is the pty**: the text is written into the tmux session through the exact same durable-attach path `/term/input` uses (`tmux new-session -A -s <name>` owned by the bridge, one shared pty per session), followed by Enter (`\r`) after a 50 ms pause so the TUI never reads the submit key inside the same chunk as the text.

- **Body**: identical to the Mac side — raw UTF-8, non-empty, not whitespace-only, **cap 8192 bytes** → `400 {"error":"invalid_body"}`. The body is never logged; the connection is closed after the response.
- **Control-character policy — everything below `0x20` except `\n`, plus `0x7f`, is rejected** (`400 {"error":"invalid_body"}`, nothing written). This is a pty, not a shell: quoting cannot protect it. `\x1b` would let a prompt drive the agent's TUI (or the terminal itself) with escape sequences, `\r` is the submit key, `\t` is completion/mode-switch, and the rest are equally load-bearing keys. Rejecting is preferred over stripping so the client sees that its prompt was not delivered *as written* instead of silently mutated.
- **Multi-line is normalized, not sent as multiple keystrokes**: `\n` is the one control character allowed, and each line is stripped, empty lines dropped, and the lines joined with a **single space** — one line, one Enter. Agent TUIs treat a bare `\n` as "send now", so passing a 5-line prompt through would fire 5 half-prompts at the agent; collapsing is the only behaviour that keeps a pasted paragraph one prompt. Clients that need real line breaks must not use this endpoint.
- `200 {"ok":true}` means the bytes were written to the session's pty — the same guarantee `/term/input` gives, no more. `409 {"error":"no_attach"}` if the pty write failed; `503 {"error":"unavailable"}` if the local lookup/attach blew up (no tmux, `ps` timeout).

### GET /term/agent-ask

**Is the agent blocked waiting for a human?** A Claude Code permission prompt (`❯ 1. Yes / 2. No`) is unanswerable from the phone by design: `/term/agent-prompt` rejects every control byte below `0x20` except `\n`, so arrow keys and `Esc` cannot be smuggled through a prompt body — and that policy is not loosened. This endpoint plus `/term/agent-answer` are the **closed-vocabulary verbs** that unblock it instead.

- Auth: the terminal token (`_term_gate`). Selector: the same two mutually-exclusive forms as `/term/agent-chat` — `?session=<tmux>` (VM) or `?project=&pane=` (Mac). Malformed, or the two mixed → `400 {"error":"bad_target"}`.

```json
{"agent":"claude","asking":true,"kind":"permission","question":"Do you want to proceed?",
 "options":[{"index":1,"label":"Yes","selected":true},{"index":2,"label":"No","selected":false}],
 "raw_hint":"Do you want to proceed?\n❯ 1. Yes\n2. No"}
```

- **VM path**: `tmux capture-pane -p -t '=<session>:'` — the **exact** pane target (`=` + `:`), never a prefix, like everywhere else in `/term/*`. No `-e`: the parser wants plain text, not ANSI. The agent is resolved first with the same local detection as `/term/agent-chat`, so `404 no_session` / `404 no_agent` keep their meanings — an agent that is not there cannot be asking anything.
- **Mac path** (v5 — it used to always answer `asking:false`): one ssh running `herdr --session <project> pane read <pane> --source visible --format text`, fed to the **same** parser as the VM. herdr's `pane read` is the exact analogue of `tmux capture-pane -p`: `--source visible` is the current screen, `--format text` strips ANSI. The agent is resolved first through the memoized `/term/agents` scan, so `503` (Mac unreachable / scan failed) and `404 no_agent` keep their meanings, and a non-zero herdr exit is `503`, never `asking:false`.
  - The response carries one extra field on this path: **`blocked`** — herdr's own lifecycle state for the pane (`agent_status == "blocked"`, documented upstream as "Herdr recognized an approval or question UI"), taken from the same `/term/agents` scan that resolved the agent. It is **not** used to compute `asking`: it says *that* the agent is waiting, never *what* it is waiting for, and a question with no options is unanswerable by `/term/agent-answer`. It exists so the client can tell "idle" from "blocked but the dialog did not parse" and offer the terminal instead of a wrong "free" badge. The field is **absent on the VM path** — tmux has no lifecycle signal and reporting `false` there would be an invention.
  - **Known false negative on hosts with a Claude Code `statusLine`.** The parser demands the option block be the *last real content* of the pane (zero tolerance after the affordance footer). A configured `statusLine` (`~/.claude/settings.json`) renders **below** the dialog — on this Mac: `▲ omni ▸ ⌥ main`, a context/cost meter, `⏵⏵ bypass permissions on (shift+tab to cycle)`, an agent-count line — and the first of those lines that is not a key hint kills the detection. Verified against a real `herdr pane read` capture: the same permission dialog parses to 3 options bare and to `asking:false` with that tail appended. This is a **false negative, never a false positive** — the bridge under-reports, it never answers something that was not asked. Two escape hatches, in this order: `blocked:true` still flags the pane, and removing/shortening `statusLine` on the host restores full detection. It was deliberately **not** fixed by teaching the parser to strip a statusline: there is exactly one detector for both hosts, and a chrome-stripping heuristic is how a false positive gets in.
- **Parser** (tested against a real Claude Code permission prompt rendered through `tmux capture-pane` at 60/80/100 columns — wrapping included — byte-for-byte against the non-wrapping paste, and against two verbatim live captures: the Codex CLI directory-trust prompt and a Claude Code v2.1.219 composer holding an unsent numbered draft):
  - The **last** option block of the pane wins — scanning starts at the bottom, so an already-answered prompt higher up is never reported. Only the last `GEO_AGENT_ASK_SCAN_LINES` (60) lines are considered.
  - An option line is `[<cursor> ]<n>. <label>` after stripping whitespace and box-drawing borders (`│`, `|`). Cursor characters: `❯` (U+276F, Claude Code), `›` (U+203A, **Codex CLI** — its first, fully blocking screen is the directory-trust prompt `› 1. Yes, continue / 2. No, quit`; leaving U+203A out made `asking:false` on a 100% blocked agent that `/term/agent-start` is allowed to start), `▶`, `»`. Plain ASCII `>` is **not** a cursor: it is the quote/diff prefix in ordinary agent output (`> 1. x`), where nothing is being asked.
  - **Positive dialog signal — the load-bearing guard.** In Claude Code v2.x `❯` marks **every user message in the transcript**, not just a menu cursor: cursor + numbered lines match equally well on a live prompt, on scrollback where the user once typed `1. … / 2. …`, and on an **unsent numbered draft** sitting in the composer. The earlier frame heuristic (a bare `─` rule above *and* below the block) was defeated by all three — scrollback has no rule at all, a draft can carry prose after the list, and ≥ 3 blank lines push the rule out of the 2-line probe — and a false `asking:true` is not cosmetic: it makes `/term/agent-answer` type a digit + `\r` into a *working* agent, submitting whatever was in the composer. So framing was dropped for a **positive signal from the dialog component itself**: after the option block, the only thing allowed in the pane is (a) blank lines, (b) pure box-drawing chrome (`─`–`╿`, e.g. `╰────╯`), (c) **key-hint lines** — a key token (`esc`, `enter`, `return`, `tab`, `space`, `ctrl+x`/`shift+x`, an arrow run like `←/→`, or a single-character key) followed by `to <word>`, e.g. `◐ Medium effort ←/→ to adjust` in Claude's `/model` picker — and (d) at least **one** affordance footer: the same `(press )?(esc|escape|enter|return) to <word>` shape, matched **anywhere in the line** (not `\A`-anchored) because real footers are ` Esc to cancel · Tab to amend · ctrl+e to explain` (Claude permission), `Enter to set as default · s to use this session only · Esc to cancel` (Claude `/model`), `Press enter to continue` (codex update / trust-folder) and `Press enter to confirm or esc to go back` (codex hooks). **`to interrupt` is deliberately excluded from (d)** and demoted to a key hint: `esc to interrupt` is the affordance a *working* agent prints in its spinner (`✻ Churning… (12s · esc to interrupt)`), never a dialog footer in any captured screen — accepting it would re-open exactly the false positive this guard exists for, since a just-sent numbered user message plus the spinner is the whole tail of the pane. **No footer → `asking:false`.** The remaining tail is read in two halves, because tolerating "any unknown line" anywhere would re-open the false positive: **before** the footer up to `GEO_AGENT_ASK_TAIL_BODY` (4) unknown lines are dialog *body* and are skipped — the `/model` picker prints, right below the option block, an effort line whose **default and overwhelmingly common** form is `● High effort (default) ←/→ to adjust` (a key hint, so it is skipped by (c)); only for Haiku — the single model whose effort setting degrades — does it become `○ Effort not supported for Haiku`, which is *not* of the form `<key> to <x>` and is what consumes the body budget. **Any `/model` fixture captured with Haiku selected hides the `●` state entirely**, which is how `●` came to be listed as a fatal transcript glyph and made every `/model` dialog on a normal model read `asking:false`; `●` is therefore **not** a fatal glyph — see below. At 60 columns the wrap continuation of the **last** option (`quick answers`) also lands below the block, where `GEO_AGENT_ASK_OPTION_GAP` cannot reach it; **after** the footer nothing unknown is allowed at all, which is what kills a transcript that merely *printed* a footer and then kept rendering. Independent of both halves, a line that starts with a transcript/status glyph (`❯ ✻ ⎿ ⏸ • ▎ > $ # %` or a bare `<n>. `) is fatal wherever it appears in the tail — that is the composer prompt, the spinner and the shell prompt, i.e. proof the block is *not* the last real content. **`●` (U+25CF) is deliberately absent from that set**: it opens the `/model` effort line in its default state, so treating it as fatal is a guaranteed false *negative* on `/model`. Dropping it costs no coverage — a real transcript tail that carries a `● Read(file)` tool line always also ends in `❯` (composer), `✻` (spinner) or `⏸` (status line), each fatal on its own, and a `●` line *after* the footer is already killed by the zero-tolerance post-footer rule. The option block must be the last real content of the pane, which is exactly what a modal dialog is and what a transcript/composer never is. Chrome is skipped instead of rejected on purpose: the old rule (`≥ 8 ─` and no `│`) also matched the `╭───╮`/`╰───╯` of a **boxed** dialog and would turn a real prompt into a false negative. Cost of the trade: an agent that draws a *footerless* menu reads as `asking:false` and has to be answered from a real terminal — accepted, because a false negative wastes a trip and a false positive answers for you.
  - The block does **not** have to be physically contiguous: the phone drives the pane width (`/term/resize`), so at 60–80 columns tmux wraps long labels onto continuation lines and pads between options. Consecutive option lines are chained while their indices descend by exactly 1 and they are at most `GEO_AGENT_ASK_OPTION_GAP` (6) lines apart; everything in between (wrap continuations, border-only pad lines) is ignored. Consequence: a wrapped `label` is **truncated at the pane width** — clients should answer by `index`, not by `option` label.
  - `asking:true` requires **≥ 2** options, indices exactly `1..n` in order, **and exactly one cursor** in the block. The cursor is the load-bearing signal: without it a numbered list in ordinary agent output would read as a prompt, and with two of them it is not a single-select TUI at all. Both cases are reported as `asking:false` — a false negative is preferred over answering something that was never a question.
  - `question` = the nearest non-empty line above the block (within 5 lines) **that ends in `?`**, capped at 240 chars; `""` when there is none. `selected` mirrors the cursor. `label` is capped at 120 chars, `raw_hint` (question + option lines, verbatim modulo trimming) at 1200.
  - `kind` is `"permission"` when question/labels match `proceed|permission|allow|trust|do you want|prosseguir|permit`, else `"choice"`; `""` only when `asking:false`.
- Codes: `200` · `400 bad_target` · `404 no_session` · `404 no_agent` · `503 {"error":"unavailable"}` when the capture failed, timed out or tmux is missing. **A read failure is `503`, never `asking:false`** — the invariant of the whole bridge: "could not find out" ≠ "not asking".

### POST /term/agent-answer

Answers the question `/term/agent-ask` detected. Same two mutually-exclusive selectors as `/term/agent-ask` — `?session=` (VM) or `?project=&pane=` (Mac); absent, malformed, or mixed → `400 {"error":"bad_target"}`. (v5: the Mac path used to be `400 bad_target` because `/term/agent-ask` never reported a question there.)

- Body: JSON, ≤ 1024 bytes, **exactly one** of `{"index": <int>}` (1-based) or `{"option": "<label>"}` (case-insensitive exact match of the label). Both, neither, a non-object, a bool `index`, an empty `option`, an unreadable body → `400 {"error":"invalid_body"}`.
- **What is written to the pty is only the digit + Enter** (`b"1"`, 50 ms pause, `b"\r"`), through the same durable attach `/term/input` and `/term/agent-prompt` use. In Claude Code's permission dialog the digit alone already selects **and** submits — the `\r` is a defensive no-op for TUIs that require confirmation, and lands in whatever the agent renders next (in practice an empty composer, where it is a bare Enter). It is not required by Claude Code. No arrows, no `Esc`, no escape sequence — the digit is inside the vocabulary `/term/agent-prompt` already allows, which is exactly why this verb exists instead of a loosened control-byte policy.
- Consequence of "digit only": options above **9** are not answerable (typing `10` would select `1` then `0`) → `400 {"error":"bad_option"}`. Same code for an index outside the currently detected range and for a label that matches nothing.
- **The pane is re-read immediately before writing** and the choice is validated against *that* snapshot, so an index computed from a stale `/term/agent-ask` cannot answer a different question. The race window is not zero: between this capture and the write (~ms) the TUI can still change. `200` therefore means "the digit was delivered to the pty", never "the option you named was selected" — the client must re-poll `/term/agent-ask`/`/term/agent-chat` to confirm.
- **Mac path**: identical contract, different channel — the re-read is the same `herdr pane read` as `/term/agent-ask`, and the write is `herdr pane send-text <pane> <digit> && herdr pane send-keys <pane> enter` in **one** ssh (chained with `&&`, so a failed `send-text` never leaves a bare Enter behind). `send-text` is literal text, not a key sequence, and every fragment is `shlex.quote`d. Consequences of the shared parser apply unchanged, including the `statusLine` false negative documented above: a Mac dialog the parser cannot see answers `409 not_asking` and must be handled from the terminal. `404 no_session` does not exist here; a missing agent is `404 no_agent`, an unreachable Mac or a non-zero herdr exit is `503`.
- Codes: `200 {"ok":true,"index":<n>}` · `400 bad_target` / `invalid_body` / `bad_option` · `404 no_session` (VM) / `404 no_agent` · `409 {"error":"not_asking"}` when the fresh capture shows no question (nothing is written) · `409 {"error":"no_attach"}` if the pty write itself failed (VM) · `503 {"error":"unavailable"}` when the lookup/capture/send blew up.

### POST /term/agent-interrupt

Interrupts the agent. No body.

- Same two mutually-exclusive selectors as `/term/agent-ask` — `?session=` (VM) or `?project=&pane=` (Mac); anything else → `400 {"error":"bad_target"}`. (v5: the Mac path used to be `400 bad_target`.)
- **The key is `Escape`, sent as `tmux send-keys -t '=<session>:' Escape`** — a tmux *key name*, so the byte never travels in a request body and never meets the control-character filter of `/term/agent-prompt`. **Why `Escape` and not `C-c`**: in Claude Code `Esc` interrupts the current turn and keeps the session alive, while `Ctrl-C` (twice) kills the process and loses the context — the phone's "parar" button must be the recoverable one. `GEO_AGENT_INTERRUPT_KEY` exists for agents that expect otherwise; changing it is a deliberate act.
- **The gate reads the same pane the key reaches.** `send-keys -t '=<session>:'` (and the pty write of `/term/agent-answer`, `/term/agent-prompt`, `/term/agent-start`, and the `capture-pane` of `/term/agent-ask`) always lands on the window's **active** pane, but the agent detection used to accept *any* pane of the window: a split with a shell active and the agent in the sibling pane passed the gate and sent `Escape` to the shell — reproducing the very `odex: command not found` this section calls impossible. The detection therefore only ever considers the pane with `#{pane_active}` = `1`. Consequence: an agent running in a non-active pane is `404 no_agent` for the whole `/term/agent-*` family — honest, since none of those verbs can talk to it.
- **An agent must be running**: the same local detection as `/term/agent-chat` runs first → `404 no_session` / `404 no_agent` / `503`. `Esc` is **not** inert in a bare shell: in interactive bash and zsh it opens a meta/vi-command sequence that swallows the next character, so an interrupt on a shell-backed pane followed by `/term/agent-start` produced `odex: command not found` (ESC ate the leading `c`, ESC+c = `capitalize-word`) with both calls reporting success. Refusing to send the key when there is no agent to interrupt is the fix; the phone's "parar" is only offered where there is something to stop.
- **Mac path**: one ssh running `herdr --session <project> pane send-keys <pane> esc` — a herdr **logical key name**, so exactly like the tmux path the byte never travels in a request body and never meets the control-character filter. Same gate first (the memoized `/term/agents` resolution → `404 no_agent` / `503`), for the same reason: `Esc` into a bare shell is not inert. `GEO_AGENT_INTERRUPT_KEY_MAC` exists because herdr's spelling (`esc`) is not tmux's (`Escape`).
- **`200 {"ok":true}` means the key was delivered to tmux/herdr, not that the agent stopped.** There is no acknowledgement from a TUI; the client confirms by polling (`/term/agent-chat`, `/term/agent-work`).
- Codes: `200` · `400 bad_target` · `404 {"error":"no_session"}` (VM) · `404 {"error":"no_agent"}` · `503 {"error":"unavailable"}` when tmux/herdr is missing, timed out, or `send-keys` failed.

### POST /term/agent-start

Starts an agent in a tmux session that currently runs only a shell.

- `?session=` **required** (VM only) → `400 {"error":"bad_target"}`.
- Body: JSON `{"agent":"claude"|"pi"|"codex"}` — a **closed vocabulary**, never a command line. Any other value → `400 {"error":"bad_agent"}`; a non-object/unparseable/oversized body → `400 {"error":"invalid_body"}`. Commands are fixed in the bridge: `claude` → `~/.local/bin/claude`, `pi` → `/usr/bin/pi`, `codex` → `codex`. The client can never influence the string that is typed.
- **Preconditions, in order**: the session must exist (`404 {"error":"no_session"}`) and must **not** already run an agent — same local detection as `/term/agent-chat` (pane command, then descendants up to `GEO_AGENT_VM_DEPTH`) → `409 {"error":"already_running"}`, nothing typed. Two phones racing can still both pass the check; the second one types into a session that is already booting an agent (visible in `/term/stream`), which is why the check is documented as a guard, not a lock.
- The command is written to the session's pty (durable attach), then `\r` after 50 ms — same path and same guarantee as `/term/agent-prompt` on the VM.
- Codes: `200 {"ok":true,"agent":"claude"}` — **the command was typed**, not "the agent is up" (a missing binary shows up as a shell error inside the terminal stream) · `400 bad_target` / `invalid_body` / `bad_agent` · `404 no_session` · `409 already_running` / `no_attach` · `503 {"error":"unavailable"}`.

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

### GET /term/agent-commands

The `/` menu of the chat composer: which slash commands **that** agent can actually run, so the phone offers a list instead of the user typing from memory.

- Auth: the terminal token (`_term_gate`). Main bridge token → `401`. Terminal disabled → `404`.
- Params — **either** the `project`/`pane` pair (Mac) **or** `?session=` (VM), never both, exactly like `/term/agent-chat`, `/term/agent-ask` and `/term/agent-work`; same anchored regexes (`\A[A-Za-z0-9_-]{1,24}\Z`, `\Aw[0-9]{1,3}:p[0-9]{1,3}\Z`, `\A[A-Za-z0-9_-]{1,32}\Z`, never `$`). Anything else → `400 {"error":"bad_target"}` and no ssh happens. This endpoint was the only member of the family without the VM branch: `?session=` answered `400 bad_target`, the app swallowed it, and the `/` menu of a VM session came up **empty — `/clear` and `/compact` never reached the VM at all**.

```json
{"agent":"claude","commands":[
  {"name":"g-omni","description":"Conduz qualquer tarefa não-trivial…","scope":"user"},
  {"name":"soltar","description":"comando de projeto","scope":"project"}
]}
```

- **VM path (`?session=`)**: the agent and its `cwd` come from the same local active-pane detection as `/term/agent-chat` (`404 no_session` / `404 no_agent` / `503`), the identical skill script runs **locally** (`/bin/sh -c`, no ssh) under its own cache key `("vm", session, agent, cwd)`, and the built-ins are merged the same way. An agent with no known skill layout (codex) still gets `200` with its built-ins (none declared → `[]`) — nothing is invented, and a failed local scan is `503`, never an empty list.
- **Resolution** on the Mac path costs zero extra ssh: same memoized scan as `/term/agents` (`host=="mac"` + exact `project` + exact `pane`). No agent in a pane that exists → `409 {"error":"no_agent_in_pane"}`; pane not in the scan at all → `404 {"error":"no_agent"}`; scan failed → `503`.
- **`cwd` comes from the scan, never from the client.** There is no `cwd` param and none would be honoured: the project scope is rooted at the `cwd` herdr reported for that pane, `shlex.quote`d.
- **Sources** (one single ssh, whatever the agent):
  - `claude` — `$HOME/.claude/skills/*/SKILL.md` (`scope:"user"`), plus `<cwd>/.claude/skills/*/SKILL.md` and `<cwd>/.claude/commands/*.md` (`scope:"project"`). This Mac has **no** `~/.claude/commands/`; the user-level slash commands *are* the skills.
  - `pi` — `$HOME/.pi/agent/skills/*/SKILL.md` and `$HOME/.pi/agent/skills/*.md` (`scope:"user"`), **plus `GEO_AGENT_PI_SKILLS_DIR` (default `/mnt/garime/pi/skills`)** with the same two patterns. On the VM the pi agent's home is not where its skills live — `$HOME/.pi/agent/skills` does not exist there and globbing only it returned `commands: []` for every VM pi session, the exact hole the endpoint's VM branch was added to close. The same asymmetry is already handled for transcripts by `GEO_AGENT_PI_SESSIONS_DIR`. Both roots are globbed unconditionally on both paths (`[ -d ]`-guarded, an absent root is not an error) and duplicates collapse by `name`.
  - Any other agent (prime-agent, codex, kimi, opencode…) → `200` with `commands: []`, **no ssh at all**. Not knowing an agent's skill layout is not an error.
- **`name`** = the skill directory's name, or the `.md` file's basename without the extension. It is re-validated on the VM against `\A[A-Za-z0-9._-]{1,64}\Z` (and never `.`/`..`); a directory whose name carries shell metacharacters is dropped from the list rather than shipped to the phone.
- **`description`** = the first `description:` line of the frontmatter, trimmed and **truncated to 160 characters** (the payload travels on 4G). No description, empty directory, no frontmatter at all → `""`, never an error and never a missing key.
- **The `SKILL.md` bodies never cross the network.** The remote side lists the files with the shell's `printf` builtin and extracts descriptions with **one** `awk` over the whole list, which stops at line `GEO_AGENT_COMMANDS_HEAD_LINES` (12) of each file and emits at most 400 bytes per description. A 400 KB skill costs the same handful of bytes as a 400 B one (proven in the smoke: 400 048 B on disk → 2 261 B on the wire for the whole list). A `description:` further down than line 12 is reported as `""` on purpose — that is the price of the cheap read.
- **Built-ins are added by the bridge.** `/clear` and `/compact` are commands of Claude Code itself, not skills — nothing on disk lists them, so scanning could never find them and the phone had no way to offer them. For `agent == "claude"` the bridge appends two synthetic entries `{"name":"clear"|"compact","description":"…","scope":"builtin","builtin":true}`. The **`builtin` key exists only on those entries** and `scope:"builtin"` is a new value of an existing field, so a client that reads `name`/`description`/`scope` keeps working unchanged; a client that wants to group them reads `builtin`. A skill with the same name is dropped in favour of the built-in (in Claude Code the built-in is what `/clear` actually runs). Built-ins are merged **after** the cache, so the list can change without invalidating any memoized scan, and they cost no ssh. No other agent has built-ins declared — inventing them for `pi`/`codex` would be guessing.
- **Ordering and precedence**: alphabetical by `name`, built-ins included in the same ordering. If the same name exists in both scopes, **`project` wins and the entry appears once** (more specific overrides; no duplicates).
- **The remote side never runs under the Mac's login shell.** ssh hands the command to the login shell, which on this Mac is `/bin/zsh`, where an unmatched glob is a **fatal** error (`NOMATCH` is on even for `zsh -c`) that would abort the listing before it printed anything — and no project here has `.claude/skills`, `.claude/commands` nor a loose `~/.pi/agent/skills/*.md`, so that is the normal case, not the exception. The listing is therefore always wrapped as `/bin/sh -c '<script>'` (single argument, `shlex.quote`d), and POSIX `sh` passes an unmatched pattern through as a literal word that `[ -f "$f" ]` discards. Each glob is additionally guarded by `[ -d ]` on its directory.
- **"Empty" is proven, never assumed.** The script does not force `exit 0`. It fails loudly instead: no `$HOME` → `6`, a skills directory that exists but is not readable/searchable → `7`, `awk` missing or unable to read a file → `8`; and when it does reach the end it prints a final `Z` line. The VM only accepts the result when the ssh exit code is `0` **and** the last output line is `Z`; anything else is `503 unavailable`. A remote error can therefore never be rendered as `commands: []`.
- **Cache**: own cache keyed by `(project, pane, agent, cwd)` with TTL `GEO_AGENT_COMMANDS_TTL` (120 s), much longer than the 10 s agent scan. Serialization is **per key**, not global: two concurrent calls for the same pane = **one** ssh, while a slow pane never blocks another pane's list. The cache (and its lock table) is bounded to `GEO_AGENT_COMMANDS_CACHE_MAX` (64) entries, oldest evicted first — `cwd` is part of the key and changes on every `cd`, so it must not grow forever. Only successes are cached; a failure is never memoized as an empty list.
- Codes: `200` (list, possibly empty) · `400 bad_target` · `404 no_agent` · `409 no_agent_in_pane` · `503 {"error":"unavailable"}` when the scan or the skills ssh failed/timed out. As everywhere in `/term/*`, `503` means "we could not find out" and is **not** the same as an empty list — the client must not blank the menu on it.

### GET /term/agent-work

What one Mac agent is doing **in parallel right now**: its workflows and its direct sub-agents, as counts and metadata. The phone renders "2 rodando / 6 prontos" without opening a PTY and without downloading a single byte of transcript.

- Auth: the terminal token (`_term_gate`). Params `project`/`pane` validated by the same anchored regexes as everywhere else in `/term/*` → `400 {"error":"bad_target"}` before any ssh. Resolution is the same memoized `agent list` scan (`404 no_agent` / `409 no_agent_in_pane` / `503 unavailable`).

```json
{"agent":"claude","supported":true,"resolved":"reported",
 "workflows":[{"id":"wf_12ec19ba-56f","running":2,"done":6,"since":"2026-08-05T13:22:31Z","stale":false}],
 "subagents":[{"id":"a1b5a89ea","type":"worker","running":true,"since":"2026-08-05T13:40:02Z"}],
 "truncated":false}
```

- **Where the truth lives** — the same session id `/term/agent-chat` uses (`agent_session` `kind:"id"`), resolved to `$HOME/.claude/projects/<dir>/<session-id>/subagents/`. The project dir of the pane's own `cwd` is tried **first** (`<cwd-encoded>/<session-id>/`); only if that directory does not exist is the id looked up by name across project dirs, and then only a match that already carries a `subagents/` tree counts. Inside it: `agent-<id>.jsonl` + `agent-<id>.meta.json` for **direct** sub-agents, and `workflows/wf_<id>/journal.jsonl` for each workflow.
- **The answer is scoped to the queried session, never to its neighbours.** There is **no newest-`*.jsonl` fallback on the reported-id path** — several agents share one `cwd`, so the newest transcript of a project dir routinely belongs to *another* session, and using it made one agent's strip show every agent's workflows (reproduced on real data: session `3d18a72b…` was served the two workflows of `53f957b9…`). When the id resolves to no session directory the script does not guess: if `<session-id>.jsonl` exists anywhere under `~/.claude/projects` the session is **proven** to exist with no work tree → `200` with empty lists; if not even that exists the id is unresolvable → exit `9` → `503 {"error":"unavailable"}`. A stale id (Claude Code rotates it on resume/compaction) therefore reads as "sem conexão", never as another session's counts.
- **`resolved`**: `"reported"` (herdr's id — the only value the `project`+`pane` path can produce now), `"fallback"` (the `cwd`/VM path, where no id exists and the newest transcript of that one project dir names the session dir), `""` (nothing resolved — `supported:false`, or no subagents tree). Always present.
- **`supported:false` means "this shape of agent has no parallel-work tree we can read"** — a non-claude agent (pi keeps only `~/.pi/agent/sessions/**.jsonl`, with no sub-agent directory), or a claude agent herdr reported without an id-shaped session. It is always `200` with empty lists and **no ssh at all**; the client must render "não disponível", not an empty work list.
- **Workflow counts come from the journal, not from guesses**: `running` = `started` events whose `agentId` has no matching `result`; `done` = those that have one. A `result` without its `started` counts as neither. Unparseable/foreign lines are skipped.
- **An interrupted workflow does not count as running forever.** A killed run leaves `started` with no `result`, which would read as "rodando" until the directory is deleted. Cut by age: if the workflow has shown **no activity at all** for `GEO_AGENT_WORK_STALE_AFTER` (3600 s), its `running` is reported as `0` and `stale:true` is set (additive field; a workflow already fully `done` is never flagged). "Activity" is `max(mtime journal.jsonl, newest mtime of the wf dir's own `agent-*.jsonl`)` — the journal is only touched on `started`/`result`, so while a sub-agent works the journal is silent and the transcript is the live signal. Using the journal alone would cut workflows that are demonstrably progressing. That same max is the `since` of the row.
- **The journal never crosses the network.** A `result` line carries the sub-agent's whole answer (kilobytes each); the aggregation runs **on the Mac** in `awk`, which only ever looks at the first 400 bytes of each line (enough for `type` and `agentId`, which are the first keys) and prints two integers. A real session with a 4-step workflow costs **86 bytes** on the wire.
- **"Running" for a direct sub-agent is a heuristic, and it is documented as one**: `running:true` iff its `agent-<id>.jsonl` was modified in the last `GEO_AGENT_WORK_RUNNING_WINDOW` seconds (120), measured against the **Mac's own clock** (the script emits `date -u +%s` in the same call, so VM/Mac clock skew cannot affect it). There is no end-of-transcript marker in those files to key off — the last record of a finished sub-agent is an ordinary `assistant`/`tool_result` line. Margin of error, both directions:
  - a sub-agent that finished less than 120 s ago still reads `running:true` (false positive, self-corrects on the next poll);
  - a live sub-agent blocked >120 s on one long tool call (a slow build, a big download) reads `running:false` (false negative).
  The window is the knob: shorter = fewer stale "rodando", more flapping on slow steps.
  **Corroborated by a live process when that is possible.** Before the `find`s, the script emits `L\t<alive|unknown|dead>` from one `ps -Ao pid=,ppid=,args=`, ignoring its own process chain (`$$`/`$PPID`, and any line carrying the script's own `subagents` text). `dead` is emitted **only** when `ps` produced output and *no* process on the host looks like claude at all — a host with no claude cannot be running a sub-agent, so every sub-agent is `running:false` regardless of mtime. Deliberately **not** keyed on the resolved session id: Claude Code rotates the id in `--resume` (that rotation is why the fallback exists), so "the id is not in the args" would say `dead` about a live agent — a false negative, worse than the mtime's false positive. `ps` missing, failing or silent → `unknown`, and an absent/unrecognised `L` line parses as `unknown`; `alive` and `unknown` both leave the mtime window as the only signal. Uncertainty is never converted into "nothing running". **Workflow counts are not affected by any of this** — they come from real events, so a workflow's `running` is exact.
- **`since`** is the mtime of the file the row is derived from (for a workflow, the newest of `journal.jsonl` and the wf dir's `agent-*.jsonl`; `agent-<id>.jsonl` for a sub-agent — the `.meta.json` when the transcript is missing), ISO-8601 UTC to the second. It answers "since when has this been in this state", not "when did it start".
- **Ordering and caps**: newest first by that same mtime. At most `GEO_AGENT_WORK_WORKFLOWS_MAX` (10) workflows and `GEO_AGENT_WORK_SUBAGENTS_MAX` (20) sub-agents; if either list was cut, the top-level `truncated` is `true` (it is a single flag for the whole payload). The remote script itself stops at `GEO_AGENT_WORK_SCAN_MAX` (200) of each kind, so a pathological session cannot produce an unbounded response either.
- **zsh-safe by construction.** The Mac's login shell is `zsh`, where an unmatched glob is a **fatal** error that aborts the whole command — this class of bug already shipped once here. Directory and file discovery is `find -mindepth/-maxdepth ... 2>/dev/null`; the one glob in the script (the fallback's `ls -1t "$d"/*.jsonl`) is guarded by `2>/dev/null` **and** by the `/bin/sh -c '<script>'` wrapper the whole thing runs inside, so an unmatched glob degrades to an empty string instead of aborting. It is smoke-tested end to end under **both** `zsh -c` and `sh -c` with byte-identical results, including a session whose `subagents/` has neither `workflows/` nor any `agent-*` file.
- **Locale-proof, and empty is never assumed.** Every `awk` runs under `LC_ALL=C`: a journal carrying one non-UTF-8 byte makes a UTF-8-locale `awk` abort with `towc: multibyte conversion failure` (rc `2`) — 9.6% of real journals here, 8 sessions losing *all* their workflows — and the aggregation only ever needs bytes, never characters. The locale is not ours to control (it arrives through sshd `AcceptEnv LANG LC_*`, and the local VM path inherits the environment), so the endpoint refuses to depend on it. Paired with that: a workflow that **exists on disk but could not be read** is an error, not an absence — an unreadable `subagents/`, `workflows/` or `wf_*/` directory and a failing `stat` exit `7`, a failing/silent `awk` exits `8` (the `/term/agent-commands` convention), both surfacing as `503`. Only a *proven* empty tree is `200` with empty lists.
- **Completion marker**, like `/term/agent-commands`: the script's last line is `Z`. The VM accepts the answer only when the ssh exit code is `0` **and** that line is present; a truncated or failed run can never be rendered as "no parallel work".
- **Cache**: own cache keyed by `(project, pane, session-id, cwd)` — `cwd` is part of the key because it is what scopes the fallback, so a pane that moved cannot serve another project's snapshot — TTL `GEO_AGENT_WORK_TTL` (5 s) — short on purpose, this is the fastest-moving state here. Serialization is **per key**: two concurrent polls of the same pane = **one** ssh (proven in the smoke), while a slow pane never blocks another. Bounded to `GEO_AGENT_WORK_CACHE_MAX` (64) entries, oldest evicted. Only successes are cached; a failure is never memoized as "nothing running".
- Codes: `200` (possibly empty lists — a session that never spawned anything is **not** an error) · `400 bad_target` · `404 no_agent` · `409 no_agent_in_pane` · `503 {"error":"unavailable"}` when the scan or the work ssh failed/timed out, when part of the tree exists but is unreadable (`7`/`8`), or when the reported id matches nothing on disk (`9`). `503` means **"we could not find out"** and is never collapsed into `200` with empty lists: the client must show "sem conexão", never "nada rodando".

#### VM agents — `?session=<tmux-session>`

Same selector rules, same local detection, same `404 no_session` / `404 no_agent` as `/term/agent-chat`. For a **claude** agent on the VM the sub-agent tree sits exactly where it does on the Mac — next to the transcript, `$HOME/.claude/projects/<cwd-dir>/<session-id>/subagents/` — so the same script, the same `awk` aggregation, the same `Z` completion marker and the same parser are reused, run locally instead of over ssh. Since there is no reported session id, only the `cwd` branch exists: the newest `*.jsonl` of that project dir names the session directory, and `resolved` is therefore **always `"fallback"`** (`""` when no such directory exists). Any other agent (pi included) → `supported:false`, `200`, empty lists, and **no script at all**. Cache key is `("vm", <session>, <agent>, <cwd>)`, sharing the `/term/agent-work` cache, its TTL and its per-key serialization.

### POST /term/agent-upload

Sends a photo/file **to the Mac where the agent runs** (not to the VM), so the phone can then cite the path in a prompt. Sibling of `/term/upload`, same rigor, different destination host. **It never executes anything and never sets the executable bit.**

- Auth: the terminal token (`_term_gate`). Params `project`/`pane` exactly as above → `400 {"error":"bad_target"}`.
- Request body: the **raw bytes** of the file (not base64, not multipart). Header `X-Geo-Filename` carries the desired basename.
- **Filename validation identical to `/term/upload`**: `\A[A-Za-z0-9._-]{1,80}\Z` (anchored — a trailing `\n`, including one smuggled in by an obs-fold header, is rejected), must equal its own `os.path.basename`, must not start with `.`. So `../../etc/x`, `a/b.png`, `.bashrc`, `..`, the empty name and any name with `$`/backticks/quotes → `400 {"error":"invalid_filename"}`, **before any ssh**. There is no sanitizing rewrite.
- Size cap **32 MiB** (33554432 bytes) from `Content-Length` → `413 {"error":"too_large"}` (refused before the body is read). Missing/zero/unparseable length, or a body shorter than announced → `400 {"error":"invalid_body"}`.
- **Resolution before transfer** (after the `400`s, so malformed input costs no scan): the same memoized lookup — `404 no_agent`, `409 no_agent_in_pane`, `503 unavailable`.
- **Transfer**: the bytes go through the **stdin** of the ssh into a remote `cat`; file content is never interpolated into a command line. The local argv is a list, never `shell=True`, and every interpolated fragment of the remote script (inbox name, filename, stem, extension) is `shlex.quote`d — a name/content carrying `'; rm -rf …; $(id)` and backticks is inert (proven in the smoke against a sentinel that survives).
- **Destination** is fixed: `$HOME/<GEO_AGENT_UPLOAD_DIR>` (`~/garime-uploads`) on the Mac, `mkdir -p` under `umask 077` → the dir is `0700` and the file `0600`.
- **Collision**: `nome.txt`, `nome-1.txt`, `nome-2.txt`, … Existing files are never overwritten (>1000 collisions → the remote script exits non-zero → `503`).
- **No symlink following, no overwrite** — with the limitation that POSIX `sh` has no `O_NOFOLLOW`: the guarantee is built from `[ -e "$p" ] || [ -L "$p" ]` (the `-L` also catches a **dangling** symlink that `-e` misses) plus `set -C` (noclobber), which opens with `O_CREAT|O_EXCL`. `O_EXCL` fails with `EEXIST` when the path is a symlink *regardless of its target*, so the symlink is never followed and nothing existing is ever truncated. What this is not: an atomic `O_NOFOLLOW` on the same descriptor — a symlink created between the test and the redirect still ends in a failed open (`503`), never in a followed write.
- Success → `200 {"path":"/Users/<user>/garime-uploads/<final-name>"}` — the **final** name after collision handling, validated against `\A/[^\x00-\x1f]{1,500}\Z` before being echoed. The client cites that path in the next `/term/agent-prompt`; running anything with it is the user's decision.
- `503 {"error":"unavailable"}` — Mac unreachable at either step, ssh timeout, or the remote script failed (`mkdir`, collision ceiling, write error). Nothing landed, or we cannot tell: the client must not assume the file exists.
- **The body is never logged** (only method+path reach the log, like `/term/input`, `/term/upload` and `/term/agent-prompt`). The connection is closed after the response.

## Agent-ask watcher → WhatsApp (added in v5)

A daemon thread inside the bridge that answers the one question the API cannot: *the owner is not looking at the app, and an agent just stopped to ask something.* It turns that into a WhatsApp message.

**Off by default.** `GEO_AGENT_WATCH=1` arms it; without it `agent_watch_start()` returns before the thread exists (no thread, no tick, no file). A watcher that came up armed on a deploy would be an unrequested WhatsApp burst.

- **Channel — the file outbox, not a new integration.** `garime-wa.service` (`/mnt/garime/pi/wa-bot/bot.js`) drains `*.txt` from `GEO_WA_OUTBOX` (`/mnt/garime/pi/wa-outbox`), posts the content to the group and unlinks the file. The bridge only writes files; it never opens a Baileys session (which would fight the bot for the WhatsApp connection). The dir already exists and is owned by `biel`, the user the bridge runs as.
- **Writes are atomic**: the payload goes to `<name>.txt.tmp` **in the same directory** (fsync'd), then `os.rename` into place. Rename within a filesystem is atomic, so the bot never reads a half-written message — and `*.txt.tmp` does not match the bot's `*.txt` glob, so the temp file is invisible to it even mid-write.
- **Filename**: `agent-ask-<epoch>-<session>-<key>.txt`. Epoch first so lexicographic order = chronological order (the bot's own drain order). `<key>` is `sha256` of the merged question+labels observation, 16 hex, present so two notifications landing in the same second cannot overwrite each other.
- **Message** (short and actionable — WhatsApp, not a log):

```
🤖 claude (grill-claude) precisa de você:

"Do you want to proceed?"
1. Yes
2. No

Responda pelo app garime.
```

  The question line is omitted when the parser found none (a menu with no `?` line above it); options are capped at `AGENT_ASK_MAX_OPTIONS` (9), the same ceiling `/term/agent-answer` can act on, and each label at 80 chars. The `.txt` is posted by the bot to a **WhatsApp group**, so the message carries only the question and the option labels — never the raw pane, never `raw_hint`, never the transcript above the dialog. On top of that, every whitespace-delimited token containing `/` is replaced by `…` in both the question and the labels (`AGENT_WATCH_PATH_RE`), because Claude Code writes absolute paths into permission labels (`2. Yes, and don't ask again for rm commands in /Users/biel/Omni`) and URLs into web-fetch ones. What survives is what makes the message actionable; what leaks the machine's layout does not. The scrub is cosmetic-only — the dedupe fingerprint is computed on the **unscrubbed** text.

- **VM only.** Enumeration is exactly what `/term/agents` does — `status_vm_agents()` → the tmux session of every live agent process — filtered through the same `\A[A-Za-z0-9_-]{1,32}\Z` name regex, then `vm_session_agent()` (active pane only) and `agent_ask_capture()` + `agent_ask_parse()`: **the same single detector `/term/agent-ask` uses**, not a copy. Mac panes are out of scope: watching them costs an ssh per tick per pane and the parser under-reports there (see the `statusLine` note above).
- **Reflow-proof fingerprint.** The remembered state per session is not a hash but the observation itself: `{question, labels}`, whitespace-collapsed and lowercased. Two observations are **the same dialog** when they have the same number of options, each label pair is prefix-compatible (one is a prefix of the other), and the questions are suffix-compatible. That tolerance is not cosmetic: `agent_ask_parse` takes each label from **one physical row**, so a narrower pane silently truncates it, and the question, when it wraps, is found by its last row. The pane width is not stable — `/term/attach` + `/term/resize` reflow the tmux window to the phone's width (commonly 40–60 cols) and `TERM_IDLE_SECONDS` puts it back — so an exact hash of the parsed text made one unanswered dialog notify on every attach/detach cycle. The stored observation is **merged** with each new one (longest wins per field), so the record only gets richer. Below `GEO_AGENT_WATCH_MIN_COLS` (40 cols) the parse is not trusted at all: the tick reads `#{pane_width}` first and skips the session, which is why a phone attached to a blocked agent neither re-notifies nor falsely clears.
- **Edge, not level.** A notification fires only when the observed dialog **changes**: the same dialog sitting there for an hour notifies once; changing the question is a new event; leaving the asking state clears the key, so the *same* question asked again later is a new event too. **A confirmed `asking:false` is the only thing that clears** — a failed capture, a `None` capture, *or an agent that merely disappeared from the enumeration* leave the state untouched. Absence from the scan is a "could not find out", not a "not asking": `vm_pid_sessions()` swallowing a `tmux list-panes` timeout returns `{}`, which makes `status_vm_agents()` report the live agent with `session: ""`, and a `ps -eo` timeout empties the list wholesale — clearing on absence would re-notify an unanswered dialog after any transient hiccup.
- **State survives the process.** The three maps (seen observations, per-session last-sent, hourly ledger) are persisted as JSON in `GEO_AGENT_WATCH_STATE` (`~/.garime/agent-watch.json`), written with the same tmp+`os.rename` atomicity and re-read on the first tick. Without this, the unit's `Restart=always` / `RestartSec=2` turns any crash loop or deploy performed while an agent is blocked into one identical WhatsApp every 2 s: the brakes are per-process, and the bot dedupes by `path:size:mtime`, so N files = N messages. Timestamps are wall clock (`time.time()`) precisely so they stay meaningful across a restart. If the state file cannot be written the failure is logged (`state save failed`) and the watcher keeps running — degraded to the old, re-notifying behaviour, never dead.
- **Anti-flood, drop-never-queue.** Two independent brakes: (1) per session, at most one notification per `GEO_AGENT_WATCH_COOLDOWN` (300 s); (2) globally, at most `GEO_AGENT_WATCH_MAX_HOUR` (12) notifications per sliding hour. Both log and drop, and the state key is burned on a drop, so a suppressed event is genuinely discarded and cannot re-fire on the next tick. **A failed outbox write is not a drop**: the key is *not* burned, so the alert is retried on the next tick instead of being lost — `GEO_WA_OUTBOX` lives under the LUKS mount `/mnt/garime`, so "bridge up before the outbox exists" is the ordinary boot order and everything asked in that window would otherwise be swallowed for good. A write that fails after `open()` unlinks its own `.txt.tmp`.
- **It cannot take the bridge down.** Every tick is wrapped: a raised tick is caught and logged, a per-session tmux/read failure is caught and skips that session only, an `OSError` writing to the outbox is caught and logged. A **missing outbox directory is logged once at startup and the thread still starts** — the mount may appear later; each write then fails as an ordinary logged `OSError` and the pending alert is retried once the mount is there.
- **Log**: appended to `~/Library/Logs/geobridge.log` (same file, same lock as the request log), lines shaped `<iso> watch <session> notified|dropped cooldown|dropped hourly cap|capture failed|outbox failed|skipped narrow pane` plus `state load failed|state save failed`.
- **Memory is bounded**: seen observations expire `GEO_AGENT_WATCH_SEEN_TTL` (24 h) after they were last observed — not on absence from the scan — the cooldown map drops entries older than the cooldown, and the hourly ledger keeps only the last hour.

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

All bridge-originated errors: `{"error":"<snake_case_code>"}` with the appropriate status (`400` invalid_id/invalid_body/bad_target/bad_option/bad_agent, `401` unauthorized, `404` not_found/no_agent/no_session, `409` task_exists/no_attach/not_asking/already_running, `502` hermes_unreachable, `503` unavailable, `500` internal). Proxied hermes errors pass through untouched.

`503 {"error":"unavailable"}` exists only on `/term/agent-chat`, `/term/agent-prompt`, `/term/agent-work`, `/term/agent-commands`, `/term/agent-ask`, `/term/agent-answer`, `/term/agent-interrupt` and `/term/agent-start` and means **the bridge could not find out** — over ssh on the Mac path (host unreachable, timeout, no herdr), locally on the VM `?session=` path (no tmux binary, `tmux`/`ps` timeout, transcript script non-zero). It is never interchangeable with an empty `200`. Every other route keeps its historical behaviour of degrading silently to empty/false.

`404 {"error":"no_session"}` is exclusive to the VM `?session=` path and means the tmux session does not exist; `404 {"error":"no_agent"}` there means it exists but runs no agent.
