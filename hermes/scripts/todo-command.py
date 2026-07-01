#!/usr/bin/env python3
"""todo-command.py — /todo quick command for Gabriel.

Prints the open Geo items grouped the way the day is actually lived:
overdue tasks, then today (events · tasks · habits), then the next 7 days,
then milestones. No LLM call and no network — pure stdout for Hermes
`quick_commands.todo`, so Telegram `/todo` returns it directly.

All stored datetimes are ISO 8601 UTC; everything here is rendered in
Gabriel's timezone (GEO_TZ, default America/Sao_Paulo). End-of-day deadlines
are synthetic (23:59Z new rule / 02:59Z legacy = 23:59 local), so those times
are hidden — only real clock times are shown.
"""

from __future__ import annotations

import json
import os
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

GEO_TASKS_DIR = Path.home() / "Library" / "Application Support" / "Geo" / "Tasks"
LOCAL_TZ = ZoneInfo(os.environ.get("GEO_TZ", "America/Sao_Paulo"))
WEEKDAYS_PT = ("seg", "ter", "qua", "qui", "sex", "sáb", "dom")
UPCOMING_DAYS = 7
EOD_SUFFIXES = ("23:59:00Z", "02:59:00Z")


def _parse_utc(iso: str) -> datetime | None:
    try:
        return datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def _local(iso: str) -> datetime | None:
    dt = _parse_utc(iso)
    return dt.astimezone(LOCAL_TZ) if dt else None


def _day_label(d: date) -> str:
    return f"{WEEKDAYS_PT[d.weekday()]} {d.strftime('%d/%m')}"


def _time_if_real(iso: str) -> str:
    if not iso or iso.endswith(EOD_SUFFIXES):
        return ""
    dt = _local(iso)
    return dt.strftime("%H:%M") if dt else ""


def _habit_due_today(rule: dict, anchor: datetime | None, today: date) -> bool:
    rtype = rule.get("type") or "daily"
    end = rule.get("endDate")
    if end:
        end_local = _local(end)
        if end_local and today > end_local.date():
            return False
    weekday_apple = today.isoweekday() % 7 + 1
    selected = rule.get("selectedWeekdays")
    if selected:
        return weekday_apple in selected
    if rtype in ("daily", "custom"):
        return True
    if rtype == "weekdays":
        return today.weekday() < 5
    if not anchor:
        return True
    a = anchor.date()
    if rtype in ("weekly", "biweekly"):
        return today.weekday() == a.weekday()
    if rtype == "monthly":
        return today.day == a.day
    if rtype == "yearly":
        return (today.month, today.day) == (a.month, a.day)
    return False


def main() -> None:
    now = datetime.now(LOCAL_TZ)
    today = now.date()
    horizon = today + timedelta(days=UPCOMING_DAYS)

    overdue: list[tuple[date, str, str]] = []
    events_today: list[tuple[str, str]] = []
    tasks_today: list[tuple[str, str, str]] = []
    habits_today: list[tuple[bool, str, str]] = []
    upcoming: list[tuple[date, str]] = []
    milestones: list[tuple[date | None, str]] = []

    if GEO_TASKS_DIR.exists():
        for path in sorted(GEO_TASKS_DIR.glob("*.json")):
            try:
                t = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if t.get("status") != "pending":
                continue
            title = str(t.get("title") or "").strip()
            body = t.get("body") or {}
            kind = body.get("kind")
            if not title or not isinstance(body, dict):
                continue
            prio = " ‼️" if t.get("priority") in ("urgent", "high") else ""

            if kind == "task":
                due_local = _local(body.get("due") or "")
                due_day = due_local.date() if due_local else None
                clock = _time_if_real(body.get("due") or "")
                if due_day and due_day < today:
                    overdue.append((due_day, title, prio))
                elif due_day == today or due_day is None:
                    tasks_today.append((clock or "99:99", title + prio, clock))
                elif due_day <= horizon:
                    upcoming.append((due_day, f"{title}{prio}"))

            elif kind == "event":
                start, end = _local(body.get("start") or ""), _local(body.get("end") or "")
                if not start:
                    continue
                s_day, e_day = start.date(), (end.date() if end else start.date())
                if s_day <= today <= e_day:
                    if s_day == e_day:
                        span = start.strftime("%H:%M") + (f"–{end.strftime('%H:%M')}" if end else "")
                    else:
                        span = f"até {_day_label(e_day)}"
                    events_today.append((start.strftime("%H:%M"), f"{span}  {title}{prio}"))
                elif today < s_day <= horizon:
                    clock = _time_if_real(body.get("start") or "")
                    upcoming.append((s_day, f"{title}{prio}" + (f" ({clock})" if clock else "")))

            elif kind == "habit":
                anchor = _local(body.get("timeOfDay") or "")
                if not _habit_due_today(body.get("rule") or {}, anchor, today):
                    continue
                done = any(
                    (ld := _local(str(o))) and ld.date() == today
                    for o in (body.get("occurrences") or [])
                )
                clock = _time_if_real(body.get("timeOfDay") or "")
                habits_today.append((done, title, clock))

            elif kind == "milestone":
                tgt = _local(body.get("target") or "")
                milestones.append((tgt.date() if tgt else None, title))

    if not any((overdue, events_today, tasks_today, habits_today, upcoming, milestones)):
        print("Sem todos em aberto")
        return

    out: list[str] = [f"📅 {_day_label(today)}"]
    n = 0

    if overdue:
        out += ["", f"⏰ Atrasadas ({len(overdue)})"]
        for day, title, prio in sorted(overdue):
            n += 1
            out.append(f"{n}. {title}{prio} · venceu {_day_label(day)}")

    if events_today:
        out += ["", "🗓 Eventos de hoje"]
        for _, line in sorted(events_today):
            out.append(f"   {line}")

    if tasks_today:
        out += ["", "✅ Tarefas de hoje"]
        for _, line, clock in sorted(tasks_today):
            n += 1
            out.append(f"{n}. {line}" + (f" · {clock}" if clock else ""))

    if habits_today:
        out += ["", "🔁 Hábitos de hoje"]
        for done, title, clock in sorted(habits_today, key=lambda h: (h[0], h[2] or "99:99")):
            mark = "✓" if done else "○"
            out.append(f"   {mark} {title}" + (f" · {clock}" if clock and not done else ""))

    if upcoming:
        out += ["", f"📆 Próximos {UPCOMING_DAYS} dias"]
        for day, line in sorted(upcoming):
            out.append(f"   {_day_label(day)} · {line}")

    if milestones:
        out += ["", "🎯 Milestones"]
        for day, title in sorted(milestones, key=lambda m: m[0] or date.max):
            if day:
                left = (day - today).days
                when = f"{_day_label(day)} ({'faltam ' + str(left) + 'd' if left >= 0 else 'atrasado'})"
                out.append(f"   {title} · {when}")
            else:
                out.append(f"   {title}")

    print("\n".join(out))


if __name__ == "__main__":
    main()
