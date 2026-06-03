"""Hermes plugin shell for geo-mcp-subscriber.

This extension is a LaunchAgent daemon (``daemon.py``), not a tool provider.
It registers nothing; the work happens out-of-process. The shell exists only so
the directory is a well-formed plugin if someone ever `hermes plugins enable`s
it. Install via ``install.sh`` (drops the LaunchAgent); do not enable it as a
plugin.
"""

from __future__ import annotations


def register(ctx) -> None:  # noqa: ARG001 — no tools; daemon does the work
    return
