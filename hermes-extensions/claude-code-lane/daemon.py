#!/usr/bin/env python3
"""Hermes kanban worker for the ``claude-code`` assignee.

Polls ``~/.hermes/kanban.db`` for ``status=ready AND assignee=claude-code`` rows,
claims them, spawns ``claude -p ... --output-format stream-json`` inside each
task's workspace directory, streams events into ``task_events``, heartbeats,
and marks the row done (or blocked) on the final result.

Coexists with the upstream Hermes dispatcher: the dispatcher silently skips
``claude-code`` rows because no Hermes profile of that name exists
(see ``hermes_cli/kanban_db.py`` ``_default_spawn`` profile-existence gate).
"""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

HERMES_AGENT = Path.home() / ".hermes" / "hermes-agent"
sys.path.insert(0, str(HERMES_AGENT))

from hermes_cli import kanban_db as kb  # noqa: E402

POLL_INTERVAL_S = 5
HEARTBEAT_INTERVAL_S = 30
DEFAULT_MAX_RUNTIME_S = 3600
CLAIMER_ID = f"claude-code-lane@{socket.gethostname()}/{os.getpid()}"
CC_BIN = os.environ.get("CLAUDE_CODE_BIN", "claude")
PERMISSION_MODE = os.environ.get("CLAUDE_CODE_PERMISSION_MODE", "acceptEdits")


def _log(msg: str) -> None:
    print(f"[claude-code-lane] {msg}", flush=True)


def _find_ready(conn) -> list[dict]:
    rows = conn.execute(
        """
        SELECT id, body, workspace_kind, workspace_path,
               max_runtime_seconds, model_override
          FROM tasks
         WHERE assignee = 'claude-code'
           AND status = 'ready'
           AND claim_lock IS NULL
         ORDER BY priority DESC, created_at ASC
         LIMIT 8
        """
    ).fetchall()
    return [dict(r) for r in rows]


def _run_task(
    task_id: str,
    body: str,
    workspace_path: str,
    max_runtime: Optional[int],
    model: Optional[str],
) -> None:
    conn = kb.connect()
    workspace = Path(workspace_path)
    workspace.mkdir(parents=True, exist_ok=True)

    argv = [
        CC_BIN,
        "-p", body,
        "--output-format", "stream-json",
        "--verbose",
        "--permission-mode", PERMISSION_MODE,
    ]
    if model:
        argv.extend(["--model", model])

    _log(f"task={task_id} spawning claude in {workspace} model={model or 'default'}")

    proc = subprocess.Popen(
        argv,
        cwd=str(workspace),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )

    with kb.write_txn(conn):
        conn.execute(
            "UPDATE tasks SET worker_pid = ? WHERE id = ?",
            (proc.pid, task_id),
        )

    stop_hb = threading.Event()
    timed_out = threading.Event()

    def heartbeat_loop() -> None:
        hb_conn = kb.connect()
        try:
            while not stop_hb.wait(HEARTBEAT_INTERVAL_S):
                if proc.poll() is not None:
                    break
                kb.heartbeat_worker(hb_conn, task_id)
        finally:
            hb_conn.close()

    def watchdog_loop() -> None:
        if not stop_hb.wait(max_runtime or DEFAULT_MAX_RUNTIME_S):
            timed_out.set()
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    hb_thread = threading.Thread(target=heartbeat_loop, daemon=True)
    hb_thread.start()
    wd_thread = threading.Thread(target=watchdog_loop, daemon=True)
    wd_thread.start()

    final_summary: Optional[str] = None
    final_error: Optional[str] = None
    saw_result = False

    try:
        assert proc.stdout is not None
        for raw in proc.stdout:
            line = raw.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                with kb.write_txn(conn):
                    kb._append_event(
                        conn, task_id, "cc_raw",
                        {"line": line[:2000]},
                    )
                continue

            kind = evt.get("type", "unknown")
            with kb.write_txn(conn):
                kb._append_event(conn, task_id, f"cc_{kind}", evt)

            if kind == "result":
                saw_result = True
                summary = evt.get("result")
                if evt.get("is_error"):
                    final_error = (summary or "claude reported error")[:500]
                else:
                    final_summary = summary
                break
    finally:
        stop_hb.set()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)
        hb_thread.join(timeout=5)
        wd_thread.join(timeout=5)

    if timed_out.is_set() and final_error is None:
        final_error = "max_runtime exceeded"
    if final_error is None and not saw_result:
        final_error = f"claude-code exited without a result (code {proc.returncode})"

    if final_error:
        _log(f"task={task_id} BLOCKED: {final_error}")
        kb.block_task(conn, task_id, reason=f"claude-code: {final_error}")
    else:
        _log(f"task={task_id} DONE")
        kb.complete_task(
            conn, task_id,
            result=final_summary,
            summary=(final_summary or "claude-code run completed")[:500],
        )
    conn.close()


def _validate_workspace(row: dict) -> Optional[str]:
    if row["workspace_kind"] != "dir":
        return f"workspace_kind must be 'dir', got {row['workspace_kind']!r}"
    ws = row["workspace_path"]
    if not ws or not Path(ws).is_absolute():
        return f"workspace_path must be absolute, got {ws!r}"
    return None


def _tick(conn) -> None:
    for row in _find_ready(conn):
        tid = row["id"]
        err = _validate_workspace(row)
        if err:
            # Claim then immediately block so the row doesn't churn forever.
            claimed = kb.claim_task(conn, tid, claimer=CLAIMER_ID)
            if claimed is None:
                continue
            _log(f"task={tid} INVALID: {err}")
            kb.block_task(conn, tid, reason=f"claude-code: {err}")
            continue

        claimed = kb.claim_task(conn, tid, claimer=CLAIMER_ID)
        if claimed is None:
            continue

        t = threading.Thread(
            target=_run_task,
            args=(
                tid,
                row["body"] or "",
                row["workspace_path"],
                row["max_runtime_seconds"],
                row["model_override"],
            ),
            daemon=True,
        )
        t.start()


def main() -> None:
    _log(f"start claimer={CLAIMER_ID} cc_bin={CC_BIN} perm={PERMISSION_MODE}")
    while True:
        try:
            conn = kb.connect()
            try:
                _tick(conn)
            finally:
                conn.close()
        except Exception as e:  # noqa: BLE001
            _log(f"tick error: {e!r}")
        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
