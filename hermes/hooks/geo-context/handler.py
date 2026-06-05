"""
geo-context — fetches User Profile, Memory, Interaction Protocol and Today
blocks (and arbitrary search results) from Gabriel's Geo app via its HTTP API
at 127.0.0.1:<port>, token from Keychain.

Auto-injection is RE-ENABLED (HOOK.yaml events: [session:start,
session:reset]): handle() rewrites MEMORY.md with the fixed identity bundle —
profile + memory + interaction protocol + today, in that order — which
config.yaml injects into every turn. The bundle now includes the Interaction
Protocol block. The search+summarize logic below is also reused on demand by
the geo_search_context tool (hermes-extensions/geo-search-tool) via
search_context() for arbitrary lookups beyond this fixed bundle.

handle() is TTL+hash gated: it skips HTTP if last fetch was <TTL_SECONDS ago
and skips the MEMORY.md rewrite when the body hash is unchanged. Silently
bails when Geo.app is closed (api.json stale / pid dead / connect fail).
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

import sys as _sys
_HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
if _HOOK_DIR not in _sys.path:
    _sys.path.insert(0, _HOOK_DIR)
import haiku

HERMES_HOME = Path(os.path.expanduser("~/.hermes"))
MEMORY_PATH = HERMES_HOME / "memories" / "MEMORY.md"
STATE_PATH = Path(__file__).parent / ".state.json"
GEO_API_JSON = Path(os.path.expanduser("~/Library/Application Support/Geo/api.json"))
CONFIG_PATH = Path(__file__).parent.parent.parent / "config.yaml"
KEYCHAIN_SERVICE = "geo-api-bootstrap"
KEYCHAIN_ACCOUNT = "hermes-hook"


def _nano_model() -> str:
    """Resolve the nano model id: HERMES_NANO_MODEL env > config.yaml model.nano
    > fallback literal. config.yaml (model.full / model.nano) is the canonical
    source so a model retirement is a one-line config edit, not a code change."""
    env = os.environ.get("HERMES_NANO_MODEL")
    if env:
        return env
    try:
        import yaml

        data = yaml.safe_load(CONFIG_PATH.read_text()) or {}
        nano = (data.get("model") or {}).get("nano")
        if nano:
            return str(nano)
    except Exception:
        pass
    return "claude-haiku-4-5"


HAIKU_MODEL = _nano_model()
TODAY_SUMMARIZE_THRESHOLD = 600
MAX_MEMORY_BODY = 5000
TTL_SECONDS = 60.0
TASKS_MAX = 12


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


def _format_tasks(raw: Optional[str]) -> Optional[str]:
    """Render GET /v1/tasks (pending) as a scannable '- title (anchor · prio)' list."""
    if not raw:
        return None
    try:
        tasks = json.loads(raw)
    except (json.JSONDecodeError, AttributeError):
        return None
    if not isinstance(tasks, list):
        return None
    rows = [t for t in tasks if isinstance(t, dict)
            and t.get("status") == "pending"
            and t.get("kind") in ("task", "event")]
    rows.sort(key=lambda t: t.get("anchor") or "9999")
    lines = []
    for t in rows[:TASKS_MAX]:
        title = t.get("title") or "?"
        meta = [m for m in ((t.get("anchor") or "")[:10],
                            t.get("priority") if t.get("priority") not in (None, "unset") else None)
                if m]
        suffix = f" ({' · '.join(meta)})" if meta else ""
        lines.append(f"- {title}{suffix}")
    return "\n".join(lines) if lines else None


def _read_keychain_token() -> Optional[str]:
    env_token = os.environ.get("GEO_API_TOKEN")
    if env_token and env_token.strip():
        return env_token.strip()
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


GEO_BLOCKS_DIR = Path(os.path.expanduser("~/Library/Application Support/Geo/Blocks"))
GEO_TASKS_DIR = Path(os.path.expanduser("~/Library/Application Support/Geo/Tasks"))


def _iter_block_files():
    if not GEO_BLOCKS_DIR.exists():
        return
    for root, dirs, files in os.walk(GEO_BLOCKS_DIR):
        dirs[:] = [d for d in dirs if d != "Attachments"]
        for fn in files:
            if fn.endswith(".md"):
                yield Path(root) / fn


def _block_h1(text: str) -> Optional[str]:
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("# "):
            return s[2:].strip()
    return None


def _find_block_by_title(title: str) -> Optional[str]:
    want = (title or "").strip()
    for p in _iter_block_files():
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        name = p.stem
        if _block_h1(text) == want or name == want or name.replace("-", " ") == want:
            return text
    return None


def _today_envelope() -> str:
    from datetime import datetime

    date = datetime.now().strftime("%Y-%m-%d")
    token = f"[[{date}]]"
    block_ids = []
    for p in _iter_block_files():
        try:
            if token in p.read_text(encoding="utf-8"):
                block_ids.append(str(p.relative_to(GEO_BLOCKS_DIR)))
        except OSError:
            continue
    return json.dumps({"id": date, "block_ids": block_ids, "capture_count": 0})


def _pending_tasks_envelope() -> str:
    rows = []
    if GEO_TASKS_DIR.exists():
        for p in sorted(GEO_TASKS_DIR.glob("*.json")):
            try:
                t = json.loads(p.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if t.get("status") != "pending":
                continue
            body = t.get("body") or {}
            rows.append({
                "title": t.get("title"),
                "status": "pending",
                "kind": body.get("kind"),
                "anchor": body.get("due") or body.get("start") or body.get("target"),
                "priority": t.get("priority"),
            })
    return json.dumps(rows)


async def _fetch_geo_blocks():
    """Read the boot bundle straight from the vault files (truth) — works even
    with Geo.app closed. Returns the same envelope shapes the formatters expect
    (profile/memory/protocol raw .md; today/tasks JSON), or None when the vault
    is absent."""
    if not GEO_BLOCKS_DIR.exists():
        return None
    return {
        "profile": _find_block_by_title("User Profile"),
        "memory": _find_block_by_title("Memory"),
        "protocol": _find_block_by_title("Interaction Protocol"),
        "today": _today_envelope(),
        "tasks": _pending_tasks_envelope(),
    }


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


SEARCH_LIMIT = 8
EXTRACT_TOPK = 6
EXTRACT_BODY_CAP = 4000


def _file_search(query: str, limit: int) -> list:
    import re

    terms = [t.lower() for t in re.findall(r"[\w]+", query, flags=re.UNICODE)]
    if not terms:
        return []
    hits = []
    for p in _iter_block_files():
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        title = _block_h1(text) or p.stem.replace("-", " ")
        body = _strip_frontmatter(text)
        hay_title = title.lower()
        hay_body = body.lower()
        score = sum(3 * hay_title.count(t) + hay_body.count(t) for t in terms)
        if score:
            hits.append({"id": str(p.relative_to(GEO_BLOCKS_DIR)), "title": title,
                         "body": body, "score": score})
    hits.sort(key=lambda h: h["score"], reverse=True)
    return hits[:limit]


async def search_context(query: str, with_summary: bool = False) -> dict:
    """Answer a question from Gabriel's Geo blocks: relevance-search his vault
    (file-native — works app-closed), pull the full text of the top matches, and
    have Haiku extract ONLY the facts that answer the question, cited by block
    title. Returns:

        {"ok": bool, "query": str, "answer": str|None,
         "sources": [str], "results": str|None, "error": str|None}

    `answer` is the cited extraction; `results` holds the raw block context only
    as a fallback when extraction is unavailable."""
    query = (query or "").strip()
    if not query:
        return {"ok": False, "query": query, "answer": None, "sources": [],
                "results": None, "error": "empty query"}
    if not GEO_BLOCKS_DIR.exists():
        return {"ok": False, "query": query, "answer": None, "sources": [],
                "results": None, "error": "Geo vault not found"}

    sources: list = []
    docs: list = []
    for hit in _file_search(query, EXTRACT_TOPK):
        title = hit["title"] or hit["id"] or "?"
        sources.append(title)
        docs.append(f"### [[{title}]]\n{hit['body']}".strip()[:EXTRACT_BODY_CAP])

    if not docs:
        return {"ok": True, "query": query, "answer": None, "sources": [],
                "results": None, "error": None}

    context_text = "\n\n".join(docs)
    answer = await haiku.extract(query, context_text)
    return {"ok": True, "query": query, "answer": answer, "sources": sources,
            "results": (None if answer else context_text), "error": None}


async def _build_body() -> Optional[str]:
    bundle = await _fetch_geo_blocks()
    if not bundle:
        return None

    profile = _unwrap_block(bundle["profile"])
    memory = _unwrap_block(bundle["memory"])
    protocol = _unwrap_block(bundle["protocol"])
    today = _format_today(bundle["today"])
    tasks = _format_tasks(bundle["tasks"])

    if not any([profile, memory, protocol, today, tasks]):
        return None

    sections: list[str] = [
        "<!-- auto-generated by hooks/geo-context — DO NOT edit by hand; "
        "edit the Soul/User-Profile/Memory blocks in Geo instead. -->\n"
    ]
    if profile:
        sections.append(f"## User profile\n\n{profile}")
    if memory:
        sections.append(f"## Memory\n\n{memory}")
    if protocol:
        sections.append(f"## Interaction protocol\n\n{protocol}")
    if tasks:
        sections.append(f"## Open tasks\n\n{tasks}")
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
    if event_type not in ("session:start", "session:reset"):
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
