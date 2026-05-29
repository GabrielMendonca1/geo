from __future__ import annotations

import logging

from .tool import register as _register

logger = logging.getLogger("plugin.geo-search-tool")


def register(ctx) -> None:
    _register(ctx)
