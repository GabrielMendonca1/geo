"""File-native READ engine for Gabriel's Geo vault.

Replaces the HTTP read path. The vault is truth: blocks are ``.md`` files
under ``Blocks/`` whose id IS their path relative to ``Blocks/`` (e.g.
``My-Block.md`` or ``MOC/MOC-—-ARC.md``). The Geo.app derives a read-only
cache at ``Index/blocks.sqlite`` that trails a write by ~0.4s.

Lens:
- SPECIFIC-ID reads (get_block / get_block_by_title) open the ``.md`` file
  directly — O(1), always fresh, immune to the index lag.
- list / filter / search / graph / day / tag queries use the index (indexed
  SQL, single O(V+E) scan for the graph) — never glob-and-parse the whole
  vault on a hot path.

journal_mode is ``delete`` (not WAL), so a momentary app write-lock can block
a read-only open. ``_db`` opens read-only with a 3-step fallback so reads never
hard-fail: ``mode=ro`` -> ``immutable=1`` -> bounded glob+parse of the files.
"""

from __future__ import annotations

import os
import re
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, Optional

from ._fs import (
    BLOCKS_DIR,
    GEO_HOME,
    INDEX_DB,
    nfc,
    parse_frontmatter,
    split_frontmatter,
)
from .client import GeoError

TAGS_JSON = GEO_HOME / "tags.json"

_LINK_RE = re.compile(r"\[\[([^\]\[]+)\]\]")
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# ---------------------------------------------------------------------------
# DB access
# ---------------------------------------------------------------------------

class _NoIndex(Exception):
    pass


@contextmanager
def _db() -> Iterator[sqlite3.Connection]:
    """Yield a read-only connection, or raise ``_NoIndex`` to signal fallback.

    Never mutates the index. Tries ``mode=ro`` then ``immutable=1`` (the latter
    ignores the journal/lock entirely). If both fail or the DB is missing the
    caller falls back to the filesystem.
    """
    if not INDEX_DB.exists():
        raise _NoIndex(f"{INDEX_DB} missing")
    conn: Optional[sqlite3.Connection] = None
    for uri in (f"file:{INDEX_DB}?mode=ro", f"file:{INDEX_DB}?immutable=1"):
        try:
            conn = sqlite3.connect(uri, uri=True, timeout=1.0)
            conn.row_factory = sqlite3.Row
            conn.execute("SELECT 1 FROM blocks LIMIT 1")
            break
        except sqlite3.Error:
            if conn is not None:
                conn.close()
                conn = None
    if conn is None:
        raise _NoIndex(f"{INDEX_DB} unreadable")
    try:
        yield conn
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Filesystem helpers (truth + fallback)
# ---------------------------------------------------------------------------

def _block_path(block_id: str) -> Path:
    rel = nfc(block_id).strip().lstrip("/")
    if not rel.endswith(".md"):
        rel += ".md"
    return (BLOCKS_DIR / rel)


def _title_from(body: str, fallback_id: str) -> str:
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("# "):
            return s[2:].strip()
    name = Path(fallback_id).name
    return name[:-3] if name.endswith(".md") else name


def _read_block_file(block_id: str) -> dict:
    path = _block_path(block_id)
    if not path.exists():
        raise GeoError(f"block not found: {block_id}")
    text = path.read_text(encoding="utf-8")
    _, body = split_frontmatter(text)
    fm = parse_frontmatter(text)
    rel = str(path.relative_to(BLOCKS_DIR))
    return {
        "id": rel,
        "title": _title_from(body, rel),
        "markdown": text,
        "body": body,
        "frontmatter": fm,
        "type": fm.get("type", "fleeting"),
        "status": fm.get("status") or None,
        "layer": fm.get("layer", "user"),
    }


def _iter_block_files(limit: Optional[int] = None) -> Iterator[Path]:
    n = 0
    for root, dirs, files in os.walk(BLOCKS_DIR):
        dirs[:] = [d for d in dirs if d != "Attachments"]
        for fn in files:
            if fn.endswith(".md"):
                yield Path(root) / fn
                n += 1
                if limit is not None and n >= limit:
                    return


