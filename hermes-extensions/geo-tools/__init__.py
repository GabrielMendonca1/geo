"""geo-tools — Geo tools for Gabriel's macOS app (`geo_*` prefix, no `mcp_`).

Fully file-native (the vault is truth): block writers are native FS ops guarded
by ``guard`` (agents may only write agent/review/shared, never user/Você); block/
day/tag reads come from the read-only ``Index/blocks.sqlite`` cache via ``reads``
(glob+parse fallback when the app is mid-write or closed); task CRUD/dedup is
``tasks_fs`` over ``Tasks/*.json``. No HTTP, no Keychain — the Geo.app FileWatcher
reconciles the derived index after any write.

Destructive ops (`geo_delete_block`, `geo_delete_task`) gate on a two-phase
confirm-token handshake (stage → Gabriel confirms in his next message →
commit) and are both native rm. See ``destructive.py``.
"""

from __future__ import annotations

import logging
from typing import Any

from .destructive import DESTRUCTIVE_TOOLS
from .tools_read import READ_TOOLS
from .tools_write import WRITE_TOOLS

logger = logging.getLogger("plugin.geo-tools")

TOOLSET = "geo"

_DISABLED = frozenset({
    "geo_move_block", "geo_link_block_to_day", "geo_update_task",
    "geo_add_reminder", "geo_create_task",
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
    logger.info("geo-tools: registered %d tools (%d disabled)",
                len(all_tools), len(_DISABLED))


def register(ctx) -> None:
    _register_all(ctx)
