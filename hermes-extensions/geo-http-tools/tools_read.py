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
        offset=a.get("offset"),
        layer=a.get("layer"),
    )


async def _list_by_status(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/blocks/by-status",
        status=a["status"],
        limit=a.get("limit"),
    )


async def _list_by_type(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/blocks/by-type",
        type=a["type"],
        limit=a.get("limit"),
    )


async def _list_neighbors(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        f"/blocks/{a['id']}/neighbors",
        depth=a.get("depth"),
    )


async def _search_blocks(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/blocks/search",
        q=a["query"],
        limit=a.get("limit"),
    )


async def _find_backlinks(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/blocks/{a['id']}/backlinks")


async def _find_orphans(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/orphans", limit=a.get("limit"))


async def _find_unresolved_links(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/blocks/unresolved-links", limit=a.get("limit"))


async def _get_graph_snapshot(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/graph/snapshot",
        root_id=a.get("root_id"),
        depth=a.get("depth"),
    )


async def _list_folders(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/folders")


async def _get_task(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/tasks/{a['id']}")


async def _list_tasks(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/tasks",
        limit=a.get("limit"),
        offset=a.get("offset"),
        status=a.get("status"),
    )


async def _list_tasks_for_day(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/tasks/for-day", day=a["day"])


async def _list_upcoming(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(
        "/tasks/upcoming",
        within_days=a.get("within_days"),
        limit=a.get("limit"),
    )


async def _list_tags(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/tags", limit=a.get("limit"))


async def _get_today(c: GeoAPIClient, a: dict) -> Any:
    return await c.get("/days/today")


async def _get_day(c: GeoAPIClient, a: dict) -> Any:
    return await c.get(f"/days/{a['day']}")


READ_TOOLS: list[dict] = [
    {
        "name": "geo_get_block",
        "description": "Fetch a single block by id. Returns full markdown body + frontmatter + metadata.",
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "Block id (uuid or slug)."}},
            "required": ["id"],
        },
        "handler": _wrap(_get_block),
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
        "description": "Paginated list of blocks.",
        "parameters": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Page size (default 50)."},
                "offset": {"type": "integer", "description": "Page offset."},
                "layer": {
                    "type": "string",
                    "description": "Filter by layer: 'fleeting', 'literature', 'permanent'.",
                },
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
                "limit": {"type": "integer"},
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
                "limit": {"type": "integer"},
            },
            "required": ["type"],
        },
        "handler": _wrap(_list_by_type),
    },
    {
        "name": "geo_list_neighbors",
        "description": "Graph neighbors of a block (in + out links) up to `depth` hops.",
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "depth": {"type": "integer", "description": "Default 1."},
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
                "limit": {"type": "integer"},
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
            "properties": {"limit": {"type": "integer"}},
        },
        "handler": _wrap(_find_orphans),
    },
    {
        "name": "geo_find_unresolved_links",
        "description": "Wikilinks pointing to titles that don't exist yet.",
        "parameters": {
            "type": "object",
            "properties": {"limit": {"type": "integer"}},
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
