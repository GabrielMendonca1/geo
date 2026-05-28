# claude-code-lane

Spawn and manage Claude Code (`claude` CLI) instances as Hermes kanban workers.

Hermes is the 24/7 orchestrator; Claude Code is the worker pool. Hermes (or you, from the kanban CLI) creates a card with `assignee=claude-code` pointing at a directory; the lane daemon claims it and runs `claude -p ...` in that directory, streaming events back into the kanban event log. Multiple parallel runs supported.

## Components

| Piece | Path | Role |
|---|---|---|
| MCP tool | `__init__.py` → `~/.hermes/plugins/claude-code-lane/` | Registers `claude_code_run(directory, prompt, model?, max_runtime_seconds?, title?)` for Hermes to call from its chat loop. |
| Daemon | `daemon.py` → `~/.hermes/plugins/claude-code-lane/daemon.py` | LaunchAgent. Polls `~/.hermes/kanban.db` every 5s for `assignee='claude-code' AND status='ready'`, claims via `kb.claim_task`, spawns `claude -p --output-format stream-json` in the workspace dir, streams events into `task_events`, heartbeats, marks done/blocked on the final result event. |
| LaunchAgent | `ai.hermes.claude-code-lane.plist` → `~/Library/LaunchAgents/` | `RunAtLoad` + `KeepAlive` (only on failure). |

## Why this works without forking Hermes

The upstream Hermes dispatcher checks `profile_exists(assignee)` before spawning. There's no `claude-code` Hermes profile, so the dispatcher silently skips those rows (`skipped_nonspawnable`). Our daemon claims them first via SQLite CAS on `claim_lock IS NULL`. No upstream patches required.

## Install

```bash
bash install.sh
```

Idempotent. Re-run after edits to push code + reload the daemon.

Verify:

```bash
launchctl list ai.hermes.claude-code-lane
tail -f ~/.hermes/logs/claude-code-lane.out.log
```

## Use

**From Hermes chat** (Telegram / WhatsApp / Nano pane):

> Hermes, run a `claude_code_run` on `/Users/biel/ARC/Forge/Geo` to refactor the X module.

Hermes calls the MCP tool, which creates the kanban row. The daemon picks it up within ~5s.

**From the kanban CLI** (direct, no Hermes in the loop):

```bash
hermes kanban create \
    --assignee claude-code \
    --workspace-kind dir \
    --workspace-path /abs/path/to/repo \
    --title "rate limiter" \
    --body "implement a token-bucket rate limiter at rate_limiter.py with tests"
```

**Inspect a running task:**

```bash
hermes kanban show <task_id>            # status + recent events
hermes kanban events <task_id>          # full event timeline
tail -f ~/.hermes/logs/claude-code-lane.out.log
```

## Config knobs

Environment vars read by the daemon (set in the plist):

- `CLAUDE_CODE_BIN` — path to the `claude` binary. Defaults to `claude` on `PATH`.
- `CLAUDE_CODE_PERMISSION_MODE` — passed as `--permission-mode`. Defaults to `acceptEdits`. Use `bypassPermissions` for fully autonomous (no permission gates).

Per-task overrides via kanban fields:

- `model_override` → `claude --model <id>`
- `max_runtime_seconds` → SIGTERM after this many seconds
- `workspace_kind` must be `dir`; `workspace_path` must be absolute.

## Lifecycle on the kanban

```
ready  ─── daemon claims ───►  running  ─── final stream-json `result` ──►  done
                                  │
                                  └── is_error / timeout / spawn fail ──►  blocked
```

The daemon heartbeats every 30s so the upstream dispatcher's reclaim logic doesn't yank rows out from under in-flight runs.

## Known limits

- No graceful restart adoption. If the daemon dies while `claude` instances are running, those instances finish naturally but their kanban rows aren't marked done. They'll get reclaimed back to `ready` by the upstream dispatcher's claim-expires logic, then re-spawned — potentially duplicating work. For long jobs, consider lowering `max_runtime_seconds`.
- Output past stream-json's buffer is dropped (line-buffered subprocess). Each event row caps at the JSON Claude Code emits.