def _scan_files(limit: Optional[int] = None) -> list[dict]:
    out = []
    for p in _iter_block_files(limit):
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        _, body = split_frontmatter(text)
        fm = parse_frontmatter(text)
        rel = str(p.relative_to(BLOCKS_DIR))
        out.append(
            {
                "id": rel,
                "title": _title_from(body, rel),
                "content": body,
                "type": fm.get("type", "fleeting"),
                "status": fm.get("status") or None,
                "layer": fm.get("layer", "user"),
            }
        )
    return out


def _extract_links(content: str) -> tuple[list[str], list[str]]:
    """Return (link_titles, day_ids) from a block body's ``[[...]]`` tokens."""
    titles, days = [], []
    for m in _LINK_RE.findall(content):
        t = m.strip()
        if _DAY_RE.match(t):
            days.append(t)
        else:
            titles.append(t)
    return titles, days


# ---------------------------------------------------------------------------
# Specific-id reads — FILE is truth, never the index
# ---------------------------------------------------------------------------

def get_block(block_id: str) -> dict:
    return _read_block_file(block_id)


def get_block_by_title(title: str) -> dict:
    want = nfc(title).strip()
    block_id = None
    try:
        with _db() as c:
            row = c.execute(
                "SELECT id FROM blocks WHERE title = ? LIMIT 1", (want,)
            ).fetchone()
            if row:
                block_id = row["id"]
    except _NoIndex:
        pass
    if block_id is None:
        for rec in _scan_files():
            if nfc(rec["title"]) == want:
                block_id = rec["id"]
                break
    if block_id is None:
        raise GeoError(
            f"no block titled '{title}' — it may not exist. Do NOT retry this call; "
            f"use geo_search_blocks to find blocks by content, or geo_list_blocks to browse titles."
        )
    return _read_block_file(block_id)


# ---------------------------------------------------------------------------
# Listing / filtering — indexed SQL with file fallback
# ---------------------------------------------------------------------------

def _row_summary(row) -> dict:
    return {
        "id": row["id"],
        "title": row["title"],
        "type": row["type"],
        "status": row["status"],
        "layer": row["layer"],
    }


def list_blocks(limit: Optional[int] = None, tag_name: Optional[str] = None) -> list[dict]:
    try:
        with _db() as c:
            if tag_name:
                sql = (
                    "SELECT b.id,b.title,b.type,b.status,b.layer FROM blocks b "
                    "JOIN block_tags t ON t.blockId = b.id WHERE t.tag = ? "
                    "ORDER BY b.modifiedAt DESC"
                )
                params: tuple = (nfc(tag_name),)
            else:
                sql = (
                    "SELECT id,title,type,status,layer FROM blocks "
                    "ORDER BY modifiedAt DESC"
                )
                params = ()
            if limit is not None:
                sql += " LIMIT ?"
                params = params + (int(limit),)
            return [_row_summary(r) for r in c.execute(sql, params)]
    except _NoIndex:
        recs = _scan_files()
        if tag_name:
            want = nfc(tag_name).lower()
            recs = [r for r in recs if want in r["content"].lower()]
        out = [
            {k: r[k] for k in ("id", "title", "type", "status", "layer")}
            for r in recs
        ]
        return out[: int(limit)] if limit is not None else out


def list_by_status(status: str) -> list[dict]:
    try:
        with _db() as c:
            rows = c.execute(
                "SELECT id,title,type,status,layer FROM blocks WHERE status = ? "
                "ORDER BY modifiedAt DESC",
                (status,),
            )
            return [_row_summary(r) for r in rows]
    except _NoIndex:
        return [
            {k: r[k] for k in ("id", "title", "type", "status", "layer")}
            for r in _scan_files()
            if r["status"] == status
        ]


def list_by_type(type_: str) -> list[dict]:
    try:
        with _db() as c:
            rows = c.execute(
                "SELECT id,title,type,status,layer FROM blocks WHERE type = ? "
                "ORDER BY modifiedAt DESC",
                (type_,),
            )
            return [_row_summary(r) for r in rows]
    except _NoIndex:
        return [
            {k: r[k] for k in ("id", "title", "type", "status", "layer")}
            for r in _scan_files()
            if r["type"] == type_
        ]


