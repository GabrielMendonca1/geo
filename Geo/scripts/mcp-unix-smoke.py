#!/usr/bin/env python3
"""
Geo MCP unix-socket smoke test.

Exercises the running Geo macOS app's local MCP listener end-to-end over its
Unix socket transport. Sends a line-framed JSON-RPC `initialize` handshake with
the endpoint's bearer token, then calls `list_tasks` and `list_blocks`.

Wire contract: docs/mcp-cache-contract.md
Handshake / token extraction: Shared/Infrastructure/MCP/MCPConnection.swift
                               Shared/Infrastructure/MCP/MCPAuthGuard.swift

Stdlib only — no pip dependencies.

Usage:

    # Default endpoint 'cli', default socket path
    python3 scripts/mcp-unix-smoke.py

    # Different endpoint
    python3 scripts/mcp-unix-smoke.py --endpoint vm-worker

    # Custom socket path
    python3 scripts/mcp-unix-smoke.py \\
        --socket "$HOME/Library/Application Support/Geo/mcp.sock"

    # Custom endpoints.json
    python3 scripts/mcp-unix-smoke.py \\
        --endpoints "$HOME/Library/Application Support/Geo/endpoints.json"

Exit codes:
    0  all three calls (initialize + list_tasks + list_blocks) succeeded
    1  any failure (bad socket, bad token, RPC error, timeout, etc.)
"""

from __future__ import annotations

import argparse
import json
import os
import select
import socket
import sys
from pathlib import Path
from typing import Any

DEFAULT_SOCKET = "~/Library/Application Support/Geo/mcp.sock"
DEFAULT_ENDPOINTS_JSON = "~/Library/Application Support/Geo/endpoints.json"
DEFAULT_ENDPOINT_NAME = "cli"
RECV_TIMEOUT_SECS = 5.0
PROTOCOL_VERSION = "2024-11-05"


KEYCHAIN_SERVICE = "ai.geo.endpoints"


def keychain_get(account: str) -> str | None:
    import subprocess
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
            capture_output=True, text=True, timeout=8,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    token = result.stdout.strip()
    return token or None


def load_token(endpoints_path: Path, endpoint_name: str) -> str:
    if not endpoints_path.exists():
        raise SystemExit(f"error: endpoints file not found: {endpoints_path}")

    try:
        raw = endpoints_path.read_text(encoding="utf-8")
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: failed to parse {endpoints_path}: {exc}")

    if isinstance(data, dict):
        records = data.get("endpoints") if "endpoints" in data else [data]
        if not isinstance(records, list):
            records = [data]
    elif isinstance(data, list):
        records = data
    else:
        raise SystemExit(f"error: unexpected endpoints.json shape: {type(data).__name__}")

    for rec in records:
        if not isinstance(rec, dict):
            continue
        name = rec.get("name") or rec.get("id")
        if name is None:
            continue
        if str(name) == endpoint_name:
            token = rec.get("token")
            if isinstance(token, str) and token:
                return token
            ref = rec.get("tokenKeychainRef")
            if not isinstance(ref, str) or not ref:
                rid = rec.get("id")
                if isinstance(rid, str) and rid:
                    ref = f"mcp_endpoint_token_{rid}"
            if isinstance(ref, str) and ref:
                kc_token = keychain_get(ref)
                if kc_token:
                    return kc_token
                raise SystemExit(
                    f"error: endpoint '{endpoint_name}' resolved to keychain ref "
                    f"'{ref}' (service='{KEYCHAIN_SERVICE}') but `security` returned "
                    f"no entry. Try unlocking the login keychain and approving the "
                    f"prompt: security find-generic-password -s {KEYCHAIN_SERVICE} -a {ref} -w"
                )
            raise SystemExit(
                f"error: endpoint '{endpoint_name}' has neither 'token' nor "
                f"'tokenKeychainRef' nor 'id' — cannot resolve a bearer token."
            )

    available = []
    for rec in records:
        if isinstance(rec, dict):
            label = rec.get("name") or rec.get("id")
            if label:
                available.append(str(label))
    raise SystemExit(
        f"error: endpoint '{endpoint_name}' not found in {endpoints_path}. "
        f"Available: {available or '(none)'}"
    )


