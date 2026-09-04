#!/usr/bin/env python3
"""Indexa o cérebro humano em state/index e gera o dashboard de tarefas."""

from __future__ import annotations

import json
import os
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

BRAIN_DIR = Path("/mnt/garime/Gabriel")
STATE_DIR = Path("/mnt/garime/state")
BLOCKS_DIR = BRAIN_DIR / "40 Conhecimento"  # destino de novos blocos pela caneta
SEARCH_DIRS = tuple(BRAIN_DIR / name for name in ("10 Diário", "20 Vida", "30 Projetos", "40 Conhecimento", "90 Arquivo"))
INDEX_DIR = STATE_DIR / "index"
INDEX_DB = INDEX_DIR / "blocks.sqlite"
TASKS_DIR = STATE_DIR / "tasks"
TAREFAS_MD = BRAIN_DIR / "00 Entrada" / "Tarefas.md"
PRIORITY_ORDER = {"urgent": 0, "high": 1, "medium": 2, "low": 3, "unset": 4}

_LINK_RE = re.compile(r"\[\[([^\]\[]+)\]\]")
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_TAGS_RE = re.compile(r"^tags:\s*\[(.*?)\]\s*$", re.MULTILINE)

SCHEMA = """
CREATE TABLE IF NOT EXISTS blocks (
    id TEXT PRIMARY KEY,
    title TEXT,
    type TEXT,
    status TEXT,
    layer TEXT,
    content TEXT,
    modifiedAt TEXT,
    mtime REAL
);
CREATE VIRTUAL TABLE IF NOT EXISTS blocks_fts USING fts5(
    blockId UNINDEXED, title, content
);
CREATE TABLE IF NOT EXISTS block_tags (
    blockId TEXT,
    tag TEXT
);
CREATE TABLE IF NOT EXISTS block_days (
    blockId TEXT,
    dayId TEXT
);
CREATE INDEX IF NOT EXISTS idx_block_tags_blockId ON block_tags(blockId);
CREATE INDEX IF NOT EXISTS idx_block_tags_tag ON block_tags(tag);
CREATE INDEX IF NOT EXISTS idx_block_days_blockId ON block_days(blockId);
CREATE INDEX IF NOT EXISTS idx_block_days_dayId ON block_days(dayId);
"""


def split_frontmatter(text: str) -> tuple[str, str]:
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[: end + 5], text[end + 5 :]
    return "", text


def parse_frontmatter(text: str) -> dict:
    fm, _ = split_frontmatter(text)
    out: dict[str, str] = {}
    if not fm:
        return out
    for line in fm.splitlines():
        if line in ("---", "") or line.startswith(" "):
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def parse_tags(text: str) -> list[str]:
    fm, _ = split_frontmatter(text)
    m = _TAGS_RE.search(fm)
    if not m:
        return []
    return [t.strip().strip("\"'") for t in m.group(1).split(",") if t.strip()]


def title_from(body: str, fallback_id: str) -> str:
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("# "):
            return s[2:].strip()
    name = Path(fallback_id).name
    return name[:-3] if name.endswith(".md") else name


def extract_days(content: str) -> list[str]:
    return sorted({m.strip() for m in _LINK_RE.findall(content) if _DAY_RE.match(m.strip())})


def iter_block_files():
    for search_dir in SEARCH_DIRS:
        if not search_dir.exists():
            continue
        for root, dirs, files in os.walk(search_dir):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for fn in files:
                if fn.endswith(".md"):
                    yield Path(root) / fn


