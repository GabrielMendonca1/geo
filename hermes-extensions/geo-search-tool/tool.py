"""geo-search-tool — on-demand Geo context search.

Exposes a single tool, ``geo_search_context``, that the agent calls when it
needs Geo state, instead of the old always-on geo-context hook rewriting
MEMORY.md every turn. The actual fetch + nano-model summarize logic lives in
hooks/geo-context/handler.py and is imported here so it is defined once.
"""

from __future__ import annotations

import importlib.util
import json
import logging
import os
from pathlib import Path
from typing import Any, Callable, Optional

logger = logging.getLogger("plugin.geo-search-tool")

TOOLSET = "geo_context"


def _candidate_handler_paths() -> list[Path]:
    here = Path(__file__).resolve().parent
    home = Path(os.path.expanduser("~"))
    return [
        home / ".hermes" / "hooks" / "geo-context" / "handler.py",
        here.parent.parent / "hermes" / "hooks" / "geo-context" / "handler.py",
        here.parent / "hermes" / "hooks" / "geo-context" / "handler.py",
    ]


def _load_search_context() -> Optional[Callable]:
    for path in _candidate_handler_paths():
        if not path.exists():
            continue
        try:
            spec = importlib.util.spec_from_file_location("geo_context_handler", path)
            if spec is None or spec.loader is None:
                continue
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            fn = getattr(module, "search_context", None)
            if callable(fn):
                return fn
        except Exception as e:
            logger.warning("geo-search-tool: failed loading handler at %s: %s", path, e)
    return None


_search_context: Optional[Callable] = None


async def _handle_geo_search_context(args: dict, **_kw: Any) -> str:
    global _search_context
    if _search_context is None:
        _search_context = _load_search_context()
    if _search_context is None:
        return json.dumps({"ok": False, "error": "geo-context handler not found"})
    args = args or {}
    query = args.get("query", "")
    with_summary = bool(args.get("with_summary", False))
    try:
        result = await _search_context(query, with_summary)
    except Exception as e:
        return json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"})
    return json.dumps(result, default=str)


SCHEMA = {
    "name": "geo_search_context",
    "description": (
        "Search Gabriel's Geo app for blocks matching a query and return the "
        "results (and an optional nano-model summary). Use this on demand when "
        "you need fresh Geo state for the current task — it is NOT injected "
        "automatically every turn. Returns {ok, query, results, summary, error}; "
        "ok=False with error set when Geo.app is closed."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Full-text search query over Geo blocks.",
            },
            "with_summary": {
                "type": "boolean",
                "description": (
                    "When true, also return a telegraphic nano-model summary of "
                    "the results (cheaper to read than raw matches). Default false."
                ),
                "default": False,
            },
        },
        "required": ["query"],
    },
}


def register(ctx) -> None:
    ctx.register_tool(
        name=SCHEMA["name"],
        toolset=TOOLSET,
        schema=SCHEMA,
        handler=_handle_geo_search_context,
        is_async=True,
        description=SCHEMA["description"],
        emoji="",
    )
    logger.info("geo-search-tool: registered geo_search_context")