# ---------------------------------------------------------------------------
# Search — FTS5 bm25 + snippet, degrades to substring scan
# ---------------------------------------------------------------------------

def _fts_query(query: str) -> str:
    terms = re.findall(r"[\w]+", nfc(query), flags=re.UNICODE)
    if not terms:
        return ""
    return " OR ".join(f'"{t}"' for t in terms)


def search_blocks(query: str, limit: int = 20) -> list[dict]:
    match = _fts_query(query)
    if not match:
        return []
    try:
        with _db() as c:
            rows = c.execute(
                "SELECT b.id AS id, b.title AS title, b.type AS type, "
                "b.layer AS layer, "
                "snippet(blocks_fts, 2, '[', ']', '…', 12) AS snippet, "
                "bm25(blocks_fts) AS rank "
                "FROM blocks_fts JOIN blocks b ON b.id = blocks_fts.blockId "
                "WHERE blocks_fts MATCH ? ORDER BY bm25(blocks_fts) LIMIT ?",
                (match, int(limit)),
            )
            return [
                {
                    "id": r["id"],
                    "title": r["title"],
                    "type": r["type"],
                    "layer": r["layer"],
                    "snippet": r["snippet"],
                    "rank": r["rank"],
                }
                for r in rows
            ]
    except (_NoIndex, sqlite3.Error):
        terms = [t.lower() for t in re.findall(r"[\w]+", nfc(query), flags=re.UNICODE)]
        hits = []
        for rec in _scan_files():
            hay = (rec["title"] + "\n" + rec["content"]).lower()
            score = sum(hay.count(t) for t in terms)
            if score:
                idx = next((hay.find(t) for t in terms if t in hay), 0)
                hits.append(
                    {
                        "id": rec["id"],
                        "title": rec["title"],
                        "type": rec["type"],
                        "layer": rec["layer"],
                        "snippet": rec["content"][max(0, idx - 40): idx + 80].strip(),
                        "rank": -float(score),
                    }
                )
        hits.sort(key=lambda h: h["rank"])
        return hits[: int(limit)]


# ---------------------------------------------------------------------------
# Graph — built ONCE in O(V+E), title->id resolution
# ---------------------------------------------------------------------------

def _build_graph(limit: Optional[int] = None) -> dict:
    rows: list[dict] = []
    try:
        with _db() as c:
            q = "SELECT id, title, content FROM blocks ORDER BY modifiedAt DESC"
            if limit is not None:
                q += f" LIMIT {int(limit)}"
            rows = [
                {"id": r["id"], "title": r["title"], "content": r["content"]}
                for r in c.execute(q)
            ]
    except _NoIndex:
        rows = [
            {"id": r["id"], "title": r["title"], "content": r["content"]}
            for r in _scan_files(limit)
        ]
    rows = [r for r in rows if not r["id"].startswith("Daily/")]
    by_title = {nfc(r["title"]): r["id"] for r in rows}
    ids = {r["id"] for r in rows}
    nodes = [{"id": r["id"], "title": r["title"]} for r in rows]
    edges = []
    adj: dict[str, set] = {r["id"]: set() for r in rows}
    rev: dict[str, set] = {r["id"]: set() for r in rows}
    has_out: set[str] = set()
    for r in rows:
        link_titles, day_ids = _extract_links(r["content"])
        if link_titles or day_ids:
            has_out.add(r["id"])
        for lt in link_titles:
            tgt = by_title.get(nfc(lt))
            if tgt and tgt in ids and tgt != r["id"]:
                edges.append({"source": r["id"], "target": tgt})
                adj[r["id"]].add(tgt)
                rev[tgt].add(r["id"])
    return {"nodes": nodes, "edges": edges, "_adj": adj, "_rev": rev,
            "_by_title": by_title, "_has_out": has_out}


def graph_snapshot(limit: Optional[int] = None) -> dict:
    g = _build_graph(limit)
    return {"nodes": g["nodes"], "edges": g["edges"]}


