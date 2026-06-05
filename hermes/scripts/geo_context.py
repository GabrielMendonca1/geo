#!/usr/bin/env python3
"""
geo_context.py — file-native brain context for hermes cron jobs.

The MCP push subscriber that warmed ~/.hermes/geo-cache/snapshot.json was
retired in the "collapse to file-native" commit, so there is no live hook to
read. The vault itself is truth (ADR-0002), so any job can rebuild richer,
zero-staleness context by scanning ~/Library/Application Support/Geo/ directly,
app-closed:

  - moc_titles  : every type:moc block (the brain's table of contents)
  - block_titles: root-level blocks (excludes Daily/Semanas/Dias journal churn)
  - open_tasks  : Tasks/*.json with status != completed (title + deadline)

render_brain_context() returns a compact prompt block (~650 tokens at current
vault size) an LLM can link and dedup against. Import from any cron in this dir.
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

GEO_HOME = Path.home() / "Library" / "Application Support" / "Geo"
BLOCKS_DIR = GEO_HOME / "Blocks"
TASKS_DIR = GEO_HOME / "Tasks"

_FM_RE = re.compile(r"---\n(.*?)\n---", re.DOTALL)
_TYPE_RE = re.compile(r"^type:\s*(\S+)", re.MULTILINE)
_H1_RE = re.compile(r"^# (.+)$", re.MULTILINE)
_MAX_BLOCK_TITLES = 80


def _head(path: Path, n: int = 2048) -> str:
    try:
        return path.read_text(encoding="utf-8")[:n]
    except Exception:
        return ""


def _fm_type(text: str) -> str | None:
    m = _FM_RE.match(text)
    if not m:
        return None
    t = _TYPE_RE.search(m.group(1))
    return t.group(1).strip() if t else None


def _title(text: str, fallback: str) -> str:
    m = _H1_RE.search(text)
    return m.group(1).strip().strip("*").strip() if m else fallback


def gather_brain_context() -> dict:
    moc_titles: list[str] = []
    block_titles: list[str] = []
    if BLOCKS_DIR.exists():
        for p in sorted(BLOCKS_DIR.glob("*.md")):
            text = _head(p)
            title = _title(text, p.stem)
            if _fm_type(text) == "moc":
                moc_titles.append(title)
            else:
                block_titles.append(title)
        moc_dir = BLOCKS_DIR / "MOC"
        if moc_dir.exists():
            for p in sorted(moc_dir.glob("*.md")):
                title = _title(_head(p), p.stem)
                if title not in moc_titles:
                    moc_titles.append(title)

    open_tasks: list[tuple[str, str]] = []
    if TASKS_DIR.exists():
        for p in sorted(TASKS_DIR.glob("*.json")):
            try:
                d = json.loads(p.read_text(encoding="utf-8"))
            except Exception:
                continue
            if d.get("status") == "completed":
                continue
            title = (d.get("title") or "").strip()
            if not title:
                continue
            body = d.get("body") or {}
            due = body.get("due") or body.get("target") or body.get("start") or ""
            open_tasks.append((title, due[:10] if isinstance(due, str) else ""))

    moc_titles = [m for m in moc_titles if m.startswith("MOC")]
    return {
        "moc_titles": moc_titles[:40],
        "block_titles": block_titles[:_MAX_BLOCK_TITLES],
        "open_tasks": open_tasks[:40],
    }


def render_brain_context() -> str:
    ctx = gather_brain_context()
    lines: list[str] = []
    if ctx["moc_titles"]:
        lines.append("MOCs reais (use SÓ estes em `Parte de [[MOC — X]]`):")
        lines += [f"- {m}" for m in ctx["moc_titles"]]
    if ctx["block_titles"]:
        lines.append("")
        lines.append("Blocos existentes (linke com [[wikilink]] quando relevante; NÃO recrie um que já existe):")
        lines += [f"- {b}" for b in ctx["block_titles"]]
    if ctx["open_tasks"]:
        lines.append("")
        lines.append("Tarefas em aberto (não duplique):")
        lines += [f"- {t}" + (f" (vence {d})" if d else "") for t, d in ctx["open_tasks"]]
    return "\n".join(lines) if lines else "(vault vazio)"


def _iter_block_files():
    if not BLOCKS_DIR.exists():
        return
    for root, dirs, files in os.walk(BLOCKS_DIR):
        dirs[:] = [d for d in dirs if d != "Attachments"]
        for fn in files:
            if fn.endswith(".md"):
                yield Path(root) / fn


def _strip_frontmatter(md: str) -> str:
    text = md or ""
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3:]
    return text.strip()


def today_str(tz=None) -> str:
    return (datetime.now(tz) if tz else datetime.now()).date().isoformat()


def day_context_today(date_iso: str | None = None) -> str:
    date_iso = date_iso or today_str()
    token = f"[[{date_iso}]]"
    parts: list[str] = []
    for p in _iter_block_files():
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        if token in text:
            body = _strip_frontmatter(text)
            if body:
                parts.append(body)
    return "\n\n".join(parts)


def _task_anchor(body: dict) -> str | None:
    return body.get("due") or body.get("start") or body.get("target")


def _read_tasks() -> list[dict]:
    rows: list[dict] = []
    if not TASKS_DIR.exists():
        return rows
    for p in sorted(TASKS_DIR.glob("*.json")):
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        body = d.get("body") or {}
        rows.append({
            "title": d.get("title"),
            "kind": body.get("kind") or "task",
            "anchor": _task_anchor(body),
            "status": d.get("status"),
            "priority": d.get("priority"),
        })
    return rows


def _anchor_date(anchor: str | None) -> str | None:
    if not anchor:
        return None
    try:
        return datetime.fromisoformat(anchor.replace("Z", "+00:00")).date().isoformat()
    except Exception:
        return anchor[:10]


def tasks_for_day(date_iso: str) -> list[dict]:
    return [t for t in _read_tasks() if _anchor_date(t.get("anchor")) == date_iso]


def upcoming_tasks(within_days: int = 7) -> list[dict]:
    today = datetime.now(timezone.utc).date()
    out: list[dict] = []
    for t in _read_tasks():
        if t.get("status") != "pending":
            continue
        d = _anchor_date(t.get("anchor"))
        if not d:
            continue
        try:
            ad = datetime.fromisoformat(d).date()
        except Exception:
            continue
        if today <= ad <= today.replace() and ad <= today and False:
            pass
        if today <= ad <= (today.fromordinal(today.toordinal() + within_days)):
            out.append(t)
    out.sort(key=lambda t: t.get("anchor") or "9999")
    return out


if __name__ == "__main__":
    print(render_brain_context())
