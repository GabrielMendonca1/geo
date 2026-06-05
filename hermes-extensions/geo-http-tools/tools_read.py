"""Read tool handlers for Geo — file-native (the vault is truth).

Each handler delegates to the sync ``reads``/``tasks_fs`` engines off the event
loop via ``asyncio.to_thread``. No HTTP: block/day/tag reads come from the
read-only ``Index/blocks.sqlite`` cache (with a glob+parse fallback), task reads
from ``Tasks/*.json``. Schemas are co-located so ``__init__.py`` registers them
from one table.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any, Callable

from . import reads, tasks_fs
from .client import GeoError


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


async def _get_block(a: dict) -> Any:
    return await asyncio.to_thread(reads.get_block, a["id"])


async def _get_block_by_title(a: dict) -> Any:
    return await asyncio.to_thread(reads.get_block_by_title, a["title"])


async def _list_blocks(a: dict) -> Any:
    return await asyncio.to_thread(reads.list_blocks, a.get("limit"), a.get("tag_name"))


async def _list_by_status(a: dict) -> Any:
    return await asyncio.to_thread(reads.list_by_status, a["status"])


async def _list_by_type(a: dict) -> Any:
    return await asyncio.to_thread(reads.list_by_type, a["type"])


async def _list_neighbors(a: dict) -> Any:
    return await asyncio.to_thread(reads.list_neighbors, a["id"])


async def _search_blocks(a: dict) -> Any:
    return await asyncio.to_thread(reads.search_blocks, a["query"])


async def _find_backlinks(a: dict) -> Any:
    return await asyncio.to_thread(reads.find_backlinks, a["id"])


async def _find_orphans(a: dict) -> Any:
    return await asyncio.to_thread(reads.find_orphans)


async def _find_unresolved_links(a: dict) -> Any:
    return await asyncio.to_thread(reads.find_unresolved_links)


async def _get_graph_snapshot(a: dict) -> Any:
    return await asyncio.to_thread(reads.graph_snapshot, a.get("limit"))


async def _list_folders(a: dict) -> Any:
    return await asyncio.to_thread(reads.list_folders)


async def _get_task(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.get_task, a["id"])


async def _list_tasks(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.list_tasks, a)


async def _list_tasks_for_day(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.list_tasks_for_day, a["day"])


async def _list_upcoming(a: dict) -> Any:
    return await asyncio.to_thread(tasks_fs.list_upcoming, a)


async def _list_tags(a: dict) -> Any:
    return await asyncio.to_thread(reads.list_tags)


async def _get_today(a: dict) -> Any:
    return await asyncio.to_thread(reads.get_today)


async def _get_day(a: dict) -> Any:
    return await asyncio.to_thread(reads.get_day, a["day"])


READ_TOOLS: list[dict] = [
    {
        "name": "geo_get_block",
        "description": (
            "Fetch a single block by id. Returns full markdown body + frontmatter + metadata. "
            "A block's id IS its path under the vault, so a folder-filed note has a "
            "folder-prefixed id like 'Projects/ARC/My-Block.md' — pass it verbatim."
        ),
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "Block id / path, e.g. 'My-Block.md' or 'Projects/ARC/My-Block.md'."}},
            "required": ["id"],
        },
        "handler": _wrap(_get_block),
    },
    {
        "name": "geo_list_folders",
        "description": (
            "List every folder in the vault (Obsidian-style folder tree), as an array of "
            "paths like ['Areas', 'Projects', 'Projects/ARC']. Folders are real directories "
            "under the vault; a block's folder is the directory part of its id. Call this to "
            "see the structure before filing notes with geo_create_block(folder=...) or "
            "reorganizing with geo_move_block."
        ),
        "parameters": {"type": "object", "properties": {}},
        "handler": _wrap(_list_folders),
    },
    {
        "name": "geo_get_block_by_title",
        "description": "Fetch a block by its title (e.g. 'User Profile', 'Memory'). Case-sensitive.",
        "parameters": {
            "type": "object",
            "properties": {"title": {"type": "string"}},
            "required": ["title"],
        },
        "handler": _wrap(_get_block_by_title),
    },
    {
        "name": "geo_list_blocks",
        "description": "List blocks, optionally filtered by tag.",
        "parameters": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Max blocks to return (default 50)."},
                "tag_name": {"type": "string", "description": "Filter to blocks carrying this tag."},
            },
        },
        "handler": _wrap(_list_blocks),
    },
    {
        "name": "geo_list_by_status",
        "description": "List blocks filtered by frontmatter status (e.g. 'active', 'archived').",
        "parameters": {
            "type": "object",
            "properties": {
                "status": {"type": "string"},
            },
            "required": ["status"],
        },
        "handler": _wrap(_list_by_status),
    },
    {
        "name": "geo_list_by_type",
        "description": "List blocks filtered by frontmatter type (e.g. 'note', 'project', 'inbox').",
        "parameters": {
            "type": "object",
            "properties": {
                "type": {"type": "string"},
            },
            "required": ["type"],
        },
        "handler": _wrap(_list_by_type),
    },
    {
        "name": "geo_list_neighbors",
        "description": "Graph neighbors of a block (immediate in + out links).",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
            },
            "required": ["id"],
        },
        "handler": _wrap(_list_neighbors),
    },
    {
        "name": "geo_search_blocks",
        "description": "Full-text search across block bodies + titles. Returns ranked hits.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
            },
            "required": ["query"],
        },
        "handler": _wrap(_search_blocks),
    },
    {
        "name": "geo_find_backlinks",
        "description": "Blocks that link TO this block (incoming wikilinks).",
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        },
        "handler": _wrap(_find_backlinks),
    },
    {
        "name": "geo_find_orphans",
        "description": "Blocks with no incoming or outgoing links.",
        "parameters": {
            "type": "object",
            "properties": {},
        },
        "handler": _wrap(_find_orphans),
    },
    {
        "name": "geo_find_unresolved_links",
        "description": "Wikilinks pointing to titles that don't exist yet.",
        "parameters": {
            "type": "object",
            "properties": {},
        },
        "handler": _wrap(_find_unresolved_links),
    },
    {
        "name": "geo_get_graph_snapshot",
        "description": "Graph snapshot of the top-N blocks by weight. Nodes + edges.",
        "parameters": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Top-N blocks by weight to include."},
            },
        },
        "handler": _wrap(_get_graph_snapshot),
    },
    {
        "name": "geo_get_task",
        "description": "Fetch a single task by id.",
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        },
        "handler": _wrap(_get_task),
    },
    {
        "name": "geo_list_tasks",
        "description": "List tasks; filter by status, kind, priority, or linked block.",
        "parameters": {
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "description": "'pending' | 'completed'.",
                },
                "kind": {"type": "string", "description": "task|event|habit|milestone."},
                "priority": {"type": "string"},
                "linked_block_id": {"type": "string", "description": "Only tasks linked to this block."},
            },
        },
        "handler": _wrap(_list_tasks),
    },
    {
        "name": "geo_list_tasks_for_day",
        "description": "Tasks scheduled for a specific day (YYYY-MM-DD).",
        "parameters": {
            "type": "object",
            "properties": {"day": {"type": "string", "description": "ISO date YYYY-MM-DD."}},
            "required": ["day"],
        },
        "handler": _wrap(_list_tasks_for_day),
    },
    {
        "name": "geo_list_upcoming",
        "description": "Upcoming tasks within a time window.",
        "parameters": {
            "type": "object",
            "properties": {
                "window": {"type": "string", "description": "'24h' | '7d' | '30d' | 'Nh' | 'Nd'."},
                "limit": {"type": "integer"},
            },
        },
        "handler": _wrap(_list_upcoming),
    },
    {
        "name": "geo_list_tags",
        "description": "All tags known to Geo with usage counts.",
        "parameters": {
            "type": "object",
            "properties": {},
        },
        "handler": _wrap(_list_tags),
    },
    {
        "name": "geo_get_today",
        "description": "Today's day record (linked blocks, capture count, id).",
        "parameters": {"type": "object", "properties": {}},
        "handler": _wrap(_get_today),
    },
    {
        "name": "geo_get_day",
        "description": "Day record for a specific date (YYYY-MM-DD).",
        "parameters": {
            "type": "object",
            "properties": {"day": {"type": "string"}},
            "required": ["day"],
        },
        "handler": _wrap(_get_day),
    },
]
