"""
MCP stdio server exposing `mcp_hermes_dispatch_subagent`.

Why one tool with a `target` arg instead of two tools:
the caller (hermes's agent loop OR the Swift AgentWorkspaceManager via an
in-app MCP client) shouldn't have to switch tool names to move a job from the
laptop to a hetzner VM. Target is data, not API.

Tool input schema:

    {
      target:                "local" | "remote:<name>",
      block_id:              str,           # the Geo block id whose frontmatter we stamp
      prompt:                str,           # passed to pi -p
      resume_pi_session_id:  str | None,    # pi --session <id> on resume turns
      provider:              "anthropic" | "openai-codex",
      model:                 str | None,    # pi --model <m>
      effort:                "low" | "medium" | "high" | None
    }

Tool output:

    {
      dispatch_id:     str,    # hermes's UUIDv7 for this dispatch
      pi_session_id:   str,    # pi's UUIDv7, captured from the first session event
      status:          "running" | "capacity" | "failed",
      workspace_path:  str
    }
"""

import asyncio
import json
import sys
from pathlib import Path
from typing import Any

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

from .frontmatter_queue import FrontmatterQueue
from .local_dispatcher import DispatchRequest, LocalDispatcher
from .remote_dispatcher import RemoteDispatcher, load_targets

TOOL_NAME = "mcp_hermes_dispatch_subagent"

TOOL_SCHEMA: dict[str, Any] = {
    "type": "object",
    "required": ["target", "block_id", "prompt", "provider"],
    "properties": {
        "target": {
            "type": "string",
            "description": "Dispatch target. Either 'local' or 'remote:<name>' where <name> matches an entry in ~/.hermes/dispatch-targets.yaml.",
        },
        "block_id": {
            "type": "string",
            "description": "Geo block id (UUIDv7 or path-safe identifier) whose frontmatter receives the stamped symphony_session_id.",
        },
        "prompt": {
            "type": "string",
            "description": "Prompt passed verbatim to `pi -p`.",
        },
        "resume_pi_session_id": {
            "type": ["string", "null"],
            "description": "Pass pi's prior session id to resume the turn. Distinct from the dispatch_id returned by this tool.",
        },
        "provider": {
            "type": "string",
            "enum": ["anthropic", "openai-codex"],
            "description": "LLM provider for pi: 'anthropic' → --provider anthropic, 'openai-codex' → --provider openai.",
        },
        "model": {
            "type": ["string", "null"],
            "description": "Model identifier passed to pi --model. Omit for pi's default.",
        },
        "effort": {
            "type": ["string", "null"],
            "enum": ["low", "medium", "high", None],
            "description": "Reasoning effort hint. Currently stamped to frontmatter only; pi has no native flag.",
        },
    },
}


def _build_server() -> tuple[Server, FrontmatterQueue, LocalDispatcher, dict[str, RemoteDispatcher]]:
    server = Server("dispatch-subagent")
    frontmatter = FrontmatterQueue()
    local = LocalDispatcher(frontmatter=frontmatter)

    remote_dispatchers: dict[str, RemoteDispatcher] = {}
    for name, target in load_targets().items():
        remote_dispatchers[name] = RemoteDispatcher(target, frontmatter=frontmatter)

    @server.list_tools()
    async def _list_tools() -> list[Tool]:
        return [
            Tool(
                name=TOOL_NAME,
                description=(
                    "Spawn one pi turn against an issue workspace. Local or remote "
                    "via the `target` arg. Returns immediately once pi emits its "
                    "first session event; remaining stdout drains in the "
                    "background and gets coalesced into frontmatter updates."
                ),
                inputSchema=TOOL_SCHEMA,
            )
        ]

    @server.call_tool()
    async def _call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        if name != TOOL_NAME:
            raise ValueError(f"unknown tool: {name}")

        target = str(arguments.get("target", "local"))
        req = DispatchRequest(
            block_id=str(arguments["block_id"]),
            prompt=str(arguments["prompt"]),
            provider=str(arguments["provider"]),
            model=arguments.get("model"),
            effort=arguments.get("effort"),
            resume_pi_session_id=arguments.get("resume_pi_session_id"),
        )

        if target == "local":
            result = await local.dispatch(req)
        elif target.startswith("remote:"):
            tname = target.split(":", 1)[1]
            disp = remote_dispatchers.get(tname)
            if disp is None:
                result = {
                    "dispatch_id": "",
                    "pi_session_id": "",
                    "status": "failed",
                    "workspace_path": "",
                    "error": f"unknown remote target: {tname}",
                }
            else:
                result = await disp.dispatch(req)
        else:
            result = {
                "dispatch_id": "",
                "pi_session_id": "",
                "status": "failed",
                "workspace_path": "",
                "error": f"invalid target: {target}",
            }

        return [TextContent(type="text", text=json.dumps(result))]

    return server, frontmatter, local, remote_dispatchers


async def _run() -> None:
    server, _fm, _local, _remotes = _build_server()
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


def main() -> None:
    try:
        asyncio.run(_run())
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
