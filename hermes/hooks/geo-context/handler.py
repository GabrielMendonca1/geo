"""
geo-context — reads User Profile, Memory, Interaction Protocol and Today
blocks (and arbitrary search results) directly from Gabriel's Geo vault files
(``~/GeoVault/``). File-native: no HTTP, no Keychain —
works even with Geo.app closed (the .md/.json files are truth).

Auto-injection is RE-ENABLED (HOOK.yaml events: [session:start,
session:reset]): handle() rewrites MEMORY.md with the fixed identity bundle —
profile + memory + interaction protocol + today, in that order — which
config.yaml injects into every turn. The search+summarize logic below is also
reused on demand by the geo_search_context tool (hermes-extensions/
geo-search-tool) via search_context() for arbitrary lookups beyond this bundle.

handle() is TTL+hash gated: it skips the vault re-scan if the last fetch was
<TTL_SECONDS ago and skips the MEMORY.md rewrite when the body hash is unchanged.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import shutil
import time
from pathlib import Path
from typing import Optional

import sys as _sys
_HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
if _HOOK_DIR not in _sys.path:
    _sys.path.insert(0, _HOOK_DIR)
import haiku

HERMES_HOME = Path(os.path.expanduser("~/.hermes"))
MEMORY_PATH = HERMES_HOME / "memories" / "MEMORY.md"
TURN_CONTEXT_DIR = HERMES_HOME / "runtime" / "geo-context"
STATE_PATH = Path(__file__).parent / ".state.json"
CONFIG_PATH = Path(__file__).parent.parent.parent / "config.yaml"


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
TURN_CONTEXT_MAX_CHARS = 1200
TURN_CONTEXT_TOPK = 4
TURN_CONTEXT_SEMANTIC_CANDIDATES = 80
SEARCH_STOPWORDS = {
    "a", "as", "o", "os", "um", "uma", "uns", "umas", "de", "do", "da", "dos", "das",
    "em", "no", "na", "nos", "nas", "por", "para", "pra", "com", "sem", "que", "qual",
    "quais", "como", "quando", "onde", "porque", "porquê", "e", "ou", "mas", "se", "isso",
    "isto", "esse", "essa", "este", "esta", "ele", "ela", "eu", "me", "meu", "minha", "seu",
    "sua", "estou", "esta", "está", "tô", "to", "fazendo", "hoje", "agora", "sobre",
    "the", "and", "or", "for", "with", "what", "when", "where", "how", "today", "now",
}


def _log(msg: str) -> None:
    print(f"[geo-context] {msg}", flush=True)


def _local_tz():
    from zoneinfo import ZoneInfo

    tz_name = "America/Sao_Paulo"
    try:
        import yaml

        data = yaml.safe_load(CONFIG_PATH.read_text()) or {}
        tz_name = data.get("timezone") or tz_name
    except Exception:
        pass
    return ZoneInfo(tz_name), tz_name


def _now_local():
    from datetime import datetime

    tz, tz_name = _local_tz()
    return datetime.now(tz), tz_name


def _anchor_local_day(anchor: Optional[str]) -> str:
    """Calendar day of a stored UTC anchor in Gabriel's timezone (matches the
    app's local-calendar bucketing; a naive [:10] is off by one for evenings)."""
    from datetime import datetime, timezone

    if not anchor:
        return ""
    try:
        dt = datetime.strptime(anchor[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return anchor[:10]
    return dt.astimezone(_local_tz()[0]).strftime("%Y-%m-%d")


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
        if obj.get("now_local"):
            off = obj.get("utc_offset") or ""
            if len(off) == 5:
                off = f"{off[:3]}:{off[3:]}"
            parts.append(f"now: {obj['now_local']} ({obj.get('timezone')}, UTC{off})")
        if block_ids:
            parts.append(f"linked blocks: {len(block_ids)}")
        if capture_count:
            parts.append(f"captures: {capture_count}")
        if len(parts) == 1:
            parts.append("nothing logged yet")
        return " · ".join(parts)
    except (json.JSONDecodeError, AttributeError):
        return raw


def _habit_due_today(rule: dict, anchor_day: str, today) -> bool:
    rtype = (rule or {}).get("type") or "daily"
    end = (rule or {}).get("endDate")
    if end and _anchor_local_day(end) and str(today) > _anchor_local_day(end):
        return False
    selected = (rule or {}).get("selectedWeekdays")
    if selected:
        return (today.isoweekday() % 7 + 1) in selected
    if rtype in ("daily", "custom"):
        return True
    if rtype == "weekdays":
        return today.weekday() < 5
    if not anchor_day:
        return True
    from datetime import date as _date
    a = _date.fromisoformat(anchor_day)
    if rtype in ("weekly", "biweekly"):
        return today.weekday() == a.weekday()
    if rtype == "monthly":
        return today.day == a.day
    if rtype == "yearly":
        return (today.month, today.day) == (a.month, a.day)
    return False


def _format_tasks(raw: Optional[str]) -> Optional[str]:
    """Render the pending-tasks envelope as a scannable '- title (anchor · prio)'
    list, plus one line each for today's habits (done-mark) and the nearest
    milestones — so the agent can nudge habits and track goals unprompted."""
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
        meta = [m for m in (_anchor_local_day(t.get("anchor")),
                            t.get("priority") if t.get("priority") not in (None, "unset") else None)
                if m]
        suffix = f" ({' · '.join(meta)})" if meta else ""
        lines.append(f"- {title}{suffix}")

    today = _now_local()[0].date()
    today_str = str(today)
    habit_bits = []
    for t in tasks:
        if not isinstance(t, dict) or t.get("kind") != "habit" or t.get("status") != "pending":
            continue
        anchor_day = _anchor_local_day(t.get("time_of_day") or "")
        if not _habit_due_today(t.get("rule") or {}, anchor_day, today):
            continue
        done = any(_anchor_local_day(str(o)) == today_str for o in (t.get("occurrences") or []))
        habit_bits.append(f"{'✓' if done else '○'} {t.get('title') or '?'}")
    if habit_bits:
        lines.append("Hábitos hoje: " + " · ".join(habit_bits[:6]))

    miles = sorted(
        (t for t in tasks if isinstance(t, dict)
         and t.get("kind") == "milestone" and t.get("status") == "pending"),
        key=lambda t: t.get("anchor") or "9999",
    )
    mile_bits = []
    for t in miles[:2]:
        day = _anchor_local_day(t.get("anchor"))
        left = ""
        if day:
            from datetime import date as _date
            left = f" ({(_date.fromisoformat(day) - today).days}d)"
        mile_bits.append(f"{t.get('title') or '?'} · {day}{left}")
    if mile_bits:
        lines.append("Milestones: " + " | ".join(mile_bits))

    return "\n".join(lines) if lines else None


GEO_BLOCKS_DIR = Path(os.path.expanduser("~/GeoVault/Blocks"))
GEO_TASKS_DIR = Path(os.path.expanduser("~/GeoVault/Tasks"))


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
    now, tz_name = _now_local()
    date = now.strftime("%Y-%m-%d")
    token = f"[[{date}]]"
    block_ids = []
    for p in _iter_block_files():
        try:
            if token in p.read_text(encoding="utf-8"):
                block_ids.append(str(p.relative_to(GEO_BLOCKS_DIR)))
        except OSError:
            continue
    return json.dumps({
        "id": date,
        "block_ids": block_ids,
        "capture_count": 0,
        "now_local": now.strftime("%Y-%m-%d %H:%M"),
        "timezone": tz_name,
        "utc_offset": now.strftime("%z"),
    })


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
            row = {
                "title": t.get("title"),
                "status": "pending",
                "kind": body.get("kind"),
                "anchor": body.get("due") or body.get("start") or body.get("target"),
                "priority": t.get("priority"),
            }
            if body.get("kind") == "habit":
                row["rule"] = body.get("rule")
                row["time_of_day"] = body.get("timeOfDay")
                row["occurrences"] = (body.get("occurrences") or [])[-7:]
            rows.append(row)
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


EXTRACT_TOPK = 6
EXTRACT_BODY_CAP = 4000


def _file_search(query: str, limit: int) -> list:
    import re

    terms = [
        t.lower()
        for t in re.findall(r"[\wÀ-ÿ]+", query, flags=re.UNICODE)
        if len(t) >= 3 and t.lower() not in SEARCH_STOPWORDS
    ]
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


def _safe_context_name(value: str) -> str:
    import re
    value = value or "unknown"
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)[:160] or "unknown"


def _compact_excerpt(body: str, query_terms: list[str], max_chars: int = 260) -> str:
    """Return a tiny relevant excerpt; no LLM call, no token blow-up."""
    lines = [ln.strip() for ln in (body or "").splitlines() if ln.strip()]
    if not lines:
        return ""
    lowered_terms = [t.lower() for t in query_terms if len(t) >= 3]
    best = []
    for ln in lines:
        low = ln.lower()
        score = sum(low.count(t) for t in lowered_terms)
        if score:
            best.append((score, ln))
    best.sort(key=lambda x: x[0], reverse=True)
    chosen = [ln for _, ln in best[:2]] or lines[:2]
    text = " / ".join(chosen)
    if len(text) > max_chars:
        text = text[: max_chars - 1].rstrip() + "…"
    return text


def _manifest_excerpt(body: str, max_chars: int = 260) -> str:
    lines = []
    for ln in (body or "").splitlines():
        s = ln.strip()
        if not s or s.startswith("---") or s.startswith("type:") or s.startswith("layer:"):
            continue
        lines.append(s)
        if len(" / ".join(lines)) >= max_chars:
            break
    text = " / ".join(lines)
    if len(text) > max_chars:
        text = text[: max_chars - 1].rstrip() + "…"
    return text


def _all_block_manifest() -> list[dict]:
    rows: list[dict] = []
    for p in _iter_block_files():
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        body = _strip_frontmatter(text)
        rows.append({
            "id": str(p.relative_to(GEO_BLOCKS_DIR)),
            "title": _block_h1(text) or p.stem.replace("-", " "),
            "body": body,
            "excerpt": _manifest_excerpt(body),
        })
    return rows


async def _semantic_file_search(query: str, limit: int) -> list:
    """Semantic per-turn router using Haiku/model.nano, with lexical fallback."""
    candidates = _all_block_manifest()
    if not candidates:
        return []
    # Keep the Haiku manifest bounded if the vault grows a lot. Lexical score is
    # only used as a cheap pre-sort; zero-score blocks remain eligible so semantic
    # matches can still surface synonyms.
    lexical = {h["id"]: h.get("score", 0) for h in _file_search(query, len(candidates))}
    candidates.sort(key=lambda c: lexical.get(c["id"], 0), reverse=True)
    bounded = candidates[:TURN_CONTEXT_SEMANTIC_CANDIDATES]
    try:
        selected_ids = await haiku.rank_blocks(query, bounded, limit=limit)
    except Exception as e:
        _log(f"semantic rank failed: {e}")
        selected_ids = None
    by_id = {c["id"]: c for c in candidates}
    if selected_ids:
        return [by_id[i] for i in selected_ids if i in by_id][:limit]
    return _file_search(query, limit)


async def _build_turn_context(message: str) -> str | None:
    """Build API-only Geo context for one user turn.

    Context-friendly by design: lexical top-k, tiny excerpts, hard cap. This
    runs automatically on every agent:start and writes a sidecar file consumed
    by the gateway before the model call. It is not persisted as the user's
    message.
    """
    import re
    query = (message or "").strip()
    if not query or not GEO_BLOCKS_DIR.exists():
        return None
    terms = [
        t.lower()
        for t in re.findall(r"[\wÀ-ÿ]+", query, flags=re.UNICODE)
        if len(t) >= 3 and t.lower() not in SEARCH_STOPWORDS
    ]
    hits = await _semantic_file_search(query, TURN_CONTEXT_TOPK)
    if not hits:
        return None

    lines = [
        "## Geo auto-context (API-only)",
        "Use if relevant; ignore if not. Do not mention this block unless asked.",
    ]
    for hit in hits:
        title = hit.get("title") or hit.get("id") or "?"
        excerpt = _compact_excerpt(hit.get("body") or "", terms)
        if excerpt:
            lines.append(f"- [[{title}]]: {excerpt}")
        else:
            lines.append(f"- [[{title}]]")
    out = "\n".join(lines).strip()
    if len(out) > TURN_CONTEXT_MAX_CHARS:
        out = out[:TURN_CONTEXT_MAX_CHARS].rsplit("\n", 1)[0].rstrip() + "\n…"
    return out or None


async def _write_turn_context(context: dict) -> str | None:
    session_id = _safe_context_name(str(context.get("session_id") or "unknown"))
    message = str(context.get("message") or "")
    TURN_CONTEXT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = TURN_CONTEXT_DIR / f"{session_id}.md"
    body = await _build_turn_context(message)
    if body:
        out_path.write_text(body, encoding="utf-8")
        _log(f"agent:start wrote turn context {out_path.name} ({len(body)} chars)")
        return body
    else:
        try:
            out_path.unlink()
        except FileNotFoundError:
            pass
    return None


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
    if event_type == "agent:start":
        body = await _write_turn_context(context)
        if body:
            # Hook contexts are mutable; gateway/run.py reads this immediately
            # and appends it to the ephemeral per-turn system context.
            context["geo_context"] = body
        return
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
