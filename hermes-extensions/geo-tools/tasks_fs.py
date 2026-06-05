"""File-native task CRUD + semantic-dedup engine for Gabriel's Geo vault.

Replaces the HTTP task path. Tasks are individual ``.json`` files under
``~/Library/Application Support/Geo/Tasks/<UUID>.json``; the file IS the task.
Geo.app's TasksStore runs a FileWatcher on that dir with a self-write grace
period, so an out-of-band atomic write is reconciled into its in-memory store
(last atomic-rename wins).

KEEP-COMPUTE split: these functions persist ONLY the durable fields. The app
still derives recurrence next-fire, streaks and habit expansion on read — this
module never advances ``timeOfDay`` nor recomputes streaks.

On-disk shape matches the Swift ``TaskItem`` Codable verbatim (top-level
camelCase, ``.iso8601`` dates WITHOUT fractional seconds via ``now_iso``):

    {id, title, notes, linkedBlockId?, status, priority, tagIds, orderIndex,
     estimatedMinutes?, createdAt, modifiedAt, body, reminders}

``body`` is the tagged-union TaskBody:
    task      {kind:"task", due, estimatedMinutes?}
    event     {kind:"event", start, end}
    habit     {kind:"habit", rule:{type, selectedWeekdays?}, timeOfDay, occurrences}
    milestone {kind:"milestone", target}

``reminders[]`` items: {id, trigger:{kind:"offset", offset} | {kind:"absolute",
date}, fired}.
"""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path
from typing import Any, Optional

from ._fs import TASKS_DIR, atomic_write_json, nfc, now_iso
from .client import GeoError
from .matching import rank

_KINDS = ("task", "event", "habit", "milestone")
_DEFAULT_OFFSET = "At time"
_RULE_TYPES = (
    "never", "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly", "custom",
)


def _new_uuid() -> str:
    return str(uuid.uuid4()).upper()


def _task_path(task_id: str) -> Path:
    return TASKS_DIR / f"{nfc(task_id).strip()}.json"


