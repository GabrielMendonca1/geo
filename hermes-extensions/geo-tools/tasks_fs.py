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

    {id, title, linkedBlockId?, status, priority, tagIds, orderIndex,
     estimatedMinutes?, createdAt, modifiedAt, body, reminders}

Tasks carry no prose: a stale ``notes`` key in an old file is ignored, never
written. The work surface is the linked block (markdown checkboxes).

``body`` is the tagged-union TaskBody:
    task      {kind:"task", due, estimatedMinutes?}
    event     {kind:"event", start, end}
    habit     {kind:"habit", rule:{type, selectedWeekdays?}, timeOfDay, occurrences}
    milestone {kind:"milestone", target}

``reminders[]`` items: {id, trigger:{kind:"offset", offset} | {kind:"absolute",
date}, fired}.
"""

from __future__ import annotations

import calendar
import json
import os
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional
from zoneinfo import ZoneInfo

from ._fs import TASKS_DIR, atomic_write_json, nfc, now_iso
from .client import GeoError
from .matching import rank

LOCAL_TZ = ZoneInfo(os.environ.get("GEO_TZ", "America/Sao_Paulo"))

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
        return {"kind": "absolute", "date": _normalize_anchor(at)}
    return {"kind": "offset", "offset": a.get("offset") or _DEFAULT_OFFSET}


_EOD_SUFFIXES = ("23:59:00Z", "02:59:00Z")


def _default_reminders(body: Optional[dict] = None) -> list[dict]:
    """Default reminder is 'at time' — except for synthetic end-of-day anchors
    (date-only deadlines), where firing at 20:59/23:59 local is useless noise;
    those get an absolute 09:00-local reminder on the due day instead."""
    trigger: dict[str, Any] = {"kind": "offset", "offset": _DEFAULT_OFFSET}
    anchor = (body or {}).get("due") or (body or {}).get("target")
    if isinstance(anchor, str) and anchor.endswith(_EOD_SUFFIXES):
        day = _local_day(anchor)
        if day:
            morning = datetime.strptime(day, "%Y-%m-%d").replace(hour=9, tzinfo=LOCAL_TZ)
            if morning > datetime.now(LOCAL_TZ):
                iso = morning.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                trigger = {"kind": "absolute", "date": iso}
    return [{"id": _new_uuid(), "trigger": trigger, "fired": False}]


def _normalize_reminders(items: Any) -> list[dict]:
    out: list[dict] = []
    for it in items or []:
        if not isinstance(it, dict):
            continue
        if isinstance(it.get("trigger"), dict) and "kind" in it["trigger"]:
            trig = it["trigger"]
            if trig.get("kind") == "absolute" and trig.get("date"):
                trig = {**trig, "date": _normalize_anchor(trig["date"])}
            out.append({
                "id": it.get("id") or _new_uuid(),
                "trigger": trig,
                "fired": bool(it.get("fired", False)),
            })
        else:
            out.append({
                "id": it.get("id") or _new_uuid(),
                "trigger": _trigger(it),
                "fired": bool(it.get("fired", False)),
            })
    return out


def _normalize_anchor(value: Any) -> Any:
    """Data-only ou sentinela 00:00/23:59 → fim-do-dia local em ISO UTC (o app espelha
    como all-day); hora real preservada. Garante ISO decodável pelo Swift (.iso8601)."""
    if not isinstance(value, str) or not value.strip():
        return value
    s = value.strip()
    try:
        if len(s) == 10:
            d = datetime.strptime(s, "%Y-%m-%d").replace(hour=23, minute=59, tzinfo=LOCAL_TZ)
            return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        p = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if p.tzinfo is None:
            p = p.replace(tzinfo=LOCAL_TZ)
        if (p.hour == 0 and p.minute == 0) or (p.hour == 23 and p.minute == 59):
            d = datetime(p.year, p.month, p.day, 23, 59, tzinfo=LOCAL_TZ)
            return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        return p.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return value


def _is_all_day(body: dict) -> bool:
    anchor = body.get("due") or body.get("start") or body.get("target") or body.get("timeOfDay")
    return isinstance(anchor, str) and anchor.endswith(_EOD_SUFFIXES)


def build_task_body(a: dict) -> dict:
    kind = a.get("kind") or "task"
    if kind not in _KINDS:
        kind = "task"
    body: dict[str, Any] = {"kind": kind}
    if kind == "task":
        if a.get("due") is not None:
            body["due"] = _normalize_anchor(a["due"])
        if a.get("estimated_minutes") is not None:
            body["estimatedMinutes"] = a["estimated_minutes"]
        elif a.get("estimatedMinutes") is not None:
            body["estimatedMinutes"] = a["estimatedMinutes"]
    elif kind == "event":
        if a.get("start") is not None:
            body["start"] = _normalize_anchor(a["start"])
        if a.get("end") is not None:
            body["end"] = _normalize_anchor(a["end"])
    elif kind == "habit":
        rule_type = a.get("recurrence") or "daily"
        if rule_type not in _RULE_TYPES:
            rule_type = "daily"
        rule: dict[str, Any] = {"type": rule_type}
        weekdays = a.get("selected_weekdays") or a.get("selectedWeekdays")
        if weekdays:
            rule["selectedWeekdays"] = list(weekdays)
        end_date = a.get("recurrence_end_date") or a.get("recurrenceEndDate")
        if end_date:
            rule["endDate"] = end_date
        body["rule"] = rule
        tod = a.get("time_of_day") or a.get("timeOfDay")
        if tod is not None:
            body["timeOfDay"] = _normalize_anchor(tod)
        body["occurrences"] = list(a.get("occurrences") or [])
    elif kind == "milestone":
        if a.get("target") is not None:
            body["target"] = _normalize_anchor(a["target"])
    return body


def _create_single(a: dict, body: dict) -> dict:
    ts = now_iso()
    task: dict[str, Any] = {
        "id": _new_uuid(),
        "title": a["title"],
        "status": a.get("status") or "pending",
        "priority": a.get("priority") or "unset",
        "tagIds": list(a.get("tag_ids") or a.get("tagIds") or a.get("tags") or []),
        "orderIndex": _next_order_index(_load_all()),
        "createdAt": ts,
        "modifiedAt": ts,
        "body": body,
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
        task["reminders"] = _default_reminders(body)
    task["isAllDay"] = _is_all_day(body)
    atomic_write_json(_task_path(task["id"]), task)
    return task


_SERIES_MAX = 26


def _shift_dt(dt: datetime, days: int = 0, months: int = 0) -> datetime:
    if months:
        y = dt.year + (dt.month - 1 + months) // 12
        m = (dt.month - 1 + months) % 12 + 1
        dt = dt.replace(year=y, month=m, day=min(dt.day, calendar.monthrange(y, m)[1]))
    return dt + timedelta(days=days)


def _series_offsets(rec: str, start_iso: str, until_iso: str) -> list[tuple[int, int]]:
    """(days, months) offsets for each instance of a recurring event, instance 0
    included, bounded by until_iso and _SERIES_MAX."""
    base = datetime.strptime(start_iso[:19], "%Y-%m-%dT%H:%M:%S")
    if len(until_iso) == 10:
        until_iso += "T23:59:59Z"
    try:
        until = datetime.strptime(until_iso[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        raise GeoError(f"bad recurrence_end_date: {until_iso}")
    out: list[tuple[int, int]] = [(0, 0)]
    if rec in ("daily", "weekdays"):
        d = 0
        while len(out) < _SERIES_MAX:
            d += 1
            nxt = base + timedelta(days=d)
            if nxt > until:
                break
            if rec == "weekdays" and nxt.weekday() >= 5:
                continue
            out.append((d, 0))
    elif rec in ("weekly", "biweekly"):
        step = 7 if rec == "weekly" else 14
        d = 0
        while len(out) < _SERIES_MAX:
            d += step
            if base + timedelta(days=d) > until:
                break
            out.append((d, 0))
    elif rec in ("monthly", "yearly"):
        step = 1 if rec == "monthly" else 12
        m = 0
        while len(out) < _SERIES_MAX:
            m += step
            if _shift_dt(base, months=m) > until:
                break
            out.append((0, m))
    else:
        raise GeoError(f"unsupported event recurrence: {rec}")
    return out


def _shift_iso(iso: str, days: int, months: int) -> str:
    dt = datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S")
    return _shift_dt(dt, days=days, months=months).strftime("%Y-%m-%dT%H:%M:%SZ")


def _create_event_series(a: dict, body: dict) -> dict:
    """The app has no recurring-event model, so a recurring event is expanded
    into real bounded instances — each a normal event the app renders natively."""
    start, end = body.get("start"), body.get("end")
    if not start or not end:
        raise GeoError("recurring event needs start and end")
    until = a.get("recurrence_end_date") or a.get("recurrenceEndDate")
    if not until:
        raise GeoError(
            "recurring event needs recurrence_end_date to bound the series "
            f"(max {_SERIES_MAX} instances)"
        )
    created = []
    for days, months in _series_offsets(a["recurrence"], start, str(until)):
        inst = dict(body)
        inst["start"] = _shift_iso(start, days, months)
        inst["end"] = _shift_iso(end, days, months)
        created.append(_create_single(a, inst))
    return {
        "action": "created_series",
        "count": len(created),
        "ids": [t["id"] for t in created],
        "first": created[0],
    }


def create_task(a: dict) -> dict:
    body = a["body"] if isinstance(a.get("body"), dict) else build_task_body(a)
    if body.get("kind") == "event" and a.get("recurrence"):
        return _create_event_series(a, body)
    return _create_single(a, body)


_SCHED_KEYS = (
    "due", "estimated_minutes", "estimatedMinutes", "start", "end",
    "recurrence", "time_of_day", "timeOfDay", "selected_weekdays",
    "selectedWeekdays", "recurrence_end_date", "recurrenceEndDate", "target",
)


def _body_to_args(body: dict) -> dict:
    """Stored TaskBody → build_task_body args, so updates can merge instead of
    wiping fields the caller didn't pass."""
    args: dict[str, Any] = {"kind": body.get("kind")}
    for k in ("due", "start", "end", "target"):
        if body.get(k) is not None:
            args[k] = body[k]
    if body.get("estimatedMinutes") is not None:
        args["estimated_minutes"] = body["estimatedMinutes"]
    if body.get("timeOfDay") is not None:
        args["time_of_day"] = body["timeOfDay"]
    if body.get("occurrences"):
        args["occurrences"] = body["occurrences"]
    rule = body.get("rule") or {}
    if rule.get("type"):
        args["recurrence"] = rule["type"]
    if rule.get("selectedWeekdays"):
        args["selected_weekdays"] = rule["selectedWeekdays"]
    if rule.get("endDate"):
        args["recurrence_end_date"] = rule["endDate"]
    return args


