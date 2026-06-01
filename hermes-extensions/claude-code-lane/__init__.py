"""Hermes plugin: claude_code_run tool.

Registers a tool that creates a kanban row with ``assignee='claude-code'``.
The accompanying ``daemon.py`` (run as a LaunchAgent) claims the row and
spawns ``claude -p ...`` in the target directory.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

logger = logging.getLogger("plugin.claude-code-lane")

CLAUDE_CODE_RUN_SCHEMA = {
    "name": "claude_code_run",
    "description": (
        "Spawn a Claude Code (`claude` CLI) instance in the given directory to "
        "execute the given prompt. Runs detached, managed by the claude-code-lane "
        "kanban worker. Returns immediately with a kanban task id you can poll via "
        "`kanban_show` or `hermes kanban show <id>`. Call repeatedly with "
        "different directories to run multiple instances in parallel."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "directory": {
                "type": "string",
                "description": "Absolute path Claude Code should `cd` into. Created if missing.",
            },
            "prompt": {
                "type": "string",
                "description": "The prompt passed to `claude -p`. Plain text; treated as the user message.",
            },
            "model": {
                "type": "string",
                "description": "Optional model id (e.g. 'claude-opus-4-8'). Omit to use Claude Code default.",
            },
            "max_runtime_seconds": {
                "type": "integer",
                "description": "Optional runtime cap. Daemon SIGTERMs after this many seconds. Default 3600.",
            },
            "title": {
                "type": "string",
                "description": "Optional kanban card title. Defaults to the first line of `prompt`.",
            },
        },
        "required": ["directory", "prompt"],
    },
}


def _ok(**fields: Any) -> str:
    return json.dumps({"ok": True, **fields})


def _handle(args: dict, **_kw: Any) -> str:
    from tools.registry import tool_error

    directory = args.get("directory")
    prompt = args.get("prompt")
    if not directory:
        return tool_error("directory is required")
    if not prompt:
        return tool_error("prompt is required")

    abspath = Path(str(directory)).expanduser()
    if not abspath.is_absolute():
        return tool_error(f"directory must be absolute, got {directory!r}")
    abspath.mkdir(parents=True, exist_ok=True)

    title = args.get("title")
    if not title:
        first_line = str(prompt).strip().splitlines()[0] if prompt else "claude-code run"
        title = first_line[:80] or "claude-code run"

    max_runtime = args.get("max_runtime_seconds")
    model = args.get("model")

    try:
        from hermes_cli import kanban_db as kb
        conn = kb.connect()
        try:
            tid = kb.create_task(
                conn,
                title=str(title),
                body=str(prompt),
                assignee="claude-code",
                workspace_kind="dir",
                workspace_path=str(abspath),
                max_runtime_seconds=(
                    int(max_runtime) if max_runtime is not None else None
                ),
                created_by=os.environ.get("HERMES_PROFILE") or "claude-code-lane",
            )
            if model:
                with kb.write_txn(conn):
                    conn.execute(
                        "UPDATE tasks SET model_override = ? WHERE id = ?",
                        (str(model), tid),
                    )
            task = kb.get_task(conn, tid)
            return _ok(
                task_id=tid,
                status=task.status if task else None,
                directory=str(abspath),
            )
        finally:
            conn.close()
    except ValueError as e:
        return tool_error(f"claude_code_run: {e}")
    except Exception as e:
        logger.exception("claude_code_run failed")
        return tool_error(f"claude_code_run: {e}")


def register(ctx) -> None:
    ctx.register_tool(
        name="claude_code_run",
        toolset="claude_code_lane",
        schema=CLAUDE_CODE_RUN_SCHEMA,
        handler=_handle,
        description="Spawn a Claude Code instance as a kanban worker in a directory you specify.",
        emoji="🛠",
    )
