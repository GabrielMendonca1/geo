"""Write tool handlers for Geo — fully file-native (the vault is truth).

BLOCK writers are native filesystem ops: a block IS its ``.md`` file under
``~/Vault/Blocks/`` with YAML frontmatter
(id/type/status/layer/tags) + an inline ``[[YYYY-MM-DD]]`` day-link. The
``guard`` module enforces ``BlockLayer.allowsAgentWrites`` — agents may write
only agent/review/shared blocks, never user (Você). TASK writers delegate to
``tasks_fs`` (``Tasks/*.json``). The Geo.app FileWatcher reconciles the derived
SQLite index — no HTTP call is needed for the app to see a native write.

Destructive ops (delete_*) live in ``destructive.py``.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import unicodedata
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Optional

from . import geo_write, guard, tasks_fs
from .client import GeoError
from .geo_write import _GeoError


def _err(msg: str) -> str:
    return json.dumps({"error": msg})


def _ok(payload: Any) -> str:
    return json.dumps({"ok": True, "data": payload}, default=str)


def _wrap(handler: Callable[[dict], Any]) -> Callable:
    async def _entry(args: dict, **_kw: Any) -> str:
        try:
            result = await handler(args or {})
            return _ok(result)
        except GeoError as e:
            return _err(str(e))
        except Exception as e:
            return _err(f"{type(e).__name__}: {e}")
    return _entry


# --- Native filesystem block ops (files are truth) -------------------------

BLOCKS_DIR = Path.home() / "Vault" / "Blocks"
_SANITIZE_RE = re.compile(r'[/:\\*?"<>|]')
_TYPES = ("fleeting", "literature", "permanent", "moc", "project")
_LAYERS = ("user", "agent", "review", "shared")


def _nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s)


def _canonical_tag(name: str) -> str:
    return _nfc((name or "").strip().lower())


def _sanitize_filename(title: str) -> str:
    name = _SANITIZE_RE.sub("-", title or "")
    name = " ".join(name.split()).strip(" -")
    return _nfc(name) or "Block"


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def _emit_inline_list(items: list[str]) -> str:
    return "[" + ", ".join(items) + "]"


def _build_frontmatter(
    block_id: str,
    type_: str,
    status: Optional[str],
    layer: str,
    tags: list[str],
    full_width: bool,
) -> str:
    lines = [f"id: {block_id}", f"type: {type_}"]
    if status:
        lines.append(f"status: {status}")
    lines.append(f"layer: {layer}")
    if tags:
        lines.append(f"tags: {_emit_inline_list(tags)}")
    if full_width:
        lines.append("full_width: true")
    return "---\n" + "\n".join(lines) + "\n---\n"


def _block_path(block_id: str) -> Path:
    rel = block_id if block_id.endswith(".md") else f"{block_id}.md"
    return BLOCKS_DIR / rel


def _resolve_path(block_id: str) -> Path:
    p = _block_path(block_id)
    if not p.exists():
        raise GeoError(f"block not found: {block_id}")
    return p


def _unique_path(folder: Path, slug: str) -> Path:
    candidate = folder / f"{slug}.md"
    n = 1
    while candidate.exists():
        candidate = folder / f"{slug}-{n}.md"
        n += 1
    return candidate


def _rel_id(path: Path) -> str:
    return _nfc(str(path.relative_to(BLOCKS_DIR)))


def _today_token() -> str:
    return datetime.now().strftime("%Y-%m-%d")


def _ensure_day_link(body: str, date: str) -> str:
    token = f"[[{date}]]"
    if token in body:
        return body
    if body and not body.endswith("\n"):
        body += "\n"
    return body + token + "\n"


def _split_frontmatter(text: str) -> tuple[str, str]:
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[: end + 5], text[end + 5 :]
    return "", text


def _read_block(path: Path) -> tuple[str, str]:
    return _split_frontmatter(path.read_text(encoding="utf-8"))


def _edit_frontmatter_field(fm: str, key: str, value: Optional[str]) -> str:
    if not fm:
        fm = "---\n---\n"
    body_lines = fm.split("\n")
    inner = body_lines[1:-2] if len(body_lines) >= 3 else []
    out: list[str] = []
    replaced = False
    for line in inner:
        if line.startswith(f"{key}:"):
            if value is not None:
                out.append(f"{key}: {value}")
            replaced = True
        else:
            out.append(line)
    if value is not None and not replaced:
        out.append(f"{key}: {value}")
    return "---\n" + "\n".join(out) + "\n---\n"


async def _create_block(a: dict) -> Any:
    title = a["title"]
    type_ = a.get("type") or "fleeting"
    if type_ not in _TYPES:
        type_ = "fleeting"
    layer = a.get("layer") or "agent"
    if layer not in _LAYERS:
        layer = "agent"
    tags: list[str] = []
    if a.get("tag_name"):
        tags = [_canonical_tag(a["tag_name"])]
    body = a.get("body", "") or ""
    try:
        created = await asyncio.to_thread(
            geo_write.write_block,
            writer="geo-agent",
            title=title,
            body=body,
            type=type_,
            layer=layer,
            tags=tags,
            force_new=bool(a.get("force_new", False)),
            folder=a.get("folder"),
            day_id=a.get("day_id"),
            status=a.get("status"),
            human_approved=False,
        )
    except _GeoError as error:
        if getattr(error, "reason", None) == "title_dup":
            raise GeoError(
                f"bloco duplicado: existing_id={getattr(error, 'id', None)}"
            ) from None
        match = re.search(r"bloco duplicado: id=([^,\s]+)", str(error))
        if match:
            raise GeoError(f"bloco duplicado: existing_id={match.group(1)}") from None
        raise
    return {"id": _rel_id(Path(created["path"]))}


async def _move_block(a: dict) -> Any:
    src = _resolve_path(a["id"])
    guard.assert_writable(src)
    folder = (a.get("folder") or "").strip("/")
    guard.assert_create_layer("agent", folder)
    dest_dir = BLOCKS_DIR / folder if folder else BLOCKS_DIR
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = _unique_path(dest_dir, src.stem) if (dest_dir / src.name).exists() else dest_dir / src.name
    shutil.move(str(src), str(dest))
    attach = src.parent / "Attachments" / src.stem
    if attach.is_dir():
        new_attach = dest.parent / "Attachments" / dest.stem
        new_attach.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(attach), str(new_attach))
    return {"id": _rel_id(dest)}


async def _update_block(a: dict) -> Any:
    path = _resolve_path(a["id"])
    guard.assert_writable(path)
    fm, _ = _read_block(path)
    _atomic_write(path, fm + a["body"])
    return {"id": _rel_id(path)}


async def _set_block_tag(a: dict) -> Any:
    path = _resolve_path(a["id"])
    guard.assert_writable(path)
    fm, body = _read_block(path)
    name = _canonical_tag(a.get("tag_name", ""))
    value = _emit_inline_list([name]) if name else None
    fm = _edit_frontmatter_field(fm, "tags", value)
    _atomic_write(path, fm + body)
    return {"id": _rel_id(path), "tags": [name] if name else []}


async def _set_layer(a: dict) -> Any:
    path = _resolve_path(a["id"])
    layer = a["layer"]
    if layer not in _LAYERS:
        raise GeoError(f"invalid layer '{layer}' (user|agent|review|shared)")
    guard.assert_writable(path)
    guard.assert_set_layer(layer)
    fm, body = _read_block(path)
    fm = _edit_frontmatter_field(fm, "layer", layer)
    _atomic_write(path, fm + body)
    return {"id": _rel_id(path), "layer": layer}


async def _promote_to_permanent(a: dict) -> Any:
    path = _resolve_path(a["id"])
    guard.assert_writable(path)
    fm, body = _read_block(path)
    fm = _edit_frontmatter_field(fm, "type", "permanent")
    _atomic_write(path, fm + body)
    return {"id": _rel_id(path), "type": "permanent"}


async def _extract_permanent_from(a: dict) -> Any:
    src = _resolve_path(a["id"])
    src_title = src.stem.replace("-", " ")
    slug = _sanitize_filename(f"Extraído de {src.stem}")
    dest = _unique_path(BLOCKS_DIR, slug)
    fm = _build_frontmatter(
        str(uuid.uuid4()).upper(), "permanent", None, "agent", [], False,
    )
    body = f"# Extraído de [[{src_title}]]\n"
    body = _ensure_day_link(body, _today_token())
    _atomic_write(dest, fm + body)
    return {"id": _rel_id(dest), "source": _rel_id(src)}


async def _link_block_to_day(a: dict) -> Any:
    path = _resolve_path(a["block_id"])
    guard.assert_writable(path)
    fm, body = _read_block(path)
    body = _ensure_day_link(body, a["day"])
    _atomic_write(path, fm + body)
    return {"id": _rel_id(path), "day": a["day"]}


# --- Task ops (file-native via tasks_fs; KEEP-COMPUTE stays app-side) -------


async def _create_task(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.create_task, a)


async def _update_task(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.update_task, a)


async def _complete_task(a: dict) -> Any:
    return await asyncio.to_thread(
        geo_write.update_task,
        writer="geo-agent",
        task_id=a["id"],
        op="complete",
    )


async def _add_reminder(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.add_reminder, a)


async def _record_habit_occurrence(a: dict) -> Any:
    return await asyncio.to_thread(
        geo_write.add_occurrence,
        writer="geo-agent",
        habit_id=a.get("habit_id") or a.get("id"),
        at=a.get("at"),
    )


async def _find_tasks(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.find_tasks, a)


async def _resolve_task(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.resolve_task, a)


async def _upsert_task(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.upsert_task, a)


_TODO_UNCHECKED_RE = re.compile(r"^(\s*)- \[ \] (.+)$")


def _fold(s: str) -> str:
    d = unicodedata.normalize("NFD", s.casefold())
    return "".join(c for c in d if not unicodedata.combining(c))


async def _task_todos(a: dict) -> Any:
    task = await asyncio.to_thread(tasks_fs.get_task, a["task_id"])
    linked = task.get("linkedBlockId")
    created_block = False
    if linked:
        path = _resolve_path(linked)
    else:
        created = await _create_block({"title": task["title"], "force_new": True})
        linked = created["id"]
        path = _resolve_path(linked)
        created_block = True
        await asyncio.to_thread(tasks_fs.set_linked_block, task["id"], linked)
    guard.assert_writable(path)
    fm, body = _read_block(path)
    lines = body.split("\n")
    checked: list[str] = []
    not_found: list[str] = []
    for needle in a.get("check") or []:
        want = _fold(str(needle))
        for i, line in enumerate(lines):
            m = _TODO_UNCHECKED_RE.match(line)
            if m and want and want in _fold(m.group(2)):
                lines[i] = f"{m.group(1)}- [x] {m.group(2)}"
                checked.append(m.group(2))
                break
        else:
            not_found.append(str(needle))
    body = "\n".join(lines)
    added: list[str] = []
    for item in a.get("items") or []:
        text = str(item.get("text", "") if isinstance(item, dict) else item).strip()
        if not text:
            continue
        mark = "x" if isinstance(item, dict) and item.get("done") else " "
        added.append(f"- [{mark}] {text}")
    log = str(a.get("log") or "").strip()
    addition = "\n".join(added + ([log] if log else []))
    if checked:
        _atomic_write(path, fm + body)
    if addition:
        await asyncio.to_thread(
            geo_write.append_block,
            writer="geo-agent",
            block_path_or_id=path,
            lines=addition,
        )
    out: dict[str, Any] = {
        "task_id": task["id"],
        "block_id": _rel_id(path),
        "added": added,
        "checked": checked,
    }
    if not_found:
        out["not_found"] = not_found
    if created_block:
        out["created_block"] = True
    return out


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
            "ask which one. Use before geo_complete_task / geo_delete_task when you only "
            "know the task by description; to edit fields, re-upsert via geo_upsert_task."
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
            "Gabriel's scheduler — the ONE tool that puts anything on his agenda: a task "
            "(to-do with a deadline), an event (happens at a time), a habit (recurring "
            "routine), or a milestone (outcome with a target date). `kind` decides which "
            "fields apply. Find-or-create with dedup: fuzzy-searches pending tasks first; "
            "a close title match (score >= match_threshold, default 0.82, same kind) is "
            "UPDATED and returns {action: 'updated', task, matched_score}; otherwise it "
            "creates and returns {action: 'created', task}. Editing (reschedule, retitle, "
            "reprioritize) = re-upsert the same title with the new fields. force_new=true "
            "skips dedup for a deliberate duplicate. A task is a PURE SCHEDULING RECORD — "
            "title, kind, dates, priority, tags. It carries NO prose: any content, "
            "context, progress, or research goes in its linked block as checkboxes via "
            "geo_task_todos, never in the title or a chat restatement."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "kind": {"type": "string", "description": "task|event|habit|milestone (default 'task'). task = one-shot to-do Gabriel must DO by a deadline. event = something that HAPPENS at a specific time (meeting, call, appointment, trip) — needs start+end. habit = recurring routine ('todo dia', 'every week') — never model recurring things as repeated tasks. milestone = outcome/goal to HIT by a target date (launch, delivery), not an action item."},
                "due": {"type": "string", "description": "kind=task: hora LOCAL de Gabriel (America/Sao_Paulo), naive, SEM 'Z' nem offset — 'YYYY-MM-DDTHH:MM:SS'. O código converte pra UTC; NÃO faça a conta de fuso. Ex.: 18:00 → '2026-06-22T18:00:00'. Sem horário → só a data 'YYYY-MM-DD' (o sistema põe no fim do dia)."},
                "estimated_minutes": {"type": "integer", "description": "kind=task: estimate."},
                "start": {"type": "string", "description": "kind=event: início em hora LOCAL naive 'YYYY-MM-DDTHH:MM:SS' (sem 'Z'). Ex.: 15h → '2026-06-22T15:00:00'. Nunca invente hora que Gabriel não disse — use uma redonda ou pergunte."},
                "end": {"type": "string", "description": "kind=event: fim em hora LOCAL naive (sem 'Z'). Sem duração → start + 1h. Período de vários dias ('de seg a qua') → start = primeiro dia, end = último dia (só a data 'YYYY-MM-DD')."},
                "recurrence": {"type": "string", "description": "daily|weekdays|weekly|biweekly|monthly|yearly. kind=habit: the repeat rule. kind=event: expands into a SERIES of real event instances (requires recurrence_end_date, max 26) — use for recurring meetings, not a habit."},
                "time_of_day": {"type": "string", "description": "kind=habit: hora LOCAL naive; só o horário importa (a data é ignorada). Ex.: 07:00 → '2026-06-22T07:00:00' (sem 'Z')."},
                "selected_weekdays": {"type": "array", "items": {"type": "integer"}, "description": "kind=habit: optional weekday selection (1=Sun … 7=Sat)."},
                "recurrence_end_date": {"type": "string", "description": "data LOCAL 'YYYY-MM-DD' — para de repetir depois dela. Opcional p/ kind=habit, OBRIGATÓRIO p/ evento recorrente."},
                "target": {"type": "string", "description": "kind=milestone: data-alvo LOCAL 'YYYY-MM-DD' (ou 'YYYY-MM-DDTHH:MM:SS' naive sem 'Z' se tiver hora). Sem hora → só a data."},
                "linked_block_id": {"type": "string", "description": "Optional source block."},
                "priority": {"type": "string"},
                "tag_ids": {"type": "array", "items": {"type": "string"}},
                "reminders": {"type": "array", "items": {"type": "object"}, "description": "[{trigger:'offset'|'absolute', offset|at}]. at = hora LOCAL naive 'YYYY-MM-DDTHH:MM:SS' (sem 'Z')."},
                "match_threshold": {"type": "number", "description": "Dedup cutoff, default 0.82."},
                "force_new": {"type": "boolean", "description": "Skip dedup, always create. Default false."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_upsert_task),
    },
    {
        "name": "geo_task_todos",
        "description": (
            "THE work surface of a task. Tasks carry no prose — all content, context, "
            "progress, next steps, and research live in the task's linked block as "
            "markdown checkboxes ('- [ ]' / '- [x]') that Gabriel sees and toggles in "
            "the app. This tool appends checkbox items and/or checks off existing ones "
            "on that block, creating the block first (agent layer, titled after the "
            "task) and linking it when the task has none. Reach for it whenever you'd "
            "be tempted to write task details anywhere else: break work into `items`, "
            "flip finished ones with `check`, and use `log` only for the rare line "
            "that genuinely isn't a to-do. Never restate task info in chat or in "
            "separate blocks."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "task_id": {"type": "string"},
                "items": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "text": {"type": "string"},
                            "done": {"type": "boolean", "description": "Default false."},
                        },
                        "required": ["text"],
                    },
                    "description": "Checkbox lines to append: each becomes '- [ ] text' ('- [x]' when done=true). One atomic step per item.",
                },
                "check": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Substrings matched case/accent-insensitively against existing unchecked '- [ ]' lines; the first matching line per entry flips to '- [x]'.",
                },
                "log": {"type": "string", "description": "Rare: ONE short plain prose line appended after the items, only when a checkbox genuinely doesn't fit."},
            },
            "required": ["task_id"],
        },
        "handler": _wrap(_task_todos),
    },
    {
        "name": "geo_create_block",
        "description": (
            "Create a new block by writing a .md file directly into the Geo vault "
            "(files are truth — the app reconciles it). Returns the new block id "
            "(its relative path, e.g. 'My-Block.md' or 'Projects/ARC/My-Block.md'). "
            "`type` is the Zettelkasten type (fleeting|literature|permanent|moc|"
            "project, default fleeting); `layer` is user|agent|review|shared "
            "(default agent). A '# <title>' H1 and today's [[YYYY-MM-DD]] day-link "
            "are added automatically unless you supply them. Pass `folder` (e.g. "
            "'Projects/ARC') to file it in a subfolder (created if missing)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "body": {"type": "string"},
                "type": {"type": "string", "description": "fleeting|literature|permanent|moc|project (default fleeting)."},
                "layer": {"type": "string", "description": "user|agent|review|shared (default agent)."},
                "status": {"type": "string", "description": "Optional, e.g. 'active' | 'evergreen'."},
                "day_id": {"type": "string", "description": "Day to link as YYYY-MM-DD (default today)."},
                "tag_name": {"type": "string", "description": "Single tag to apply (lowercased)."},
                "folder": {"type": "string", "description": "Folder path to file the block under, e.g. 'Projects/ARC'. Created if missing."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_create_block),
    },
    {
        "name": "geo_update_block",
        "description": (
            "Replace a block's full markdown body in place (preserving its frontmatter). "
            "`body` becomes the entire block content below the frontmatter (not a partial "
            "patch) — include the '# <title>' H1 and any [[date]] day-links you want to keep."
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
        "name": "geo_promote_to_permanent",
        "description": "Promote a block to type=permanent in place (frontmatter edit).",
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        },
        "handler": _wrap(_promote_to_permanent),
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
                "kind": {"type": "string", "description": "task|event|habit|milestone (default 'task'). task = one-shot to-do Gabriel must DO by a deadline. event = something that HAPPENS at a specific time (meeting, call, appointment, trip) — needs start+end. habit = recurring routine ('todo dia', 'every week') — never model recurring things as repeated tasks. milestone = outcome/goal to HIT by a target date (launch, delivery), not an action item."},
                "due": {"type": "string", "description": "kind=task: hora LOCAL de Gabriel (America/Sao_Paulo), naive, SEM 'Z' nem offset — 'YYYY-MM-DDTHH:MM:SS'. O código converte pra UTC; NÃO faça a conta de fuso. Ex.: 18:00 → '2026-06-22T18:00:00'. Sem horário → só a data 'YYYY-MM-DD' (o sistema põe no fim do dia)."},
                "estimated_minutes": {"type": "integer", "description": "kind=task: estimate."},
                "start": {"type": "string", "description": "kind=event: início em hora LOCAL naive 'YYYY-MM-DDTHH:MM:SS' (sem 'Z'). Ex.: 15h → '2026-06-22T15:00:00'. Nunca invente hora que Gabriel não disse — use uma redonda ou pergunte."},
                "end": {"type": "string", "description": "kind=event: fim em hora LOCAL naive (sem 'Z'). Sem duração → start + 1h. Período de vários dias ('de seg a qua') → start = primeiro dia, end = último dia (só a data 'YYYY-MM-DD')."},
                "recurrence": {"type": "string", "description": "daily|weekdays|weekly|biweekly|monthly|yearly. kind=habit: the repeat rule. kind=event: expands into a SERIES of real event instances (requires recurrence_end_date, max 26) — use for recurring meetings, not a habit."},
                "time_of_day": {"type": "string", "description": "kind=habit: hora LOCAL naive; só o horário importa (a data é ignorada). Ex.: 07:00 → '2026-06-22T07:00:00' (sem 'Z')."},
                "selected_weekdays": {"type": "array", "items": {"type": "integer"}, "description": "kind=habit: optional weekday selection (1=Sun … 7=Sat)."},
                "recurrence_end_date": {"type": "string", "description": "data LOCAL 'YYYY-MM-DD' — para de repetir depois dela. Opcional p/ kind=habit, OBRIGATÓRIO p/ evento recorrente."},
                "target": {"type": "string", "description": "kind=milestone: data-alvo LOCAL 'YYYY-MM-DD' (ou 'YYYY-MM-DDTHH:MM:SS' naive sem 'Z' se tiver hora). Sem hora → só a data."},
                "linked_block_id": {"type": "string", "description": "Optional source block."},
                "priority": {"type": "string"},
                "tag_ids": {"type": "array", "items": {"type": "string"}},
                "reminders": {"type": "array", "items": {"type": "object"}, "description": "[{trigger:'offset'|'absolute', offset|at}]. at = hora LOCAL naive 'YYYY-MM-DDTHH:MM:SS' (sem 'Z')."},
            },
            "required": ["title"],
        },
        "handler": _wrap(_create_task),
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
        "name": "geo_record_habit_occurrence",
        "description": "Log an occurrence of a habit. `at` defaults to now.",
        "parameters": {
            "type": "object",
            "properties": {
                "habit_id": {"type": "string"},
                "at": {"type": "string", "description": "Opcional. Hora LOCAL naive 'YYYY-MM-DDTHH:MM:SS' (sem 'Z')."},
            },
            "required": ["habit_id"],
        },
        "handler": _wrap(_record_habit_occurrence),
    },
]