def update_task(a: dict) -> dict:
    task = _read_task(a["id"])
    for k in ("title", "status", "priority"):
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
    else:
        kind = a.get("kind")
        existing = task.get("body") if isinstance(task.get("body"), dict) else None
        if kind is not None or any(a.get(k) is not None for k in _SCHED_KEYS):
            if existing and kind in (None, existing.get("kind")):
                merged = _body_to_args(existing)
                merged.update({k: a[k] for k in _SCHED_KEYS if a.get(k) is not None})
                task["body"] = build_task_body(merged)
            else:
                task["body"] = build_task_body(a)
    if a.get("reminders") is not None:
        task["reminders"] = _normalize_reminders(a["reminders"])
    task["modifiedAt"] = now_iso()
    atomic_write_json(_task_path(task["id"]), task)
    return task


def set_linked_block(task_id: str, block_id: str) -> dict:
    task = _read_task(task_id)
    task["linkedBlockId"] = block_id
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


def _local_day(iso: Any) -> Optional[str]:
    """Calendar day of an ISO 8601 UTC timestamp in Gabriel's timezone —
    matches how the app (local Calendar) buckets days."""
    if not isinstance(iso, str) or len(iso) < 10:
        return None
    try:
        dt = datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return iso[:10]
    return dt.astimezone(LOCAL_TZ).strftime("%Y-%m-%d")


def _occurrence_day(at: Any) -> str:
    return _local_day(at) or _local_day(now_iso()) or now_iso()[:10]


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
        if anchor and _local_day(anchor) == day:
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
    if created.get("action") == "created_series":
        return created
    return {"action": "created", "task": created}
