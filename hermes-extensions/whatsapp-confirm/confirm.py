from __future__ import annotations

import asyncio
import logging
import time
from collections import deque
from typing import Any, Optional

GABRIEL_TELEGRAM_CHAT_ID = "5225262193"
TELEGRAM_TARGET = f"telegram:{GABRIEL_TELEGRAM_CHAT_ID}"
CONFIRM_TIMEOUT_S = 30.0
REMINDER_AT_S = 25.0
POLL_INTERVAL_S = 1.0
PREVIEW_CHARS = 280

logger = logging.getLogger("plugin.whatsapp-confirm")

_inbound_queue: "deque[tuple[float, str]]" = deque(maxlen=64)
_inbound_lock = asyncio.Lock()
_confirm_gate = asyncio.Lock()
_consumed_ts = 0.0


async def _record_inbound(text: str) -> None:
    async with _inbound_lock:
        _inbound_queue.append((time.time(), text))


async def pre_gateway_dispatch_hook(event=None, **_kw: Any) -> Optional[dict]:
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


async def _send_telegram(message: str) -> None:
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
    if norm in ("y", "yes", "yeah", "yep", "confirm", "ok", "okay", "send", "go"):
        return "yes"
    if norm in ("n", "no", "nope", "deny", "cancel", "abort", "stop"):
        return "no"
    return None


async def _await_confirmation(since_ts: float) -> str:
    global _consumed_ts
    deadline = since_ts + CONFIRM_TIMEOUT_S
    reminder_sent = False
    while True:
        now = time.time()
        if now >= deadline:
            return "timeout"
        if not reminder_sent and (now - since_ts) >= REMINDER_AT_S:
            reminder_sent = True
            try:
                await _send_telegram("still waiting — 5 s left to approve WhatsApp send")
            except Exception:
                pass
        async with _inbound_lock:
            messages = list(_inbound_queue)
        for ts, text in messages:
            if ts < since_ts or ts <= _consumed_ts:
                continue
            verdict = _classify_reply(text)
            if verdict is not None:
                _consumed_ts = ts
                return verdict
        await asyncio.sleep(POLL_INTERVAL_S)


def _is_whatsapp_send(tool_name: str, args: Optional[dict]) -> tuple[bool, str, str]:
    if tool_name != "send_message":
        return False, "", ""
    if not args:
        return False, "", ""
    action = (args.get("action") or "send").strip().lower()
    if action != "send":
        return False, "", ""
    target = (args.get("target") or "").strip()
    if not target.lower().startswith("whatsapp"):
        return False, "", ""
    message = args.get("message") or ""
    return True, target, message


async def pre_tool_call_hook(
    tool_name: str = "",
    args: Optional[dict] = None,
    **_kw: Any,
) -> Optional[dict]:
    is_wa, target, message = _is_whatsapp_send(tool_name, args)
    if not is_wa:
        return None

    preview = message if len(message) <= PREVIEW_CHARS else message[:PREVIEW_CHARS] + "…"
    prompt = (
        f"⚠️ Agent wants to send WhatsApp to {target}:\n"
        f"---\n{preview}\n---\n"
        f"Reply Y within 30 s to send, N or no reply to deny."
    )

    async with _confirm_gate:
        since = time.time()
        try:
            await _send_telegram(prompt)
        except Exception as e:
            logger.warning("telegram confirm DM failed: %s", e)
            return {
                "action": "block",
                "message": (
                    "WhatsApp send blocked: could not reach Gabriel on Telegram to "
                    f"request approval ({e}). Do not retry without rephrasing or "
                    "switching to a different platform."
                ),
            }

        verdict = await _await_confirmation(since)
    if verdict == "yes":
        return None
    reason = "user denied" if verdict == "no" else "no reply within 30 s"
    return {
        "action": "block",
        "message": (
            f"WhatsApp send blocked: {reason}. The user has not approved this "
            "outbound message. Do not retry without rephrasing the message or "
            "asking the user directly on Telegram first."
        ),
    }
