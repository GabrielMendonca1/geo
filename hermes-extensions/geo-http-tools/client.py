"""HTTP client for Gabriel's Geo macOS app (Slice A localhost API).

Connection contract:
    ~/Library/Application Support/Geo/api.json  →  {"port": int, "pid": int, ...}
    macOS Keychain  service="geo-api-bootstrap", account="hermes-runtime"  →  bearer token

Why a singleton: per-process connection pool + in-memory token cache keep p50
latency under a couple ms on localhost (no Keychain re-read, no TCP handshake).

Lazy refresh: if Geo rotates the bearer mid-session, the next request returns
401 with ``WWW-Authenticate: Bearer realm="rotated"``. We re-read the Keychain
once and retry. A second 401 means the rotation didn't reach the Keychain —
hard fail so the caller surfaces it instead of looping.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
from pathlib import Path
from typing import Any, Optional

import httpx

GEO_API_JSON = Path.home() / "Library" / "Application Support" / "Geo" / "api.json"
KEYCHAIN_SERVICE = "geo-api-bootstrap"
KEYCHAIN_ACCOUNT = "hermes-runtime"
CALLER_ID = "hermes-runtime"
ROTATED_REALM = 'Bearer realm="rotated"'


class GeoError(Exception):
    pass


class GeoUnreachable(GeoError):
    """Geo.app is not running or api.json is stale."""


class GeoAuthRotated(GeoError):
    """Token rotated mid-flight and the second attempt also 401'd."""


class GeoAPIError(GeoError):
    def __init__(self, status_code: int, body: Any):
        self.status_code = status_code
        self.body = body
        super().__init__(f"Geo API {status_code}: {body}")


def _read_api_json() -> tuple[int, int]:
    if not GEO_API_JSON.exists():
        raise GeoUnreachable(f"{GEO_API_JSON} missing — Geo.app likely closed")
    try:
        raw = GEO_API_JSON.read_text(encoding="utf-8")
        obj = json.loads(raw)
        port = int(obj["port"])
        pid = int(obj["pid"])
    except (json.JSONDecodeError, KeyError, ValueError, TypeError) as e:
        raise GeoUnreachable(f"{GEO_API_JSON} unreadable: {e}") from e
    try:
        os.kill(pid, 0)
    except ProcessLookupError as e:
        raise GeoUnreachable(f"Geo.app pid {pid} not running (stale api.json)") from e
    except PermissionError:
        # Process exists, owned by another uid. On macOS this shouldn't happen
        # for the user's own Geo.app — but treat as alive rather than fail.
        pass
    return port, pid


def _read_keychain_token() -> str:
    env_token = os.environ.get("GEO_API_TOKEN")
    if env_token and env_token.strip():
        return env_token.strip()
    try:
        proc = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s", KEYCHAIN_SERVICE,
                "-a", KEYCHAIN_ACCOUNT,
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=5.0,
        )
    except subprocess.TimeoutExpired as e:
        raise GeoUnreachable("keychain lookup timed out") from e
    if proc.returncode != 0:
        raise GeoUnreachable(
            f"keychain miss ({KEYCHAIN_SERVICE}/{KEYCHAIN_ACCOUNT}): "
            f"{proc.stderr.strip() or 'not found'}"
        )
    token = proc.stdout.strip()
    if not token:
        raise GeoUnreachable("keychain returned empty token")
    return token


class GeoAPIClient:
    _instance: Optional["GeoAPIClient"] = None
    _instance_lock = asyncio.Lock()

    def __init__(self) -> None:
        port, pid = _read_api_json()
        self._port = port
        self._pid = pid
        self._token = _read_keychain_token()
        self._client = httpx.AsyncClient(
            base_url=f"http://127.0.0.1:{port}/v1",
            headers=self._build_headers(),
            http2=False,
            timeout=httpx.Timeout(connect=2.0, read=10.0, write=10.0, pool=2.0),
            limits=httpx.Limits(max_keepalive_connections=4, max_connections=8),
        )

    def _build_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._token}",
            "X-Caller-Id": CALLER_ID,
            "Accept": "application/json",
        }

    @classmethod
    async def get_instance(cls) -> "GeoAPIClient":
        async with cls._instance_lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    @classmethod
    async def reset_instance(cls) -> None:
        async with cls._instance_lock:
            inst = cls._instance
            cls._instance = None
        if inst is not None:
            await inst.aclose()

    async def aclose(self) -> None:
        try:
            await self._client.aclose()
        except Exception:
            pass

    async def _refresh_token(self) -> None:
        new_token = _read_keychain_token()
        self._token = new_token
        self._client.headers["Authorization"] = f"Bearer {new_token}"

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: Optional[dict] = None,
        json_body: Any = None,
        _allow_reconnect: bool = True,
    ) -> Any:
        """Issue an HTTP request, self-healing a stale ephemeral port.

        Geo rebinds a new port on each launch. A connect failure means the
        cached port is dead: drop the singleton, rebuild it from a fresh
        api.json read (new port + token), and retry through the new instance
        exactly once. A second connect failure is a hard ``GeoUnreachable``.
        """
        try:
            resp = await self._client.request(method, path, params=params, json=json_body)
        except (httpx.ConnectError, httpx.ConnectTimeout) as e:
            if not _allow_reconnect:
                raise GeoUnreachable(
                    f"Geo unreachable at 127.0.0.1:{self._port} after reconnect: {e}"
                ) from e
            await type(self).reset_instance()
            fresh = await type(self).get_instance()
            return await fresh._request(
                method,
                path,
                params=params,
                json_body=json_body,
                _allow_reconnect=False,
            )
        if resp.status_code == 401 and ROTATED_REALM in resp.headers.get("www-authenticate", ""):
            await self._refresh_token()
            resp = await self._client.request(method, path, params=params, json=json_body)
            if resp.status_code == 401:
                raise GeoAuthRotated(
                    "Bearer rotated but Keychain still serving old token"
                )
        if 200 <= resp.status_code < 300:
            if not resp.content:
                return None
            return _safe_json(resp)
        raise GeoAPIError(resp.status_code, _safe_json(resp))

    async def get(self, path: str, **params: Any) -> Any:
        cleaned = {k: v for k, v in params.items() if v is not None}
        return await self._request("GET", path, params=cleaned or None)

    async def post(self, path: str, json: Any = None) -> Any:
        return await self._request("POST", path, json_body=json)

    async def patch(self, path: str, json: Any = None) -> Any:
        return await self._request("PATCH", path, json_body=json)

    async def delete(self, path: str) -> Any:
        return await self._request("DELETE", path)


def _safe_json(resp: httpx.Response) -> Any:
    try:
        return resp.json()
    except (json.JSONDecodeError, ValueError):
        return {"raw": resp.text[:2000]}