def _read_task(task_id: str) -> dict:
    path = _task_path(task_id)
    if not path.exists():
        raise GeoError(f"task not found: {task_id}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise GeoError(f"task unreadable: {task_id} ({e})")


def _iter_task_files() -> list[Path]:
    if not TASKS_DIR.exists():
        return []
    return sorted(TASKS_DIR.glob("*.json"))


def _load_all() -> list[dict]:
    out: list[dict] = []
    for p in _iter_task_files():
        try:
            out.append(json.loads(p.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            continue
    return out


def _load_pending() -> list[dict]:
    return [t for t in _load_all() if t.get("status") != "completed"]


def _next_order_index(tasks: list[dict]) -> int:
    indices = [int(t.get("orderIndex", 0)) for t in tasks]
    return (max(indices) + 1) if indices else 0


def _trigger(a: dict) -> dict:
    kind = a.get("trigger", "offset")
    if kind == "absolute":
        at = a.get("at") or a.get("date")
        if not at:
            raise GeoError("absolute trigger requires 'at' (ISO 8601)")
        return {"kind": "absolute", "date": at}
    return {"kind": "offset", "offset": a.get("offset") or _DEFAULT_OFFSET}


def _default_reminders() -> list[dict]:
    return [{"id": _new_uuid(), "trigger": {"kind": "offset", "offset": _DEFAULT_OFFSET}, "fired": False}]


def _normalize_reminders(items: Any) -> list[dict]:
    out: list[dict] = []
    for it in items or []:
        if not isinstance(it, dict):
            continue
        if isinstance(it.get("trigger"), dict) and "kind" in it["trigger"]:
            out.append({
                "id": it.get("id") or _new_uuid(),
                "trigger": it["trigger"],
                "fired": bool(it.get("fired", False)),
            })
        else:
            out.append({
                "id": it.get("id") or _new_uuid(),
                "trigger": _trigger(it),
                "fired": bool(it.get("fired", False)),
            })
    return out


def build_task_body(a: dict) -> dict:
    kind = a.get("kind") or "task"
    if kind not in _KINDS:
        kind = "task"
    body: dict[str, Any] = {"kind": kind}
    if kind == "task":
        if a.get("due") is not None:
            body["due"] = a["due"]
        if a.get("estimated_minutes") is not None:
            body["estimatedMinutes"] = a["estimated_minutes"]
        elif a.get("estimatedMinutes") is not None:
            body["estimatedMinutes"] = a["estimatedMinutes"]
    elif kind == "event":
        if a.get("start") is not None:
            body["start"] = a["start"]
        if a.get("end") is not None:
            body["end"] = a["end"]
    elif kind == "habit":
        rule_type = a.get("recurrence") or "daily"
        if rule_type not in _RULE_TYPES:
            rule_type = "daily"
        rule: dict[str, Any] = {"type": rule_type}
        weekdays = a.get("selected_weekdays") or a.get("selectedWeekdays")
        if weekdays:
            rule["selectedWeekdays"] = list(weekdays)
        body["rule"] = rule
        tod = a.get("time_of_day") or a.get("timeOfDay")
        if tod is not None:
            body["timeOfDay"] = tod
        body["occurrences"] = list(a.get("occurrences") or [])
    elif kind == "milestone":
        if a.get("target") is not None:
            body["target"] = a["target"]
    return body


def _notes_from(a: dict) -> str:
    notes = a.get("notes")
    if notes is None and isinstance(a.get("body"), str):
        notes = a["body"]
    return notes or ""


def create_task(a: dict) -> dict:
    ts = now_iso()
    task: dict[str, Any] = {
        "id": _new_uuid(),
        "title": a["title"],
        "notes": _notes_from(a),
        "status": a.get("status") or "pending",
        "priority": a.get("priority") or "unset",
        "tagIds": list(a.get("tag_ids") or a.get("tagIds") or a.get("tags") or []),
        "orderIndex": _next_order_index(_load_all()),
        "createdAt": ts,
        "modifiedAt": ts,
        "body": a["body"] if isinstance(a.get("body"), dict) else build_task_body(a),
    }
    linked = a.get("linked_block_id") or a.get("linkedBlockId") or a.get("block_id")
    if linked is not None:
        task["linkedBlockId"] = linked
    est = a.get("estimated_minutes") or a.get("estimatedMinutes")
    if est is not None:
        task["estimatedMinutes"] = est
    if a.get("reminders") is not None:
        task["reminders"] = _normalize_reminders(a["reminders"])
    else:
        task["reminders"] = _default_reminders()
    atomic_write_json(_task_path(task["id"]), task)
    return task


def update_task(a: dict) -> dict:
    task = _read_task(a["id"])
    for k in ("title", "notes", "status", "priority"):
        if k in a and a[k] is not None:
            task[k] = a[k]
    linked = a.get("linked_block_id") or a.get("linkedBlockId") or a.get("block_id")
    if linked is not None:
        task["linkedBlockId"] = linked
    tag_ids = a.get("tag_ids") or a.get("tagIds") or a.get("tags")
    if tag_ids is not None:
        task["tagIds"] = list(tag_ids)
    if isinstance(a.get("body"), dict):
        task["body"] = a["body"]
    elif a.get("kind") is not None:
        task["body"] = build_task_body(a)
    if a.get("reminders") is not None:
        task["reminders"] = _normalize_reminders(a["reminders"])
    task["modifiedAt"] = now_iso()
    atomic_write_json(_task_path(task["id"]), task)
    return task


def complete_task(task_id: str) -> dict:
    task = _read_task(task_id)
    task["status"] = "completed"
    task["modifiedAt"] = now_iso()
    atomic_write_json(_task_path(task["id"]), task)
    return task


def add_reminder(a: dict) -> dict:
    task = _read_task(a["id"])
    reminder = {"id": _new_uuid(), "trigger": _trigger(a), "fired": False}
    task.setdefault("reminders", []).append(reminder)
    task["modifiedAt"] = now_iso()
    atomic_write_json(_task_path(task["id"]), task)
    return {"id": task["id"], "reminder": reminder}


def _occurrence_day(at: Any) -> str:
    if isinstance(at, str) and at:
        return at[:10]
    return now_iso()[:10]


def record_habit_occurrence(a: dict) -> dict:
    task_id = a.get("habit_id") or a.get("id")
    if not task_id:
        raise GeoError("record_habit_occurrence requires habit_id")
    task = _read_task(task_id)
    body = task.get("body") or {}
    if body.get("kind") != "habit":
        raise GeoError(f"task is not a habit: {task_id}")
    when = a.get("at") or a.get("date") or now_iso()
    day = _occurrence_day(when)
    occurrences = list(body.get("occurrences") or [])
    if not any(_occurrence_day(o) == day for o in occurrences):
        occurrences.append(when)
    body["occurrences"] = occurrences
    task["body"] = body
    task["reminders"] = [
        {**r, "fired": False} for r in (task.get("reminders") or [])
    ]
    task["modifiedAt"] = now_iso()
    atomic_write_json(_task_path(task["id"]), task)
    return task


def delete_task(task_id: str) -> dict:
    path = _task_path(task_id)
    if not path.exists():
        raise GeoError(f"task not found: {task_id}")
    os.remove(path)
    return {"deleted": nfc(task_id).strip()}


def get_task(task_id: str) -> dict:
    return _read_task(task_id)


def _body_kind(task: dict) -> Optional[str]:
    body = task.get("body")
    return body.get("kind") if isinstance(body, dict) else None


def list_tasks(a: dict) -> list[dict]:
    status = a.get("status")
    kind = a.get("kind")
    priority = a.get("priority")
    linked = a.get("linked_block_id") or a.get("linkedBlockId")
    out = []
    for t in _load_all():
        if status is not None and t.get("status") != status:
            continue
        if kind is not None and _body_kind(t) != kind:
            continue
        if priority is not None and t.get("priority") != priority:
            continue
        if linked is not None and t.get("linkedBlockId") != linked:
            continue
        out.append(t)
    return out


def _anchor(task: dict) -> Optional[str]:
    body = task.get("body")
    if not isinstance(body, dict):
        return None
    kind = body.get("kind")
    if kind == "task":
        return body.get("due")
    if kind == "event":
        return body.get("start")
    if kind == "milestone":
        return body.get("target")
    if kind == "habit":
        return body.get("timeOfDay")
    return None


def list_tasks_for_day(day: str) -> list[dict]:
    day = nfc(day).strip()[:10]
    out = []
    for t in _load_all():
        anchor = _anchor(t)
        if anchor and anchor[:10] == day:
            out.append(t)
    return out


def _window_seconds(window: Optional[str]) -> int:
    if not window:
        return 24 * 3600
    w = window.strip().lower()
    try:
        if w.endswith("h"):
            return int(w[:-1]) * 3600
        if w.endswith("d"):
            return int(w[:-1]) * 86400
        return int(w) * 3600
    except ValueError:
        return 24 * 3600


def list_upcoming(a: dict) -> list[dict]:
    from datetime import datetime, timedelta, timezone

    now = datetime.now(timezone.utc)
    horizon = now + timedelta(seconds=_window_seconds(a.get("window")))
    limit = a.get("limit")
    hits: list[tuple[datetime, dict]] = []
    for t in _load_all():
        if t.get("status") == "completed":
            continue
        anchor = _anchor(t)
        if not anchor:
            continue
        try:
            dt = datetime.strptime(anchor[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if now <= dt <= horizon:
            hits.append((dt, t))
    hits.sort(key=lambda x: x[0])
    tasks = [t for _, t in hits]
    return tasks[: int(limit)] if limit is not None else tasks


def _view(task: dict) -> dict:
    out = {
        "id": task.get("id"),
        "title": task.get("title"),
        "status": task.get("status"),
        "kind": _body_kind(task),
        "anchor": _anchor(task),
    }
    if task.get("linkedBlockId") is not None:
        out["linked_block_id"] = task["linkedBlockId"]
    if "score" in task:
        out["score"] = task["score"]
    return out


def find_tasks(a: dict) -> dict:
    pool = _load_all() if a.get("include_completed") else _load_pending()
    ranked = rank(a["query"], pool, limit=int(a.get("limit", 5)))
    return {"matches": [_view(t) for t in ranked]}


def resolve_task(a: dict) -> dict:
    pool = _load_all() if a.get("include_completed") else _load_pending()
    ranked = rank(a["query"], pool)
    if not ranked:
        return {"matched": False, "candidates": []}
    best = ranked[0]
    second = ranked[1]["score"] if len(ranked) > 1 else 0.0
    clear = len(ranked) == 1 or best["score"] >= second + 0.15
    if best["score"] >= 0.6 and clear:
        return {"matched": True, "task": _view(best), "score": best["score"]}
    return {"matched": False, "candidates": [_view(t) for t in ranked[:3]]}


def upsert_task(a: dict) -> dict:
    threshold = float(a.get("match_threshold", 0.82))
    if not bool(a.get("force_new", False)):
        ranked = rank(a["title"], _load_pending())
        if ranked:
            best = ranked[0]
            kind_ok = a.get("kind") in (None, _body_kind(best))
            if best["score"] >= threshold and kind_ok:
                updated = update_task({**a, "id": best["id"]})
                return {"action": "updated", "task": updated, "matched_score": best["score"]}
    created = create_task(a)
    return {"action": "created", "task": created}
