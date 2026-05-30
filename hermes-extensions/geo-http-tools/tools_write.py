"""Non-destructive write tool handlers for Geo HTTP API.

Destructive ops (delete_*) live in ``destructive.py`` because they require
the two-phase prepare → Telegram confirm → commit dance.
"""

from __future__ import annotations

import json
from typing import Any, Callable

from .client import GeoAPIClient, GeoError
from .matching import rank


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
        "content": a.get("body", ""),
        "layer": a.get("layer"),
        "type": a.get("type"),
        "tags": a.get("tags"),
    })

async def _update_block(c: GeoAPIClient, a: dict) -> Any:
    payload: dict = {}
    if "body" in a:
        payload["content"] = a["body"]
    for k in ("title", "layer", "type", "status"):
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


def _coerce_task_body(body: Any) -> Any:
    if isinstance(body, str):
        stripped = body.strip()
        if stripped.startswith("{"):
            try:
                return json.loads(stripped)
            except json.JSONDecodeError:
                return body
    return body


async def _create_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.post("/tasks", json={
        "title": a["title"],
        "body": _coerce_task_body(a.get("body")),
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


# --- Semantic task tools (find-before-create dedup) ------------------------
#
# GET /v1/tasks returns a BARE JSON ARRAY of task summaries:
#   [ {id, title, status, kind, priority, anchor, linked_block_id?}, ... ]
# `status` is "pending" | "completed"; `kind` is task|event|habit|milestone;
# `anchor` is the ISO 8601 anchor date (there is no top-level `due` — `due`
# only appears nested in a task's `body` on the detail endpoint). Passing
# status="pending" returns only pending tasks. Scoring lives in matching.py.

_TASK_VIEW_KEYS = ("id", "title", "status", "kind", "anchor")


async def _fetch_tasks(c: GeoAPIClient, include_completed: bool) -> list:
    """Pending tasks (and completed too if asked) as a plain list of dicts."""
    resp = await c.get("/tasks", status=None if include_completed else "pending")
    if isinstance(resp, list):
        return resp
    if isinstance(resp, dict):
        return resp.get("tasks") or []
    return []


def _task_view(task: dict) -> dict:
    view = {k: task[k] for k in _TASK_VIEW_KEYS if k in task}
    if "score" in task:
        view["score"] = task["score"]
    return view


async def _find_tasks(c: GeoAPIClient, a: dict) -> Any:
    tasks = await _fetch_tasks(c, bool(a.get("include_completed", False)))
    ranked = rank(a["query"], tasks, limit=int(a.get("limit", 5)))
    return {"matches": [_task_view(t) for t in ranked]}


async def _resolve_task(c: GeoAPIClient, a: dict) -> Any:
    tasks = await _fetch_tasks(c, bool(a.get("include_completed", False)))
    ranked = rank(a["query"], tasks)
    if not ranked:
        return {"matched": False, "candidates": []}
    best = ranked[0]
    second = ranked[1]["score"] if len(ranked) > 1 else 0.0
    clear = len(ranked) == 1 or best["score"] >= second + 0.15
    if best["score"] >= 0.6 and clear:
        return {"matched": True, "task": _task_view(best), "score": best["score"]}
    return {"matched": False, "candidates": [_task_view(t) for t in ranked[:3]]}


async def _upsert_task(c: GeoAPIClient, a: dict) -> Any:
    threshold = float(a.get("match_threshold", 0.82))
    if not bool(a.get("force_new", False)):
        ranked = rank(a["title"], await _fetch_tasks(c, include_completed=False))
        if ranked:
            best = ranked[0]
            kind_ok = a.get("kind") in (None, best.get("kind"))
            if best["score"] >= threshold and kind_ok:
                updated = await _update_task(c, {**a, "id": best["id"]})
                return {"action": "updated", "task": updated, "matched_score": best["score"]}
    created = await _create_task(c, a)
    return {"action": "created", "task": created}


WRITE_TOOLS: list[dict] = [
    {
        "name": "geo_find_tasks",
        "description": (
            "Search existing Geo tasks by a natural-language query, ranked by fuzzy "
            "similarity (accent/punctuation-insensitive title match + token overlap). "
            "ALWAYS call this BEFORE creating a task to avoid duplicates — or just use "
            "geo_upsert_task, which does find-or-create for you. Returns the top `limit` "
            "matches as {id, title, status, kind, due, score} sorted by score desc. By "
            "default only pending tasks; set include_completed=true to also search done ones."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "include_completed": {"type": "boolean", "description": "Default false."},
                "limit": {"type": "integer", "description": "Default 5."},
            },
            "required": ["query"],
        },
        "handler": _wrap(_find_tasks),
    },
    {
        "name": "geo_resolve_task",
        "description": (
            "Resolve a natural-language task reference (e.g. 'finish the exam', 'reuniao "
            "arca') to ONE specific task id so you can complete/update/delete it by name "
            "instead of guessing an id. Returns {matched: true, task, score} when there is "
            "a single confident match (score >= 0.6 and clearly ahead of the rest); "
            "otherwise {matched: false, candidates: [top 3 {id,title,score}]} so you can "
            "ask which one. Use before geo_complete_task / geo_update_task / geo_delete_task "
            "when you only know the task by description."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "include_completed": {"type": "boolean", "description": "Default false."},
            },
            "required": ["query"],
        },
        "handler": _wrap(_resolve_task),
    },
    {
        "name": "geo_upsert_task",
        "description": (
            "RECOMMENDED way to create a task: find-or-create (dedup). Same fields as "
            "geo_create_task (`title` required; optional `body`, `due`, `day`, `tags`, "
            "`block_id`, `kind`). It first fuzzy-searches pending tasks; if an existing "
            "task matches the title closely (score >= match_threshold, default 0.82, and "
            "any provided `kind` agrees) it UPDATES that task with your provided fields and "
            "returns {action: 'updated', task, matched_score}. Otherwise it creates a new "
            "task and returns {action: 'created', task}. Set force_new=true to skip dedup "
            "and always create. Prefer this over geo_create_task to stop duplicate tasks."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "body": {"type": "string"},
                "due": {"type": "string", "description": "ISO 8601 datetime."},
                "day": {"type": "string", "description": "YYYY-MM-DD."},
                "tags": {"type": "array", "items": {"type": "string"}},
                "block_id": {"type": "string", "description": "Optional source block."},
                "kind": {"type": "string", "description": "todo|event|habit|reminder|deadline."},
                "match_threshold": {"type": "number", "description": "Dedup cutoff, default 0.82."},
                "force_new": {"type": "boolean", "description": "Skip dedup, always create. Default false."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_upsert_task),
    },
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
        "description": "Create a task UNCONDITIONALLY (no dedup). Prefer geo_upsert_task, which avoids duplicates. `due` and `day` are optional ISO dates.",
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