def connect_unix(sock_path: Path) -> socket.socket:
    if not sock_path.exists():
        raise SystemExit(
            f"error: unix socket not found at {sock_path}. "
            f"Is the Geo app running with the MCP listener enabled?"
        )
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(RECV_TIMEOUT_SECS)
    try:
        s.connect(str(sock_path))
    except (ConnectionRefusedError, FileNotFoundError, OSError) as exc:
        raise SystemExit(f"error: failed to connect to {sock_path}: {exc}")
    return s


def send_frame(sock: socket.socket, payload: dict[str, Any]) -> None:
    data = (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")
    sock.sendall(data)


class FrameReader:
    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._buf = bytearray()

    def read_frame(self, timeout: float = RECV_TIMEOUT_SECS) -> dict[str, Any]:
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line = bytes(self._buf[:nl]).replace(b"\r", b"")
                del self._buf[: nl + 1]
                if not line:
                    continue
                try:
                    return json.loads(line.decode("utf-8"))
                except json.JSONDecodeError as exc:
                    raise RuntimeError(f"malformed JSON frame: {exc}: {line!r}")

            ready, _, _ = select.select([self._sock], [], [], timeout)
            if not ready:
                raise TimeoutError(f"no frame received within {timeout}s")
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("server closed connection")
            self._buf.extend(chunk)


def read_response_for_id(reader: FrameReader, want_id: int) -> dict[str, Any]:
    while True:
        frame = reader.read_frame()
        if frame.get("method") == "ping" and "id" not in frame:
            continue
        if "id" not in frame and frame.get("method"):
            continue
        if frame.get("id") == want_id:
            return frame


def call(
    sock: socket.socket,
    reader: FrameReader,
    request_id: int,
    method: str,
    params: dict[str, Any],
    label: str,
) -> bool:
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": params,
    }
    send_frame(sock, payload)
    try:
        resp = read_response_for_id(reader, request_id)
    except (TimeoutError, ConnectionError, RuntimeError) as exc:
        print(f"FAIL {label} id={request_id}: {exc}")
        return False

    if "error" in resp:
        print(f"FAIL {label} id={request_id}: {json.dumps(resp['error'])}")
        return False

    result = resp.get("result")
    if isinstance(result, dict) and result.get("isError") is True:
        print(f"FAIL {label} id={request_id}: tool error: {json.dumps(result)}")
        return False

    print(f"OK {label} id={request_id}")
    return True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="mcp-unix-smoke",
        description="End-to-end smoke test for Geo's local MCP unix-socket listener.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--socket",
        default=DEFAULT_SOCKET,
        help=f"Path to the MCP unix socket (default: {DEFAULT_SOCKET})",
    )
    parser.add_argument(
        "--endpoint",
        default=DEFAULT_ENDPOINT_NAME,
        help=f"Endpoint name or id to authenticate as (default: {DEFAULT_ENDPOINT_NAME})",
    )
    parser.add_argument(
        "--endpoints",
        default=DEFAULT_ENDPOINTS_JSON,
        help=f"Path to endpoints.json (default: {DEFAULT_ENDPOINTS_JSON})",
    )
    args = parser.parse_args(argv)

    sock_path = Path(os.path.expanduser(args.socket))
    endpoints_path = Path(os.path.expanduser(args.endpoints))

    token = load_token(endpoints_path, args.endpoint)
    sock = connect_unix(sock_path)
    reader = FrameReader(sock)

    successes = 0
    total = 3

    init_ok = call(
        sock,
        reader,
        request_id=1,
        method="initialize",
        params={
            "authToken": token,
            "_meta": {"authToken": token},
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "mcp-unix-smoke", "version": "1.0.0"},
        },
        label="initialize",
    )
    if init_ok:
        successes += 1

    if not init_ok:
        try:
            sock.close()
        except OSError:
            pass
        return 1

    if call(
        sock,
        reader,
        request_id=2,
        method="tools/call",
        params={"name": "list_tasks", "arguments": {"days": 7}},
        label="tools/call list_tasks",
    ):
        successes += 1

    if call(
        sock,
        reader,
        request_id=3,
        method="tools/call",
        params={
            "name": "list_blocks",
            "arguments": {"days": 7, "include_content": False},
        },
        label="tools/call list_blocks",
    ):
        successes += 1

    try:
        sock.close()
    except OSError:
        pass

    return 0 if successes == total else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        sys.exit(1)
