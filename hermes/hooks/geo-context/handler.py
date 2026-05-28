"""
geo-context hook — fetches User Profile, Memory and Today blocks from Gabriel's
Geo app via its HTTP API at 127.0.0.1:<port>, token from Keychain, and writes
the result to ~/.hermes/memories/MEMORY.md so hermes's own memory-injection
picks it up when building system prompts.

Fires on agent:start (every turn) and session:reset. TTL+hash gated:
- Skip HTTP entirely if last successful fetch was <TTL_SECONDS ago.
- Skip MEMORY.md rewrite if body hash is unchanged (preserves prompt cache).
Silently bails when Geo.app is closed (api.json stale / pid dead / connect fail).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import shutil
import subprocess
import time
import urllib.parse
from pathlib import Path
from typing import Optional

import httpx

HERMES_HOME = Path(os.path.expanduser("~/.hermes"))
MEMORY_PATH = HERMES_HOME / "memories" / "MEMORY.md"
STATE_PATH = Path(__file__).parent / ".state.json"
GEO_API_JSON = Path(os.path.expanduser("~/Library/Application Support/Geo/api.json"))
KEYCHAIN_SERVICE = "geo-api-bootstrap"
KEYCHAIN_ACCOUNT = "hermes-hook"
HAIKU_MODEL = "claude-haiku-4-5"
TODAY_SUMMARIZE_THRESHOLD = 600
MAX_MEMORY_BODY = 4000
TTL_SECONDS = 60.0


def _log(msg: str) -> None:
    print(f"[geo-context] {msg}", flush=True)


def _unwrap_block(raw: Optional[str]) -> Optional[str]:
    """Geo's get_block_by_title returns a JSON envelope; pull `.markdown` and
    strip its frontmatter so we don't double-wrap. Returns None on miss
    sentinels ("No block found matching title: ...")."""
    if not raw:
        return None
    if raw.lstrip().lower().startswith("no block found"):
        return None
    try:
        obj = json.loads(raw)
        md = obj.get("markdown") or obj.get("body") or obj.get("content")
        if md:
            return _strip_frontmatter(md)
    except (json.JSONDecodeError, AttributeError):
        pass
    return _strip_frontmatter(raw)


def _format_today(raw: Optional[str]) -> Optional[str]:
    """Geo's get_today returns {block_ids, capture_count, id}; render as a
    one-line summary humans/LLMs can scan."""
    if not raw:
        return None
    try:
        obj = json.loads(raw)
        date = obj.get("id", "today")
        block_ids = obj.get("block_ids") or []
        capture_count = obj.get("capture_count", 0)
        parts = [f"date: {date}"]
        if block_ids:
            parts.append(f"linked blocks: {len(block_ids)}")
        if capture_count:
            parts.append(f"captures: {capture_count}")
        if len(parts) == 1:
            parts.append("nothing logged yet")
        return " · ".join(parts)
    except (json.JSONDecodeError, AttributeError):
        return raw


def _read_keychain_token() -> Optional[str]:
    try:
        result = subprocess.run(
            ["security", "find-generic-password",
             "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True, text=True, timeout=2.0,
        )
    except Exception as e:
        _log(f"keychain read failed: {e}")
        return None
    if result.returncode != 0:
        _log(f"keychain entry missing (service={KEYCHAIN_SERVICE} account={KEYCHAIN_ACCOUNT})")
        return None
    tok = (result.stdout or "").strip()
    return tok or None


def _read_api_json() -> Optional[dict]:
    if not GEO_API_JSON.exists():
        return None
    try:
        obj = json.loads(GEO_API_JSON.read_text(encoding="utf-8"))
        port = int(obj.get("port") or 0)
        pid = int(obj.get("pid") or 0)
        if not port or not pid:
            return None
        try:
            os.kill(pid, 0)
        except OSError:
            return None
        return {"port": port, "pid": pid}
    except Exception:
        return None


async def _safe_get(client: httpx.AsyncClient, path: str, token_ref: dict) -> Optional[str]:
    try:
        r = await client.get(path)
    except httpx.RequestError as e:
        _log(f"GET {path} failed: {e}")
        return None
    if r.status_code == 401:
        new_tok = _read_keychain_token()
        if new_tok and new_tok != token_ref.get("token"):
            token_ref["token"] = new_tok
            client.headers["Authorization"] = f"Bearer {new_tok}"
            try:
                r = await client.get(path)
            except httpx.RequestError as e:
                _log(f"GET {path} retry failed: {e}")
                return None
        if r.status_code == 401:
            _log(f"GET {path} unauthorized after token refresh")
            return None
    if r.status_code == 200:
        return r.text
    if r.status_code == 404:
        return None
    _log(f"GET {path} -> {r.status_code}")
    return None


async def _fetch_geo_blocks():
    info = _read_api_json()
    if not info:
        return None, None, None
    token = _read_keychain_token()
    if not token:
        return None, None, None
    token_ref = {"token": token}
    base = f"http://127.0.0.1:{info['port']}"
    headers = {
        "Authorization": f"Bearer {token}",
        "X-Caller-Id": "hermes-hook",
    }
    try:
        async with httpx.AsyncClient(base_url=base, headers=headers, timeout=8.0) as client:
            profile_path = "/v1/blocks/by-title?title=" + urllib.parse.quote("User Profile")
            memory_path = "/v1/blocks/by-title?title=" + urllib.parse.quote("Memory")
            profile = await asyncio.wait_for(_safe_get(client, profile_path, token_ref), timeout=10.0)
            memory = await asyncio.wait_for(_safe_get(client, memory_path, token_ref), timeout=10.0)
            today = await asyncio.wait_for(_safe_get(client, "/v1/days/today", token_ref), timeout=10.0)
            return profile, memory, today
    except Exception as e:
        _log(f"http unreachable (Geo.app closed?): {e}")
        return None, None, None


async def _summarize_with_haiku(text: str, label: str) -> str:
    """Spawn `hermes -z` to summarize via Haiku. Uses the same auth as the
    running gateway so no API key juggling. Falls back to truncation."""
    hermes_bin = shutil.which("hermes") or os.path.expanduser("~/.local/bin/hermes")
    if not Path(hermes_bin).exists():
        return text[:1500]
    prompt = (
        f"Summarize {label} in <= 200 words. Be telegraphic, no preamble, "
        f"no markdown. Pure information density.\n\n{text}"
    )
    try:
        proc = await asyncio.create_subprocess_exec(
            hermes_bin,
            "-z", prompt,
            "-m", HAIKU_MODEL,
            "--provider", "anthropic",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=20.0)
        if proc.returncode == 0 and out:
            return out.decode("utf-8", errors="replace").strip()
        _log(f"haiku summarize exit {proc.returncode}: {err.decode()[:200]}")
    except Exception as e:
        _log(f"haiku summarize failed: {e}")
    return text[:1500]


def _strip_frontmatter(md: str) -> str:
    """Drop the leading YAML frontmatter from a markdown block, if present."""
    if not md.startswith("---"):
        return md.strip()
    parts = md.split("---", 2)
    return parts[2].strip() if len(parts) >= 3 else md.strip()


async def _build_body() -> Optional[str]:
    raw_profile, raw_memory, raw_today = await _fetch_geo_blocks()

    profile = _unwrap_block(raw_profile)
    memory = _unwrap_block(raw_memory)
    today = _format_today(raw_today)

    if not any([profile, memory, today]):
        return None

    sections: list[str] = [
        "<!-- auto-generated by hooks/geo-context — DO NOT edit by hand; "
        "edit the Soul/User-Profile/Memory blocks in Geo instead. -->\n"
    ]
    if profile:
        sections.append(f"## User profile\n\n{profile}")
    if memory:
        sections.append(f"## Memory\n\n{memory}")
    if today:
        body = today
        if len(body) > TODAY_SUMMARIZE_THRESHOLD:
            body = await _summarize_with_haiku(body, "today's day record")
        sections.append(f"## Today\n\n{body}")

    out = "\n\n".join(sections)
    if len(out) > MAX_MEMORY_BODY:
        out = out[:MAX_MEMORY_BODY].rsplit("\n", 1)[0] + "\n"
    return out


def _load_state() -> dict:
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_state(state: dict) -> None:
    try:
        STATE_PATH.write_text(json.dumps(state), encoding="utf-8")
    except Exception as e:
        _log(f"state persist failed: {e}")


def _hash(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


async def handle(event_type: str, context: dict) -> None:
    if event_type not in ("agent:start", "session:reset", "session:start"):
        return
    platform = context.get("platform", "?")
    state = _load_state()
    now = time.time()
    last_ts = float(state.get("last_fetch_ts") or 0)
    force = event_type == "session:reset"
    if not force and (now - last_ts) < TTL_SECONDS:
        return
    body = await _build_body()
    if not body:
        if event_type != "agent:start":
            _log(f"{event_type}: no Geo data fetched; leaving MEMORY.md untouched")
        return
    new_hash = _hash(body)
    if state.get("body_hash") == new_hash and MEMORY_PATH.exists():
        state["last_fetch_ts"] = now
        _save_state(state)
        return
    try:
        MEMORY_PATH.parent.mkdir(parents=True, exist_ok=True)
        MEMORY_PATH.write_text(body, encoding="utf-8")
        _log(f"{event_type} (platform={platform}) wrote {MEMORY_PATH.name} ({len(body)} chars)")
        _save_state({"last_fetch_ts": now, "body_hash": new_hash})
    except Exception as e:
        _log(f"write failed: {e}")