def build_row(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    _, body = split_frontmatter(text)
    fm = parse_frontmatter(text)
    rel = str(path.relative_to(BRAIN_DIR))
    mtime = path.stat().st_mtime
    return {
        "id": rel,
        "title": title_from(body, rel),
        "type": fm.get("type", "fleeting"),
        "status": fm.get("status") or None,
        "layer": fm.get("layer", "user"),
        "content": body,
        "modifiedAt": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mtime": mtime,
        "tags": parse_tags(text),
        "days": extract_days(body),
    }


def upsert(conn: sqlite3.Connection, row: dict) -> None:
    conn.execute(
        "INSERT INTO blocks (id,title,type,status,layer,content,modifiedAt,mtime) "
        "VALUES (?,?,?,?,?,?,?,?) "
        "ON CONFLICT(id) DO UPDATE SET title=excluded.title, type=excluded.type, "
        "status=excluded.status, layer=excluded.layer, content=excluded.content, "
        "modifiedAt=excluded.modifiedAt, mtime=excluded.mtime",
        (row["id"], row["title"], row["type"], row["status"], row["layer"],
         row["content"], row["modifiedAt"], row["mtime"]),
    )
    conn.execute("DELETE FROM blocks_fts WHERE blockId = ?", (row["id"],))
    conn.execute(
        "INSERT INTO blocks_fts (blockId, title, content) VALUES (?,?,?)",
        (row["id"], row["title"], row["content"]),
    )
    conn.execute("DELETE FROM block_tags WHERE blockId = ?", (row["id"],))
    conn.executemany(
        "INSERT INTO block_tags (blockId, tag) VALUES (?,?)",
        [(row["id"], t) for t in row["tags"]],
    )
    conn.execute("DELETE FROM block_days WHERE blockId = ?", (row["id"],))
    conn.executemany(
        "INSERT INTO block_days (blockId, dayId) VALUES (?,?)",
        [(row["id"], d) for d in row["days"]],
    )


def remove(conn: sqlite3.Connection, block_id: str) -> None:
    conn.execute("DELETE FROM blocks WHERE id = ?", (block_id,))
    conn.execute("DELETE FROM blocks_fts WHERE blockId = ?", (block_id,))
    conn.execute("DELETE FROM block_tags WHERE blockId = ?", (block_id,))
    conn.execute("DELETE FROM block_days WHERE blockId = ?", (block_id,))


def iter_task_files():
    if not TASKS_DIR.exists():
        return
    for path in sorted(TASKS_DIR.glob("*.json")):
        if ".sync-conflict-" in path.name:
            continue
        yield path


def load_tasks() -> list[dict]:
    tasks = []
    for path in iter_task_files():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        tasks.append(data)
    return tasks


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def local_date(dt: datetime | None):
    if dt is None:
        return None
    return dt.astimezone().date()


def anchor_dt(task: dict) -> datetime | None:
    body = task.get("body") or {}
    kind = body.get("kind")
    if kind == "event":
        return parse_ts(body.get("start"))
    if kind == "habit":
        return parse_ts(body.get("timeOfDay"))
    if kind == "milestone":
        return parse_ts(body.get("target"))
    return parse_ts(body.get("due"))


def is_overdue(task: dict, now: datetime, today) -> bool:
    body = task.get("body") or {}
    kind = body.get("kind")
    if kind == "event":
        end = parse_ts(body.get("end"))
        return end is not None and end < now
    if kind in ("habit", "milestone"):
        return False
    due = anchor_dt(task)
    return due is not None and local_date(due) < today


def is_due_today(task: dict, today) -> bool:
    body = task.get("body") or {}
    kind = body.get("kind")
    if kind == "habit":
        occurrences = body.get("occurrences") or []
        return not any(local_date(parse_ts(o)) == today for o in occurrences)
    if kind == "milestone":
        target = anchor_dt(task)
        return target is not None and local_date(target) <= today
    anchor = anchor_dt(task)
    return anchor is not None and local_date(anchor) == today


def kanban_item(task: dict) -> str:
    checked = "x" if task.get("status") == "completed" else " "
    title = (task.get("title") or "").strip()
    anchor = anchor_dt(task)
    suffix = ""
    if anchor:
        suffix = f" @{{{local_date(anchor).isoformat()}}}"
    return f"- [{checked}] {title}{suffix}"


def render_tarefas(tasks: list[dict]) -> str:
    now = datetime.now(timezone.utc)
    today = local_date(now)

    pending = [t for t in tasks if t.get("status") != "completed"]
    completed = [t for t in tasks if t.get("status") == "completed"]

    atrasadas, hoje, proximas = [], [], []
    for t in pending:
        if is_overdue(t, now, today):
            atrasadas.append(t)
        elif is_due_today(t, today):
            hoje.append(t)
        else:
            proximas.append(t)

    concluidas_hoje = [
        t for t in completed if local_date(parse_ts(t.get("modifiedAt"))) == today
    ]

    def sort_key(t: dict):
        anchor = anchor_dt(t)
        ts = anchor if anchor is not None else datetime.max.replace(tzinfo=timezone.utc)
        return (ts, PRIORITY_ORDER.get(t.get("priority"), 4))

    atrasadas.sort(key=sort_key)
    hoje.sort(key=sort_key)
    proximas.sort(key=sort_key)
    concluidas_hoje.sort(key=lambda t: t.get("modifiedAt") or "", reverse=True)

    lines = [
        "---",
        "kanban-plugin: board",
        "---",
        "",
        "%% gerado automaticamente pelo geo-indexer — edições manuais serão sobrescritas %%",
        "",
    ]
    for heading, items in (
        ("Atrasadas", atrasadas),
        ("Hoje", hoje),
        ("Próximas", proximas),
        ("Concluídas hoje", concluidas_hoje),
    ):
        lines.append(f"## {heading}")
        lines.append("")
        for t in items:
            lines.append(kanban_item(t))
        lines.append("")
    return "\n".join(lines)


def write_tarefas() -> None:
    TAREFAS_MD.parent.mkdir(parents=True, exist_ok=True)
    tasks = load_tasks()
    content = render_tarefas(tasks)
    if TAREFAS_MD.exists() and TAREFAS_MD.read_text(encoding="utf-8") == content:
        return
    tmp = TAREFAS_MD.with_name(TAREFAS_MD.name + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, TAREFAS_MD)


def run() -> None:
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    full_rebuild = not INDEX_DB.exists()
    tmp_db = INDEX_DB.with_name(INDEX_DB.name + ".tmp")
    target = tmp_db if full_rebuild else INDEX_DB
    if full_rebuild and tmp_db.exists():
        tmp_db.unlink()

    conn = sqlite3.connect(target)
    conn.executescript(SCHEMA)

    known_mtime: dict[str, float] = {}
    if not full_rebuild:
        known_mtime = {r[0]: r[1] for r in conn.execute("SELECT id, mtime FROM blocks")}

    seen: set[str] = set()
    n_written = 0
    for path in iter_block_files():
        rel = str(path.relative_to(BRAIN_DIR))
        seen.add(rel)
        mtime = path.stat().st_mtime
        if not full_rebuild and known_mtime.get(rel) == mtime:
            continue
        upsert(conn, build_row(path))
        n_written += 1

    if not full_rebuild:
        for rel in set(known_mtime) - seen:
            remove(conn, rel)

    conn.commit()
    conn.close()

    if full_rebuild:
        os.replace(tmp_db, INDEX_DB)

    write_tarefas()

    print(f"geo_indexer: {n_written} written, {len(seen)} total blocks")


if __name__ == "__main__":
    run()
