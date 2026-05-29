"""geo-http-tools — authenticated HTTP client for Gabriel's Geo macOS app.

Registers 34 tools (`geo_*` prefix, no `mcp_`) that talk to the localhost
HTTP API exposed by Geo.app (Slice A). Auth via macOS Keychain bearer.

Destructive ops (`geo_delete_block`, `geo_delete_task`) gate on a Telegram
confirm from Gabriel. See ``destructive.py`` for the two-phase flow and the
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


def _register_all(ctx) -> None:
    all_tools = READ_TOOLS + WRITE_TOOLS + DESTRUCTIVE_TOOLS
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
    logger.info("geo-http-tools: registered %d tools", len(all_tools))


def register(ctx) -> None:
    _register_all(ctx)
    try:
        ctx.register_hook("pre_gateway_dispatch", get_inbound_hook())
    except Exception as e:
        logger.warning("pre_gateway_dispatch hook registration failed: %s", e)
