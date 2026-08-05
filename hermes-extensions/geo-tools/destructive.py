"""Destructive Geo ops gated on a two-phase confirm-token handshake.

Blocks are files-are-truth, so a block delete is a native ``rm`` of its .md
under the Geo vault (the app FileWatcher reconciles the derived index). A task
delete is likewise a native rm of its ``.json`` under ``Tasks/`` via tasks_fs.

Confirmation mechanism (why two-phase, not a blocking wait):
The old design blocked the agent's turn inside the tool call on a
``threading.Event`` with a 30 s timeout, racing Gabriel's reply against
Telegram's inbound batching + human latency — replies slower than ~25 s always
timed out, and the late "Y" then started a fresh turn that re-triggered the
same doomed wait (the "reply Y does nothing" loop). Now the first call stages
the delete and returns immediately with a ``confirm_token``; the agent asks
Gabriel in its normal reply and ends the turn. Gabriel's confirmation arrives
as an ordinary new message, and the agent calls the tool again with the token
to commit. No blocking, no timeout race, platform-agnostic (works the same on
Telegram, WhatsApp and the TUI). Staged deletes expire after CONFIRM_TTL_S and
die with the process — both fail safe (nothing is deleted without a live
token round-trip).
"""

from __future__ import annotations

import asyncio
import json
import os
import secrets
import shutil
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

from . import geo_write, guard
from .client import GeoError

BLOCKS_DIR = (
    Path.home() / "Vault" / "Blocks"
)

CONFIRM_TTL_S = 900.0

_staged: dict[str, dict] = {}


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _result(ok: bool, **fields: Any) -> str:
    return json.dumps({"ok": ok, **fields}, default=str)


def _prune_staged() -> None:
    now = time.monotonic()
    for token in [t for t, e in _staged.items() if e["expires"] <= now]:
        del _staged[token]


def _stage(kind: str, target_id: str, title: str) -> str:
    """Stage a delete and return its token; re-staging the same target
    refreshes the TTL and reuses the existing token."""
    _prune_staged()
    for token, entry in _staged.items():
        if entry["kind"] == kind and entry["id"] == target_id:
            entry["expires"] = time.monotonic() + CONFIRM_TTL_S
            return token
    token = secrets.token_hex(4)
    _staged[token] = {
        "kind": kind,
        "id": target_id,
        "title": title,
        "expires": time.monotonic() + CONFIRM_TTL_S,
    }
    return token


def _pending(token: str, label: str, note: str = "") -> str:
    return _result(
        False,
        pending_confirmation=True,
        confirm_token=token,
        expires_in_s=int(CONFIRM_TTL_S),
        instruction=(
            f"{note}NOTHING was deleted. Ask Gabriel to confirm deleting "
            f"{label} in your reply and END YOUR TURN. Only after he explicitly "
            f"confirms in his NEXT message, call this tool again with the same "
            f"id plus this confirm_token. If he declines or doesn't answer, do "
            f"nothing — the token expires on its own."
        ),
    )


async def _confirmed_delete(
    kind: str,
    args: dict,
    commit: Callable[[], Awaitable[Any]],
) -> str:
    target_id = (args or {}).get("id")
    if not target_id:
        return _err("id is required")
    title = (args or {}).get("title") or target_id
    label = f"{kind} '{title}'"
    token = (args or {}).get("confirm_token")

    if not token:
        return _pending(_stage(kind, target_id, title), label)

    _prune_staged()
    entry = _staged.get(str(token))
    if entry is None or entry["kind"] != kind or entry["id"] != target_id:
        return _pending(
            _stage(kind, target_id, title),
            label,
            note="confirm_token invalid or expired — restaged. ",
        )

    del _staged[str(token)]
    try:
        commit_result = await commit()
    except GeoError as e:
        return _result(False, reason="commit_failed", detail=str(e))
    except Exception as e:
        return _result(False, reason="commit_failed", detail=f"{type(e).__name__}: {e}")
    return _result(True, result=commit_result)


def _rm_block(block_id: str) -> dict:
    rel = block_id if block_id.endswith(".md") else f"{block_id}.md"
    path = BLOCKS_DIR / rel
    if not path.exists():
        raise GeoError(f"block not found: {block_id}")
    guard.assert_writable(path)
    os.remove(path)
    attach = path.parent / "Attachments" / path.stem
    if attach.is_dir():
        shutil.rmtree(attach, ignore_errors=True)
    return {"deleted": block_id}


async def _delete_block(args: dict, **_kw: Any) -> str:
    async def commit() -> Any:
        return await asyncio.to_thread(_rm_block, args["id"])

    return await _confirmed_delete("block", args, commit)


async def _delete_task(args: dict, **_kw: Any) -> str:
    async def commit() -> Any:
        return await asyncio.to_thread(
            geo_write.update_task,
            writer="geo-agent",
            task_id=args["id"],
            op="delete",
        )

    return await _confirmed_delete("task", args, commit)


_CONFIRM_DOC = (
    "Two-phase: the FIRST call (no confirm_token) deletes nothing — it stages "
    "the delete and returns a confirm_token. Ask Gabriel for confirmation in "
    "your reply and end the turn. Only after he explicitly confirms in a NEW "
    "message, call again with the same id + confirm_token to commit. Never "
    "pass a confirm_token Gabriel has not confirmed. Always pass `title` so "
    "the confirmation question is readable."
)

DESTRUCTIVE_TOOLS: list[dict] = [
    {
        "name": "geo_delete_block",
        "description": (
            "DESTRUCTIVE: delete a block (native rm of its .md file; the app "
            "reconciles). " + _CONFIRM_DOC
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string", "description": "Shown in the confirmation question. Always pass it."},
                "confirm_token": {"type": "string", "description": "Only on the second call, after Gabriel explicitly confirmed."},
            },
            "required": ["id"],
        },
        "handler": _delete_block,
    },
    {
        "name": "geo_delete_task",
        "description": (
            "DESTRUCTIVE: delete a task (native rm of its .json under Tasks/; "
            "the app reconciles). " + _CONFIRM_DOC
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string", "description": "Shown in the confirmation question. Always pass it."},
                "confirm_token": {"type": "string", "description": "Only on the second call, after Gabriel explicitly confirmed."},
            },
            "required": ["id"],
        },
        "handler": _delete_task,
    },
]
