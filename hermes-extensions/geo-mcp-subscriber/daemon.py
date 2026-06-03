#!/usr/bin/env python3
"""geo-mcp-subscriber — keep the geo-context boot bundle warm via MCP push.

Replaces the geo-context hook's session-start HTTP poll with a persistent
push subscription. Connects to the Geo macOS app's MCP server over its Unix
socket (``~/Library/Application Support/Geo/mcp.sock``, newline-delimited
JSON-RPC, no auth on the unix transport), subscribes to ``block`` and ``task``
changes (``geo/subscribe`` -> one-way ``geo/changed`` notifications), and on
every change refetches the four boot-bundle pieces — User Profile, Memory,
Interaction Protocol, Today — over the SAME socket and atomically rewrites
``~/.hermes/geo-cache/snapshot.json``.

The geo-context hook reads that snapshot (freshness-gated) instead of making
HTTP round-trips at session start, and falls back to live HTTP if the cache is
missing or stale (daemon down / Geo closed). So this daemon is a pure
accelerator: if it never runs, the hook behaves exactly as before.

The socket is BOTH the change signal and the fetch path — single transport,
no token / keychain / httpx / ephemeral port. Stdlib only.

Wire contract: Geo/docs/mcp-cache-contract.md
Reference client: Geo/scripts/mcp-unix-smoke.py
"""

from __future__ import annotations

import json
import os
import select
import socket
import sys
import time
from pathlib import Path
from typing import Any, Optional

SOCK_PATH = Path(os.path.expanduser(
    os.environ.get("GEO_MCP_SOCK", "~/Library/Application Support/Geo/mcp.sock")))
CACHE_DIR = Path(os.path.expanduser(
    os.environ.get("GEO_CACHE_DIR", "~/.hermes/geo-cache")))
SNAPSHOT = CACHE_DIR / "snapshot.json"
SNAPSHOT_TMP = CACHE_DIR / "snapshot.json.tmp"

# The geo-context boot bundle: three blocks by title + today's day record.
# Mirrors hermes/hooks/geo-context/handler.py::_fetch_geo_blocks — keep in sync.
BUNDLE = [("profile", "User Profile"), ("memory", "Memory"),
          ("protocol", "Interaction Protocol")]

DEBOUNCE_S = 1.5           # coalesce bursts of geo/changed before refetching
SAFETY_REFRESH_S = 600.0   # missed-event safety net (contract §3 recommendation)
TICK_S = 1.0
RECONNECT_MIN_S = 1.0
RECONNECT_MAX_S = 30.0
STABLE_UPTIME_S = 30.0     # a connection alive this long resets the backoff
RPC_TIMEOUT_S = 10.0
PROTOCOL_VERSION = "2024-11-05"


def _log(msg: str) -> None:
    print(f"[geo-mcp-subscriber] {msg}", flush=True)


class Disconnected(Exception):
    pass


