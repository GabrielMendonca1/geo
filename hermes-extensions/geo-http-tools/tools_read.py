"""Read tool handlers for Geo HTTP API.

Each handler is a thin async wrapper over ``GeoAPIClient`` that returns
the raw JSON dict from the API. Schemas are co-located with handlers so
``__init__.py`` can iterate one table to register them all.
"""

from __future__ import annotations

import json
from typing import Any, Callable

from .client import GeoAPIClient, GeoError


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


async def _get_block(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/blocks/{a['id']}")


async def _get_block_by_title(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/by-title", title=a["title"])


async def _list_blocks(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/blocks",
        limit=a.get("limit"),
        tag_name=a.get("tag_name"),
    )


async def _list_by_status(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/by-status", status=a["status"])


async def _list_by_type(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/by-type", type=a["type"])


async def _list_neighbors(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/blocks/{a['id']}/neighbors")


async def _search_blocks(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/search", q=a["query"])


async def _find_backlinks(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/blocks/{a['id']}/backlinks")


async def _find_orphans(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/orphans")


async def _find_unresolved_links(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/unresolved-links")


async def _get_graph_snapshot(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/graph/snapshot", limit=a.get("limit"))


async def _list_folders(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/folders")


async def _get_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/tasks/{a['id']}")


async def _list_tasks(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/tasks",
        status=a.get("status"),
        kind=a.get("kind"),
        priority=a.get("priority"),
        linked_block_id=a.get("linked_block_id"),
    )


async def _list_tasks_for_day(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/tasks/for-day/{a['day']}")


async def _list_upcoming(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/tasks/upcoming",
        window=a.get("window"),
        limit=a.get("limit"),
    )


async def _list_tags(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/tags")


async def _get_today(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/days/today")


async def _get_day(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/days/{a['day']}")


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
        "description": "Subgraph rooted at `root_id` (or whole graph if omitted). Nodes + edges.",
        "parameters": {
            "type": "object",
            "properties": {
                "root_id": {"type": "string"},
                "depth": {"type": "integer"},
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
        "description": "Paginated list of tasks; filter by status if given.",
        "parameters": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer"},
                "offset": {"type": "integer"},
                "status": {
                    "type": "string",
                    "description": "'open', 'completed', 'snoozed', 'cancelled'.",
                },
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
        "description": "Upcoming tasks within the next N days (default 7).",
        "parameters": {
            "type": "object",
            "properties": {
                "within_days": {"type": "integer"},
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
            "properties": {"limit": {"type": "integer"}},
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
