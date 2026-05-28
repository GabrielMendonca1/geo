from __future__ import annotations

import logging

from .confirm import pre_gateway_dispatch_hook, pre_tool_call_hook

logger = logging.getLogger("plugin.whatsapp-confirm")


def register(ctx) -> None:
    try:
        ctx.register_hook("pre_gateway_dispatch", pre_gateway_dispatch_hook)
    except Exception as e:
        logger.warning("pre_gateway_dispatch hook registration failed: %s", e)
    try:
        ctx.register_hook("pre_tool_call", pre_tool_call_hook)
    except Exception as e:
        logger.warning("pre_tool_call hook registration failed: %s", e)
    logger.info("whatsapp-confirm: hooks registered (pre_gateway_dispatch, pre_tool_call)")