class Subscriber:
    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._buf = bytearray()
        self._resp: dict[int, dict] = {}
        self._rid = 0
        self.dirty = False
        self.dirty_since = 0.0
        self.last_fetch = 0.0

    def _send(self, method: str, params: dict) -> int:
        self._rid += 1
        frame = json.dumps(
            {"jsonrpc": "2.0", "id": self._rid, "method": method, "params": params},
            separators=(",", ":"),
        ) + "\n"
        self._sock.sendall(frame.encode("utf-8"))
        return self._rid

    def _dispatch(self, frame: dict) -> None:
        # Server -> client notifications carry "method" and no response id.
        if "method" in frame:
            if frame["method"] == "geo/changed" and not self.dirty:
                self.dirty = True
                self.dirty_since = time.monotonic()
            # "ping" and any other notification: ignore (keepalive).
            return
        rid = frame.get("id")
        if rid is not None:
            self._resp[rid] = frame

    def _drain(self, timeout: float) -> None:
        """Read and dispatch whatever frames arrive within `timeout` seconds."""
        end = time.monotonic() + timeout
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line = bytes(self._buf[:nl]).replace(b"\r", b"")
                del self._buf[:nl + 1]
                if line:
                    try:
                        self._dispatch(json.loads(line.decode("utf-8")))
                    except json.JSONDecodeError:
                        _log(f"malformed frame: {line[:200]!r}")
                continue
            remaining = end - time.monotonic()
            if remaining <= 0:
                return
            ready, _, _ = select.select([self._sock], [], [], remaining)
            if not ready:
                return
            chunk = self._sock.recv(65536)
            if not chunk:
                raise Disconnected("server closed connection")
            self._buf.extend(chunk)

    def _call(self, method: str, params: dict) -> dict:
        rid = self._send(method, params)
        deadline = time.monotonic() + RPC_TIMEOUT_S
        while rid not in self._resp:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Disconnected(f"timeout waiting for {method} id={rid}")
            self._drain(min(TICK_S, remaining))
        return self._resp.pop(rid)

    def _tool_text(self, name: str, arguments: dict) -> Optional[str]:
        resp = self._call("tools/call", {"name": name, "arguments": arguments})
        if "error" in resp:
            _log(f"{name} rpc error: {resp['error']}")
            return None
        result = resp.get("result") or {}
        if result.get("isError"):
            return None
        for item in result.get("content") or []:
            if isinstance(item, dict) and item.get("type") == "text":
                return item.get("text")
        return None

    def handshake(self) -> None:
        self._call("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "geo-mcp-subscriber", "version": "1.0.0"},
        })
        sub = self._call("geo/subscribe", {"kinds": ["block", "task"]})
        _log(f"subscribed: {(sub.get('result') or {}).get('subscribed')}")

    def refresh(self) -> None:
        # Clear dirty up-front so a change arriving mid-fetch re-arms a refresh.
        self.dirty = False
        snap: dict[str, Any] = {}
        for key, title in BUNDLE:
            snap[key] = self._tool_text("get_block_by_title", {"title": title})
        snap["today"] = self._tool_text("get_today", {})
        snap["fetched_at"] = time.time()
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        SNAPSHOT_TMP.write_text(json.dumps(snap), encoding="utf-8")
        os.replace(SNAPSHOT_TMP, SNAPSHOT)
        self.last_fetch = time.monotonic()
        present = [k for k, _ in BUNDLE if snap.get(k)]
        _log(f"cache refreshed -> {SNAPSHOT.name} "
             f"(blocks: {present or 'none'}, today: {'yes' if snap['today'] else 'no'})")

    def run(self) -> None:
        self.handshake()
        self.refresh()
        while True:
            self._drain(TICK_S)
            now = time.monotonic()
            if self.dirty and (now - self.dirty_since) >= DEBOUNCE_S:
                self.refresh()
            elif (now - self.last_fetch) >= SAFETY_REFRESH_S:
                self.refresh()


def _connect() -> socket.socket:
    if not SOCK_PATH.exists():
        raise Disconnected(f"socket not found at {SOCK_PATH} (Geo.app closed?)")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(RPC_TIMEOUT_S)
    sock.connect(str(SOCK_PATH))
    return sock


def main() -> None:
    _log(f"start sock={SOCK_PATH} cache={SNAPSHOT}")
    backoff = RECONNECT_MIN_S
    while True:
        sock = None
        started = time.monotonic()
        try:
            sock = _connect()
            _log("connected")
            Subscriber(sock).run()
        except Disconnected as exc:
            _log(f"disconnected: {exc}")
        except Exception as exc:  # noqa: BLE001 — daemon must never die
            _log(f"error: {exc!r}")
        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        if (time.monotonic() - started) > STABLE_UPTIME_S:
            backoff = RECONNECT_MIN_S
        time.sleep(backoff)
        backoff = min(backoff * 2, RECONNECT_MAX_S)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
