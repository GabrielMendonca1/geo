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
        "status": a.get("status"),
        "day_id": a.get("day_id"),
        "tag_name": a.get("tag_name"),
        "folder": a.get("folder"),
    })


async def _move_block(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['id']}/move", json={"folder": a.get("folder")})

async def _update_block(c: GeoAPIClient, a: dict) -> Any:
    return await c.patch(f"/blocks/{a['id']}", json={"content": a["body"]})

async def _set_block_tag(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['id']}/tag", json={"tag_name": a.get("tag_name", "")})


async def _set_layer(c: GeoAPIClient, a: dict) -> Any:
    return await c.patch(f"/blocks/{a['id']}/layer", json={"layer": a["layer"]})


async def _extract_permanent_from(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['id']}/extract-permanent", json={})


async def _promote_to_permanent(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['id']}/promote-permanent", json={})


async def _link_block_to_day(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/blocks/{a['block_id']}/link-day", json={"date": a["day"]})


def _build_task_body(a: dict) -> dict:
    kind = a.get("kind") or "task"
    body: dict[str, Any] = {"kind": kind}
    if kind == "task":
        if "due" in a:
            body["due"] = a["due"]
        if "estimated_minutes" in a:
            body["estimated_minutes"] = a["estimated_minutes"]
    elif kind == "event":
        if "start" in a:
            body["start"] = a["start"]
        if "end" in a:
            body["end"] = a["end"]
    elif kind == "habit":
        if "recurrence" in a:
            body["recurrence"] = a["recurrence"]
        if "time_of_day" in a:
            body["time_of_day"] = a["time_of_day"]
        if "selected_weekdays" in a:
            body["selected_weekdays"] = a["selected_weekdays"]
    elif kind == "milestone":
        if "target" in a:
            body["target"] = a["target"]
    return body


def _notes_from(a: dict) -> Any:
    notes = a.get("notes")
    if notes is None and isinstance(a.get("body"), str):
        notes = a["body"]
    return notes


async def _create_task(c: GeoAPIClient, a: dict) -> Any:
    payload: dict[str, Any] = {
        "title": a["title"],
        "body": _build_task_body(a),
    }
    notes = _notes_from(a)
    if notes is not None:
        payload["notes"] = notes
    linked = a.get("linked_block_id") or a.get("block_id")
    if linked is not None:
        payload["linked_block_id"] = linked
    if a.get("priority") is not None:
        payload["priority"] = a["priority"]
    tag_ids = a.get("tag_ids") or a.get("tags")
    if tag_ids is not None:
        payload["tag_ids"] = tag_ids
    if a.get("reminders") is not None:
        payload["reminders"] = a["reminders"]
    return await c.post("/tasks", json=payload)


async def _update_task(c: GeoAPIClient, a: dict) -> Any:
    payload: dict[str, Any] = {}
    for k in ("title", "notes", "status", "priority"):
        if k in a:
            payload[k] = a[k]
    linked = a.get("linked_block_id") or a.get("block_id")
    if linked is not None:
        payload["linked_block_id"] = linked
    tag_ids = a.get("tag_ids") or a.get("tags")
    if tag_ids is not None:
        payload["tag_ids"] = tag_ids
    if "body" in a and isinstance(a["body"], dict):
        payload["body"] = a["body"]
    elif a.get("kind") is not None:
        payload["body"] = _build_task_body(a)
    return await c.patch(f"/tasks/{a['id']}", json=payload)


async def _complete_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.post(f"/tasks/{a['id']}/complete", json={})


async def _add_reminder(c: GeoAPIClient, a: dict) -> Any:
    trigger = a.get("trigger", "absolute")
    body: dict[str, Any] = {"trigger": trigger}
    if trigger == "offset":
        body["offset"] = a["offset"]
    else:
        body["at"] = a["at"]
    return await c.post(f"/tasks/{a['id']}/reminder", json=body)


async def _ai_parse_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.post("/tasks/parse", json={"input": a["text"]})


async def _create_tag(c: GeoAPIClient, a: dict) -> Any:
    body: dict[str, Any] = {"name": a["name"]}
    if a.get("color") is not None:
        body["color"] = a["color"]
    return await c.post("/tags", json=body)


def _habit_date(at: Any) -> str:
    from datetime import datetime, timezone
    if isinstance(at, str) and at:
        return at[:10]
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


async def _record_habit_occurrence(c: GeoAPIClient, a: dict) -> Any:
    date = _habit_date(a.get("at"))
    return await c.post(f"/days/{date}/habit", json={"id": a["habit_id"]})


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
            "geo_create_task (`title` + `kind` required-by-kind fields; optional `notes`, "
            "`linked_block_id`, `priority`, `tag_ids`, `reminders`). It first fuzzy-searches "
            "pending tasks; if an existing task matches the title closely (score >= "
            "match_threshold, default 0.82, and any provided `kind` agrees) it UPDATES that "
            "task and returns {action: 'updated', task, matched_score}. Otherwise it creates "
            "a new task and returns {action: 'created', task}. Set force_new=true to skip "
            "dedup. Prefer this over geo_create_task to stop duplicate tasks."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "kind": {"type": "string", "description": "task|event|habit|milestone (default 'task')."},
                "due": {"type": "string", "description": "kind=task: ISO 8601 UTC due time."},
                "estimated_minutes": {"type": "integer", "description": "kind=task: estimate."},
                "start": {"type": "string", "description": "kind=event: ISO 8601 start."},
                "end": {"type": "string", "description": "kind=event: ISO 8601 end."},
                "recurrence": {"type": "string", "description": "kind=habit: daily|weekdays|weekly|biweekly|monthly|yearly."},
                "time_of_day": {"type": "string", "description": "kind=habit: ISO 8601 time-of-day."},
                "selected_weekdays": {"type": "array", "items": {"type": "integer"}, "description": "kind=habit: optional weekday selection."},
                "target": {"type": "string", "description": "kind=milestone: ISO 8601 target."},
                "notes": {"type": "string", "description": "Free-form task notes."},
                "linked_block_id": {"type": "string", "description": "Optional source block."},
                "priority": {"type": "string"},
                "tag_ids": {"type": "array", "items": {"type": "string"}},
                "reminders": {"type": "array", "items": {"type": "object"}, "description": "[{trigger:'offset'|'absolute', offset|at}]."},
                "match_threshold": {"type": "number", "description": "Dedup cutoff, default 0.82."},
                "force_new": {"type": "boolean", "description": "Skip dedup, always create. Default false."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_upsert_task),
    },
    {
        "name": "geo_create_block",
        "description": (
            "Create a new block. Returns the new block id + frontmatter_version. "
            "Pass `folder` (e.g. 'Projects/ARC') to file it inside that folder — the "
            "folder is created if missing and the returned id is folder-prefixed "
            "(e.g. 'Projects/ARC/My-Block.md'). Omit `folder` for the vault root."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "body": {"type": "string"},
                "layer": {"type": "string", "description": "'fleeting' | 'literature' | 'permanent'."},
                "type": {"type": "string"},
                "status": {"type": "string"},
                "day_id": {"type": "string", "description": "Optional day record to attach to."},
                "tag_name": {"type": "string", "description": "Single tag to apply (server takes one tag, not an array)."},
                "folder": {"type": "string", "description": "Folder path to file the block under, e.g. 'Projects/ARC'. Created if missing."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_create_block),
    },
    {
        "name": "geo_move_block",
        "description": (
            "Move a block into a folder (or to the vault root). A block's id IS its path "
            "under the vault, so moving changes the id — the returned id is the new "
            "folder-prefixed path. Pass `folder` like 'Areas/Health'; the folder is "
            "created if missing. Pass folder='' or omit it to move the block to the root. "
            "Wikilinks ([[Title]]) keep resolving after a move since they match by title."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Current block id (path), e.g. 'My-Block.md' or 'Old/My-Block.md'."},
                "folder": {"type": "string", "description": "Destination folder path, or '' for the vault root."},
            },
            "required": ["id"],
        },
        "handler": _wrap(_move_block),
    },
    {
        "name": "geo_update_block",
        "description": (
            "Replace a block's full markdown body. `body` becomes the entire block content "
            "(not a partial patch). The server only reads id + content; title/type/status "
            "are NOT editable here. To change the layer use geo_set_layer; to change the tag "
            "use geo_set_block_tag."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "body": {"type": "string", "description": "Full replacement markdown body."},
            },
            "required": ["id", "body"],
        },
        "handler": _wrap(_update_block),
    },
    {
        "name": "geo_set_block_tag",
        "description": "Set a block's tag. A block carries a single tag; pass an empty tag_name to clear it.",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "tag_name": {"type": "string", "description": "Tag to set; empty string clears the tag."},
            },
            "required": ["id", "tag_name"],
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
        "description": (
            "Extract a permanent block from a source block. The server archives the source "
            "and creates a stub titled 'Extraído de [[<source title>]]'. Takes only the "
            "source `id` — you do not supply a title or body."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Source block id."},
            },
            "required": ["id"],
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
        "description": (
            "Create a task UNCONDITIONALLY (no dedup). Prefer geo_upsert_task. The shape "
            "depends on `kind`: task needs `due`; event needs `start`+`end`; habit needs "
            "`recurrence`+`time_of_day`; milestone needs `target`. All are ISO 8601."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "kind": {"type": "string", "description": "task|event|habit|milestone (default 'task')."},
                "due": {"type": "string", "description": "kind=task: ISO 8601 UTC due time."},
                "estimated_minutes": {"type": "integer", "description": "kind=task: estimate."},
                "start": {"type": "string", "description": "kind=event: ISO 8601 start."},
                "end": {"type": "string", "description": "kind=event: ISO 8601 end."},
                "recurrence": {"type": "string", "description": "kind=habit: daily|weekdays|weekly|biweekly|monthly|yearly."},
                "time_of_day": {"type": "string", "description": "kind=habit: ISO 8601 time-of-day."},
                "selected_weekdays": {"type": "array", "items": {"type": "integer"}, "description": "kind=habit: optional weekday selection."},
                "target": {"type": "string", "description": "kind=milestone: ISO 8601 target."},
                "notes": {"type": "string", "description": "Free-form task notes."},
                "linked_block_id": {"type": "string", "description": "Optional source block."},
                "priority": {"type": "string"},
                "tag_ids": {"type": "array", "items": {"type": "string"}},
                "reminders": {"type": "array", "items": {"type": "object"}, "description": "[{trigger:'offset'|'absolute', offset|at}]."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_create_task),
    },
    {
        "name": "geo_update_task",
        "description": (
            "Patch task fields. To reschedule, pass a full structured `body` "
            "{kind, due|start|end|recurrence|time_of_day|target}; alternatively pass `kind` "
            "plus the kind's fields and the body is built for you."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "title": {"type": "string"},
                "notes": {"type": "string"},
                "status": {"type": "string", "description": "pending|completed."},
                "priority": {"type": "string"},
                "linked_block_id": {"type": "string"},
                "tag_ids": {"type": "array", "items": {"type": "string"}},
                "kind": {"type": "string", "description": "task|event|habit|milestone (drives body rebuild)."},
                "due": {"type": "string"},
                "start": {"type": "string"},
                "end": {"type": "string"},
                "recurrence": {"type": "string"},
                "time_of_day": {"type": "string"},
                "target": {"type": "string"},
                "body": {"type": "object", "description": "Full structured body {kind, ...} for reschedule."},
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
        "description": (
            "Schedule a reminder for a task. trigger='absolute' fires at the ISO 8601 `at`; "
            "trigger='offset' fires at an `offset` relative to the task's anchor."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "trigger": {"type": "string", "description": "'absolute' (default) or 'offset'."},
                "at": {"type": "string", "description": "ISO 8601 datetime (trigger=absolute)."},
                "offset": {"type": "string", "description": "Offset enum value (trigger=offset)."},
            },
            "required": ["id"],
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
                "color": {
                    "type": "object",
                    "description": "Optional RGB color, floats 0..1: {red, green, blue}.",
                    "properties": {
                        "red": {"type": "number"},
                        "green": {"type": "number"},
                        "blue": {"type": "number"},
                    },
                },
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
