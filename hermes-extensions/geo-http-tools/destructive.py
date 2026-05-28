"""Two-phase destructive flow with Telegram confirm.

prepare → DM Gabriel → wait 30s for Y/N → commit or abort.

The 300-s server-side backstop on `/destructive/prepare` is the safety net:
if we crash mid-flow, Geo expires the transaction on its own.

Block_version is passed through prepare so commit can detect a 409 Conflict
(someone — the app, another agent — wrote to the file between phases).

Inbound listening:
A ``pre_gateway_dispatch`` hook (registered from ``__init__.py``) drops every
inbound message from ``GABRIEL_TELEGRAM_CHAT_ID`` into ``_inbound_queue``. The
destructive flow drains the queue with a 1-s poll for 30 s wall-clock. The
hook returns ``None`` (action="allow") so normal dispatch continues — we don't
swallow the confirmation reply, we just observe it.
"""

from __future__ import annotations

import asyncio
import json
import time
from collections import deque
from typing import Any, Callable, Optional

from .client import GeoAPIClient, GeoConflict, GeoError

GABRIEL_TELEGRAM_CHAT_ID = "5225262193"
TELEGRAM_TARGET = f"telegram:{GABRIEL_TELEGRAM_CHAT_ID}"
CONFIRM_TIMEOUT_S = 30.0
REMINDER_AT_S = 25.0
POLL_INTERVAL_S = 1.0

_inbound_queue: "deque[tuple[float, str]]" = deque(maxlen=64)
_inbound_lock = asyncio.Lock()
_confirm_gate = asyncio.Lock()
_consumed_ts = 0.0


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _result(ok: bool, **fields: Any) -> str:
    return json.dumps({"ok": ok, **fields}, default=str)


async def _record_inbound(text: str) -> None:
    async with _inbound_lock:
        _inbound_queue.append((time.time(), text))


async def pre_gateway_dispatch_hook(event=None, **_kw: Any) -> Optional[dict]:
    """Plugin hook: capture Gabriel's Telegram replies for the destructive flow.

    Must NOT swallow the message — return None (allow) so hermes dispatches
    normally. We only observe.
    """
    if event is None:
        return None
    try:
        source = getattr(event, "source", None)
        if source is None:
            return None
        platform = getattr(source, "platform", None)
        platform_name = getattr(platform, "value", str(platform) if platform else "")
        if platform_name.lower() != "telegram":
            return None
        chat_id = str(getattr(source, "chat_id", "") or "")
        if chat_id != GABRIEL_TELEGRAM_CHAT_ID:
            return None
        text = getattr(event, "text", None) or ""
        if not text:
            return None
        await _record_inbound(text)
    except Exception:
        return None
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


def _classify_reply(text: str) -> Optional[str]:
    norm = text.strip().lower()
    if norm in ("y", "yes", "yeah", "yep", "confirm", "ok", "okay"):
        return "yes"
    if norm in ("n", "no", "nope", "deny", "cancel", "abort"):
        return "no"
    return None


async def _await_confirmation(since_ts: float) -> str:
    """Poll the inbound queue for up to 30 s. Returns 'yes' | 'no' | 'timeout'."""
    deadline = since_ts + CONFIRM_TIMEOUT_S
    reminder_sent = False
    seen_idx = 0
    while True:
        now = time.time()
        if now >= deadline:
            return "timeout"
        if not reminder_sent and (now - since_ts) >= REMINDER_AT_S:
            reminder_sent = True
            try:
                await _send_telegram_sync("still waiting — 5 s left to confirm")
            except Exception:
                pass
        async with _inbound_lock:
            messages = list(_inbound_queue)
        for ts, text in messages[seen_idx:]:
            if ts < since_ts:
                continue
            verdict = _classify_reply(text)
            if verdict is not None:
                return verdict
        seen_idx = len(messages)
        await asyncio.sleep(POLL_INTERVAL_S)


async def _two_phase_delete(
    operation: str,
    target_id: str,
    target_label: str,
    args: dict,
) -> str:
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
    diff_preview = prepared.get("diff_preview", "(no preview)")
    server_version = prepared.get("block_version")

    warn = (
        f"⚠️ Agent wants to {operation.replace('_', ' ')} "
        f"{target_label} (id {target_id}).\n"
        f"Diff preview:\n{diff_preview}\n"
        f"Reply Y within 30 s to confirm, N or no reply to deny."
    )
    since = time.time()
    try:
        await _send_telegram_sync(warn)
    except Exception as e:
        return _result(False, reason="telegram_send_failed", detail=str(e))

    verdict = await _await_confirmation(since)
    if verdict == "no":
        return _result(False, reason="user_denied", transaction_id=transaction_id)
    if verdict == "timeout":
        return _result(False, reason="timeout", transaction_id=transaction_id)

    try:
        commit_result = await client.commit_destructive(
            transaction_id, block_version=server_version,
        )
    except GeoConflict as e:
        return _result(False, reason="stale_version", detail=str(e.body))
    except GeoError as e:
        return _result(False, reason="commit_failed", detail=str(e))

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
            "version, returns {ok: false, reason: 'stale_version'} — re-fetch and retry."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string", "description": "Optional, shown in confirm DM."},
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
            "within 30 s. Two-phase prepare → DM → commit."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string"},
                "block_version": {"type": "integer"},
            },
            "required": ["id"],
        },
        "handler": _delete_task,
    },
]


def get_inbound_hook() -> Callable:
    return pre_gateway_dispatch_hook
