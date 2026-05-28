"""Non-destructive write tool handlers for Geo HTTP API.

Destructive ops (delete_*) live in ``destructive.py`` because they require
the two-phase prepare → Telegram confirm → commit dance.
"""

from __future__ import annotations

import json
from typing import Any, Callable

from .client import GeoAPIClient, GeoError


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _ok(payload: Any) -> str:
    return json.dumps({"ok": True, "data": payload}, default=str)


def _wrap(handler: Callable[[GeoAPIClient, dict], Any]) -> Callable:
    async def _entry(args: dict, **_kw: Any) -> str:
        try:
            client = await GeoAPIClient.get_instance()
            result = await handler(client, args or {})
            return _ok(result)
        except GeoError as e:
            return _err(str(e))
        except Exception as e:
            return _err(f"{type(e).__name__}: {e}")
    return _entry


async def _create_block(c: GeoAPIClient, a: dict) -> Any:
    return await c.post("/blocks", json={
        "title": a["title"],
        "body": a.get("body", ""),
        "layer": a.get("layer"),
        "type": a.get("type"),
        "tags": a.get("tags"),
    })


async def _update_block(c: GeoAPIClient, a: dict) -> Any:
    payload: dict = {}
    for k in ("title", "body", "layer", "type", "status"):
        if k in a:
            payload[k] = a[k]
    if "block_version" in a:
        payload["block_version"] = a["block_version"]
    return await c.patch(f"/blocks/{a['id']}", json=payload)


async def _set_block_tag(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['id']}/tags", json={
        "tag": a["tag"],
        "action": a.get("action", "add"),
    })


async def _set_layer(c: GeoAPIClient, a: dict) -> Any:
    return await c.patch(f"/blocks/{a['id']}/layer", json={"layer": a["layer"]})


async def _extract_permanent_from(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['id']}/extract-permanent", json={
        "title": a["title"],
        "body": a["body"],
    })


async def _promote_to_permanent(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['id']}/promote-to-permanent", json={})


async def _link_block_to_day(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/days/{a['day']}/link", json={"block_id": a["block_id"]})


async def _create_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.post("/tasks", json={
        "title": a["title"],
        "body": a.get("body"),
        "due": a.get("due"),
        "day": a.get("day"),
        "tags": a.get("tags"),
        "block_id": a.get("block_id"),
    })


async def _update_task(c: GeoAPIClient, a: dict) -> Any:
    payload: dict = {}
    for k in ("title", "body", "due", "day", "status", "tags"):
        if k in a:
            payload[k] = a[k]
    return await c.patch(f"/tasks/{a['id']}", json=payload)


async def _complete_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/tasks/{a['id']}/complete", json={})


async def _add_reminder(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/tasks/{a['id']}/reminders", json={"at": a["at"]})


async def _ai_parse_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.post("/tasks/ai-parse", json={"text": a["text"]})


async def _create_tag(c: GeoAPIClient, a: dict) -> Any:
    return await c.post("/tags", json={"name": a["name"], "color": a.get("color")})


async def _record_habit_occurrence(c: GeoAPIClient, a: dict) -> Any:
    return await c.post("/habits/occurrences", json={
        "habit_id": a["habit_id"],
        "at": a.get("at"),
    })


WRITE_TOOLS: list[dict] = [
    {
        "name": "geo_create_block",
        "description": "Create a new block. Returns the new block id + frontmatter_version.",
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "body": {"type": "string"},
                "layer": {"type": "string", "description": "'fleeting' | 'literature' | 'permanent'."},
                "type": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["title"],
        },
        "handler": _wrap(_create_block),
    },
    {
        "name": "geo_update_block",
        "description": "Patch a block's title/body/layer/type/status. Pass `block_version` for optimistic concurrency.",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string"},
                "body": {"type": "string"},
                "layer": {"type": "string"},
                "type": {"type": "string"},
                "status": {"type": "string"},
                "block_version": {"type": "integer"},
            },
            "required": ["id"],
        },
        "handler": _wrap(_update_block),
    },
    {
        "name": "geo_set_block_tag",
        "description": "Add or remove a tag on a block.",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "tag": {"type": "string"},
                "action": {"type": "string", "description": "'add' (default) or 'remove'."},
            },
            "required": ["id", "tag"],
        },
        "handler": _wrap(_set_block_tag),
    },
    {
        "name": "geo_set_layer",
        "description": "Change a block's Zettelkasten layer (fleeting/literature/permanent).",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "layer": {"type": "string"},
            },
            "required": ["id", "layer"],
        },
        "handler": _wrap(_set_layer),
    },
    {
        "name": "geo_extract_permanent_from",
        "description": "Extract a passage from a source block into a new permanent block; backlink is created.",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Source block id."},
                "title": {"type": "string", "description": "Title of the new permanent block."},
                "body": {"type": "string", "description": "Body of the new permanent block."},
            },
            "required": ["id", "title", "body"],
        },
        "handler": _wrap(_extract_permanent_from),
    },
    {
        "name": "geo_promote_to_permanent",
        "description": "Promote a fleeting/literature block to permanent in place.",
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        },
        "handler": _wrap(_promote_to_permanent),
    },
    {
        "name": "geo_link_block_to_day",
        "description": "Attach a block to a day record (YYYY-MM-DD).",
        "parameters": {
            "type": "object",
            "properties": {
                "day": {"type": "string"},
                "block_id": {"type": "string"},
            },
            "required": ["day", "block_id"],
        },
        "handler": _wrap(_link_block_to_day),
    },
    {
        "name": "geo_create_task",
        "description": "Create a task. `due` and `day` are optional ISO dates.",
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "body": {"type": "string"},
                "due": {"type": "string", "description": "ISO 8601 datetime."},
                "day": {"type": "string", "description": "YYYY-MM-DD."},
                "tags": {"type": "array", "items": {"type": "string"}},
                "block_id": {"type": "string", "description": "Optional source block."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_create_task),
    },
    {
        "name": "geo_update_task",
        "description": "Patch task fields.",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string"},
                "body": {"type": "string"},
                "due": {"type": "string"},
                "day": {"type": "string"},
                "status": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["id"],
        },
        "handler": _wrap(_update_task),
    },
    {
        "name": "geo_complete_task",
        "description": "Mark a task as completed (sets status + completed_at).",
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        },
        "handler": _wrap(_complete_task),
    },
    {
        "name": "geo_add_reminder",
        "description": "Schedule a reminder for a task at ISO 8601 time `at`.",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "at": {"type": "string", "description": "ISO 8601 datetime."},
            },
            "required": ["id", "at"],
        },
        "handler": _wrap(_add_reminder),
    },
    {
        "name": "geo_ai_parse_task",
        "description": "Send free-form text to Geo's AI task parser. Returns structured {title, due, tags, ...}.",
        "parameters": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
        "handler": _wrap(_ai_parse_task),
    },
    {
        "name": "geo_create_tag",
        "description": "Create a tag (idempotent on `name`).",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "color": {"type": "string", "description": "Optional hex color."},
            },
            "required": ["name"],
        },
        "handler": _wrap(_create_tag),
    },
    {
        "name": "geo_record_habit_occurrence",
        "description": "Log an occurrence of a habit. `at` defaults to now.",
        "parameters": {
            "type": "object",
            "properties": {
                "habit_id": {"type": "string"},
                "at": {"type": "string", "description": "Optional ISO 8601 datetime."},
            },
            "required": ["habit_id"],
        },
        "handler": _wrap(_record_habit_occurrence),
    },
]
