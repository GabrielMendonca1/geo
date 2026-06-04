"""geo-http-tools — Geo tools for Gabriel's macOS app (`geo_*` prefix, no `mcp_`).

BLOCK writers are native filesystem ops on the Geo vault (files are truth);
TASK/read/ai/search/graph/tag/day tools talk to Geo.app's localhost HTTP API
(Slice A), auth via macOS Keychain bearer.

Destructive ops (`geo_delete_block`, `geo_delete_task`) gate on a Telegram
confirm from Gabriel: block delete is a native rm, task delete is an HTTP
DELETE. See ``destructive.py`` for the confirm flow and the
``pre_gateway_dispatch`` hook that captures his replies.
"""

from __future__ import annotations

import logging
from typing import Any

from .destructive import DESTRUCTIVE_TOOLS, get_inbound_hook
from .tools_read import READ_TOOLS
from .tools_write import WRITE_TOOLS

logger = logging.getLogger("plugin.geo-http-tools")

TOOLSET = "geo_http"

_DISABLED = frozenset({
    "geo_list_by_status", "geo_list_by_type", "geo_get_day", "geo_list_tags",
    "geo_move_block", "geo_link_block_to_day", "geo_update_task",
    "geo_add_reminder", "geo_ai_parse_task", "geo_create_tag",
    "geo_record_habit_occurrence",
})


def _register_all(ctx) -> None:
    all_tools = [t for t in (READ_TOOLS + WRITE_TOOLS + DESTRUCTIVE_TOOLS)
                 if t["name"] not in _DISABLED]
    for tool in all_tools:
        name = tool["name"]
        ctx.register_tool(
            name=name,
            toolset=TOOLSET,
            schema={
                "name": name,
                "description": tool["description"],
                "parameters": tool["parameters"],
            },
            handler=tool["handler"],
            is_async=True,
            description=tool["description"],
            emoji="",
        )
    logger.info("geo-http-tools: registered %d tools (%d disabled)",
                len(all_tools), len(_DISABLED))


def register(ctx) -> None:
    _register_all(ctx)
    try:
        ctx.register_hook("pre_gateway_dispatch", get_inbound_hook())
    except Exception as e:
        logger.warning("pre_gateway_dispatch hook registration failed: %s", e)
