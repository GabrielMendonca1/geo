"""Two-phase destructive flow with a Telegram Y/N confirm.

prepare → DM Gabriel → wait 30 s for Y/N → commit or abort.

The 300-s server-side backstop on `/destructive/prepare` is the safety net:
if we crash mid-flow, Geo expires the transaction on its own.

`block_version` is passed through prepare so commit can detect a 409 Conflict
(someone — the app, another agent — wrote to the file between phases).

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
import threading
from typing import Any, Callable, Optional

from .client import GeoAPIClient, GeoConflict, GeoError

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


async def _two_phase_delete(
    operation: str,
    target_id: str,
    target_label: str,
    args: dict,
) -> str:
    global _pending
    try:
        client = await GeoAPIClient.get_instance()
    except GeoError as e:
        return _err(str(e))

    block_version = args.get("block_version")
    try:
        prepared = await client.prepare_destructive(
            operation, target_id, block_version=block_version,
        )
    except GeoError as e:
        return _err(f"prepare failed: {e}")

    transaction_id = prepared["transaction_id"]
    server_version = prepared.get("block_version")

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
                    transaction_id=transaction_id,
                )

            try:
                commit_result = await client.commit_destructive(
                    transaction_id, block_version=server_version,
                )
            except GeoConflict as e:
                return _result(False, reason="stale_version", detail=str(e.body))
            except GeoError as e:
                return _result(False, reason="commit_failed", detail=str(e))
        finally:
            _pending = None

    return _result(True, transaction_id=transaction_id, result=commit_result)


async def _delete_block(args: dict, **_kw: Any) -> str:
    block_id = (args or {}).get("id")
    if not block_id:
        return _err("id is required")
    label = f"block '{(args or {}).get('title') or block_id}'"
    return await _two_phase_delete("delete_block", block_id, label, args or {})


async def _delete_task(args: dict, **_kw: Any) -> str:
    task_id = (args or {}).get("id")
    if not task_id:
        return _err("id is required")
    label = f"task '{(args or {}).get('title') or task_id}'"
    return await _two_phase_delete("delete_task", task_id, label, args or {})


DESTRUCTIVE_TOOLS: list[dict] = [
    {
        "name": "geo_delete_block",
        "description": (
            "DESTRUCTIVE: delete a block. Requires Gabriel's Telegram Y confirm "
            "within 30 s. Two-phase: prepare → DM → commit. On stale frontmatter "
            "version, returns {ok: false, reason: 'stale_version'} — re-fetch and retry. "
            "Always pass `title` so the confirm DM is readable."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string", "description": "Shown in the confirm DM. Always pass it."},
                "block_version": {
                    "type": "integer",
                    "description": "Optional optimistic-concurrency token from a prior fetch.",
                },
            },
            "required": ["id"],
        },
        "handler": _delete_block,
    },
    {
        "name": "geo_delete_task",
        "description": (
            "DESTRUCTIVE: delete a task. Requires Gabriel's Telegram Y confirm "
            "within 30 s. Two-phase: prepare → DM → commit. Always pass `title` so "
            "the confirm DM is readable."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string", "description": "Shown in the confirm DM. Always pass it."},
                "block_version": {"type": "integer"},
            },
            "required": ["id"],
        },
        "handler": _delete_task,
    },
]


def get_inbound_hook() -> Callable:
    return pre_gateway_dispatch_hook
