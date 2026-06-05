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

render_brain_context() returns a compact prompt block (~500 tokens) an LLM can
link and dedup against. Import from any cron in this dir.
"""

from __future__ import annotations

import json
import re
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

    return {
        "moc_titles": moc_titles,
        "block_titles": block_titles[:_MAX_BLOCK_TITLES],
        "open_tasks": open_tasks,
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


if __name__ == "__main__":
    print(render_brain_context())