def list_neighbors(block_id: str) -> dict:
    bid = _read_block_file(block_id)["id"]
    g = _build_graph(None)
    out = sorted(g["_adj"].get(bid, set()))
    inc = sorted(g["_rev"].get(bid, set()))
    return {"id": bid, "outgoing": out, "incoming": inc}


def find_backlinks(block_id: str) -> dict:
    bid = _read_block_file(block_id)["id"]
    g = _build_graph(None)
    return {"id": bid, "backlinks": sorted(g["_rev"].get(bid, set()))}


def find_orphans() -> list[dict]:
    g = _build_graph(None)
    has_out = g["_has_out"]
    return [
        n for n in g["nodes"]
        if not g["_rev"].get(n["id"]) and n["id"] not in has_out
    ]


def find_unresolved_links() -> list[dict]:
    rows: list[dict] = []
    try:
        with _db() as c:
            rows = [
                {"id": r["id"], "title": r["title"], "content": r["content"]}
                for r in c.execute("SELECT id, title, content FROM blocks")
            ]
    except _NoIndex:
        rows = [
            {"id": r["id"], "title": r["title"], "content": r["content"]}
            for r in _scan_files()
        ]
    rows = [r for r in rows if not r["id"].startswith("Daily/")]
    known = {nfc(r["title"]) for r in rows}
    out = []
    for r in rows:
        link_titles, _ = _extract_links(r["content"])
        for lt in link_titles:
            if nfc(lt) not in known:
                out.append({"source": r["id"], "target_title": lt})
    return out


# ---------------------------------------------------------------------------
# Folders
# ---------------------------------------------------------------------------

def list_folders() -> list[str]:
    out: set[str] = set()
    for root, dirs, _files in os.walk(BLOCKS_DIR):
        dirs[:] = [d for d in dirs if d != "Attachments"]
        rel = os.path.relpath(root, BLOCKS_DIR)
        if rel not in (".", "Attachments"):
            out.add(rel)
    return sorted(out)


# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

def _load_tag_colors() -> dict:
    import json

    try:
        return json.loads(TAGS_JSON.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def list_tags() -> list[dict]:
    colors = _load_tag_colors()
    counts: dict[str, int] = {}
    try:
        with _db() as c:
            for r in c.execute(
                "SELECT tag, COUNT(DISTINCT blockId) AS n FROM block_tags GROUP BY tag"
            ):
                counts[r["tag"]] = r["n"]
    except _NoIndex:
        for rec in _scan_files():
            for t in re.findall(r"tags:\s*\[\[([^\]]+)\]\]", rec["content"]):
                counts[t.strip()] = counts.get(t.strip(), 0) + 1
    names = set(counts) | set(colors)
    out = []
    for name in sorted(names):
        meta = colors.get(name, {})
        out.append(
            {
                "name": name,
                "count": counts.get(name, 0),
                "color": meta.get("color"),
                "order": meta.get("order"),
            }
        )
    return out


# ---------------------------------------------------------------------------
# Days
# ---------------------------------------------------------------------------

def _day_record(day: str) -> dict:
    day = nfc(day).strip()
    block_ids: list[str] = []
    try:
        with _db() as c:
            rows = c.execute(
                "SELECT b.id AS id, b.title AS title FROM block_days d "
                "JOIN blocks b ON b.id = d.blockId WHERE d.dayId = ? "
                "ORDER BY b.modifiedAt DESC",
                (day,),
            ).fetchall()
            return {
                "day": day,
                "block_ids": [r["id"] for r in rows],
                "titles": [r["title"] for r in rows],
                "count": len(rows),
            }
    except _NoIndex:
        for rec in _scan_files():
            _, days = _extract_links(rec["content"])
            if day in days:
                block_ids.append(rec["id"])
        return {"day": day, "block_ids": block_ids, "titles": [], "count": len(block_ids)}


def get_day(day: str) -> dict:
    return _day_record(day)


def get_today() -> dict:
    import os
    from datetime import datetime
    from zoneinfo import ZoneInfo

    tz = ZoneInfo(os.environ.get("GEO_TZ", "America/Sao_Paulo"))
    return _day_record(datetime.now(tz).strftime("%Y-%m-%d"))
