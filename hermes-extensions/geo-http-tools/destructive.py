"""Destructive Geo ops gated on a Telegram Y/N confirm.

DM Gabriel → wait 30 s for Y/N → commit or abort.

Blocks are files-are-truth, so a block delete is a native ``rm`` of its .md
under the Geo vault (the app FileWatcher reconciles the derived index). A task
delete stays KEEP-COMPUTE over HTTP — a plain ``DELETE /tasks/{id}`` (no
two-phase prepare/commit; the /v1/destructive/* routes are gone).

Confirmation mechanism (why this is self-contained):
The agent's turn blocks inside the tool call awaiting Gabriel's reply. When his
"Y" arrives the gateway fires the ``pre_gateway_dispatch`` hook BEFORE its
"interrupt running agent" step (gateway/run.py). The hook resolves the pending
confirmation and returns ``action="skip"``, which makes the gateway drop the
reply early — so it does NOT interrupt/cancel the blocked turn (the old bug:
"Y did nothing"). Resolution uses a module-level ``_pending`` + ``threading.Event``
so it works regardless of event-loop/thread and needs no gateway session plumbing
(the native approval queue's notifier is only registered by the TUI gateway, not
the Telegram one — which is why the previous native bridge silently fell back).
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import threading
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

from . import guard, tasks_fs
from .client import GeoError

BLOCKS_DIR = (
    Path.home() / "Library" / "Application Support" / "Geo" / "Blocks"
)

GABRIEL_TELEGRAM_CHAT_ID = "5225262193"
TELEGRAM_TARGET = f"telegram:{GABRIEL_TELEGRAM_CHAT_ID}"
CONFIRM_TIMEOUT_S = 30.0
REMINDER_AT_S = 25.0

# One in-flight confirmation at a time (deletes are rare; _confirm_gate serializes).
_confirm_gate = asyncio.Lock()
_pending: "Optional[_PendingConfirm]" = None


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _result(ok: bool, **fields: Any) -> str:
    return json.dumps({"ok": ok, **fields}, default=str)


class _PendingConfirm:
    """A delete awaiting Gabriel's Y/N. Resolved by the inbound hook from any
    thread via a threading.Event; awaited on the loop via asyncio.to_thread."""

    __slots__ = ("_event", "verdict")

    def __init__(self) -> None:
        self._event = threading.Event()
        self.verdict = "timeout"

    @property
    def resolved(self) -> bool:
        return self._event.is_set()

    def resolve(self, verdict: str) -> None:
        if not self._event.is_set():
            self.verdict = verdict
            self._event.set()

    async def wait(self) -> str:
        # Two-stage so we can nudge a reminder at REMINDER_AT_S without a reply.
        got = await asyncio.to_thread(self._event.wait, REMINDER_AT_S)
        if not got:
            try:
                await _send_telegram_sync("⏳ 5 s left — reply Y to delete, or it cancels.")
            except Exception:
                pass
            await asyncio.to_thread(self._event.wait, CONFIRM_TIMEOUT_S - REMINDER_AT_S)
        return self.verdict


def _classify_reply(text: str) -> Optional[str]:
    norm = text.strip().lower()
    if norm in ("y", "yes", "yeah", "yep", "confirm", "ok", "okay", "sim"):
        return "yes"
    if norm in ("n", "no", "nope", "deny", "cancel", "abort", "não", "nao"):
        return "no"
    return None


def pre_gateway_dispatch_hook(event=None, **_kw: Any) -> Optional[dict]:
    """Resolve a pending Geo delete from Gabriel's Telegram Y/N reply.

    Returns ``action="skip"`` when the reply answers a pending confirmation, so
    the gateway drops it before the interrupt step and the blocked delete turn
    survives to commit. Returns ``None`` (allow) otherwise.
    """
    if event is None:
        return None
    try:
        if _pending is None or _pending.resolved:
            return None
        source = getattr(event, "source", None)
        if source is None:
            return None
        platform = getattr(source, "platform", None)
        platform_name = getattr(platform, "value", str(platform) if platform else "")
        if platform_name.lower() != "telegram":
            return None
        if str(getattr(source, "chat_id", "") or "") != GABRIEL_TELEGRAM_CHAT_ID:
            return None
        verdict = _classify_reply(getattr(event, "text", None) or "")
        if verdict is None:
            return None
        _pending.resolve(verdict)
        return {"action": "skip", "reason": "geo_destructive_confirmation"}
    except Exception:
        return None


async def _send_telegram_sync(message: str) -> None:
    """Dispatch via the in-process send_message tool registry entry."""
    from tools.registry import registry

    entry = registry.get_entry("send_message")
    if entry is None:
        raise RuntimeError("send_message tool not registered")
    args = {"action": "send", "target": TELEGRAM_TARGET, "message": message}
    if entry.is_async:
        await entry.handler(args)
    else:
        await asyncio.to_thread(entry.handler, args)


def _confirm_message(target_label: str) -> str:
    return (
        f"🗑️ Delete {target_label}?\n"
        f"Reply Y to confirm — N or no reply cancels (30s)."
    )


async def _confirm_then(
    target_label: str,
    commit: Callable[[], Awaitable[Any]],
) -> str:
    """DM Gabriel, wait for Y/N, then run ``commit`` on a 'yes'."""
    global _pending
    async with _confirm_gate:
        pending = _PendingConfirm()
        _pending = pending
        try:
            try:
                await _send_telegram_sync(_confirm_message(target_label))
            except Exception as e:
                return _result(False, reason="telegram_send_failed", detail=str(e))

            verdict = await pending.wait()
            if verdict != "yes":
                return _result(
                    False,
                    reason="user_denied" if verdict == "no" else "timeout",
                )

            try:
                commit_result = await commit()
            except GeoError as e:
                return _result(False, reason="commit_failed", detail=str(e))
            except Exception as e:
                return _result(False, reason="commit_failed", detail=f"{type(e).__name__}: {e}")
        finally:
            _pending = None

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
    block_id = (args or {}).get("id")
    if not block_id:
        return _err("id is required")
    label = f"block '{(args or {}).get('title') or block_id}'"

    async def commit() -> Any:
        return await asyncio.to_thread(_rm_block, block_id)

    return await _confirm_then(label, commit)


async def _delete_task(args: dict, **_kw: Any) -> str:
    task_id = (args or {}).get("id")
    if not task_id:
        return _err("id is required")
    label = f"task '{(args or {}).get('title') or task_id}'"

    async def commit() -> Any:
        return await asyncio.to_thread(tasks_fs.delete_task, task_id)

    return await _confirm_then(label, commit)


DESTRUCTIVE_TOOLS: list[dict] = [
    {
        "name": "geo_delete_block",
        "description": (
            "DESTRUCTIVE: delete a block (native rm of its .md file; the app "
            "reconciles). Requires Gabriel's Telegram Y confirm within 30 s. "
            "Always pass `title` so the confirm DM is readable."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string", "description": "Shown in the confirm DM. Always pass it."},
            },
            "required": ["id"],
        },
        "handler": _delete_block,
    },
    {
        "name": "geo_delete_task",
        "description": (
            "DESTRUCTIVE: delete a task (HTTP DELETE). Requires Gabriel's Telegram "
            "Y confirm within 30 s. Always pass `title` so the confirm DM is readable."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string", "description": "Shown in the confirm DM. Always pass it."},
            },
            "required": ["id"],
        },
        "handler": _delete_task,
    },
]


def get_inbound_hook() -> Callable:
    return pre_gateway_dispatch_hook
