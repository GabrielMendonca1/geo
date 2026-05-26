"""
Bridge from dispatcher events to MCP tool calls on the parent hermes process.

Dispatchers emit FrontmatterUpdate(block_id, fields_to_merge) entries. We
coalesce per block_id with a 500 ms debounce and emit one JSON-RPC notification
back over the stdio MCP channel — hermes picks it up and turns it into a single
`mcp_geo_update_block` tool call.

Notification format hermes expects (matches the `notifications/message`
shape from the MCP spec):

    {
      "jsonrpc": "2.0",
      "method": "notifications/message",
      "params": {
        "level": "info",
        "logger": "dispatch-subagent",
        "data": {
          "kind": "frontmatter_update",
          "block_id": "<id>",
          "fields": { "symphony_session_id": "...", "symphony_state": "..." }
        }
      }
    }

Why a notification and not a direct tool call: MCP servers can't call tools on
other servers. Hermes is the only one with both `geo.update_block` and this
server wired in, so we surface our intent as a notification and let hermes
resolve it. This matches geo-claw's old "let the agent do it" pattern.
"""

import asyncio
import json
import sys
from collections import defaultdict
from dataclasses import dataclass


@dataclass(frozen=True)
class FrontmatterUpdate:
    block_id: str
    fields: dict[str, str]


class FrontmatterQueue:
    def __init__(self, *, debounce_ms: int = 500, sink=None) -> None:
        self._debounce = debounce_ms / 1000.0
        self._pending: dict[str, dict[str, str]] = defaultdict(dict)
        self._tasks: dict[str, asyncio.Task[None]] = {}
        self._sink = sink or self._default_sink
        self._lock = asyncio.Lock()

    async def submit(self, update: FrontmatterUpdate) -> None:
        async with self._lock:
            self._pending[update.block_id].update(update.fields)
            existing = self._tasks.get(update.block_id)
            if existing and not existing.done():
                existing.cancel()
            self._tasks[update.block_id] = asyncio.create_task(
                self._flush_after(update.block_id)
            )

    async def _flush_after(self, block_id: str) -> None:
        try:
            await asyncio.sleep(self._debounce)
        except asyncio.CancelledError:
            return
        async with self._lock:
            fields = self._pending.pop(block_id, None)
            self._tasks.pop(block_id, None)
        if not fields:
            return
        await self._sink(block_id, fields)

    @staticmethod
    async def _default_sink(block_id: str, fields: dict[str, str]) -> None:
        msg = {
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": {
                "level": "info",
                "logger": "dispatch-subagent",
                "data": {
                    "kind": "frontmatter_update",
                    "block_id": block_id,
                    "fields": fields,
                },
            },
        }
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()
