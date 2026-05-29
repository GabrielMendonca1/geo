#!/usr/bin/env python3
"""
whatsapp-extractor.py — Haiku-side phase of the WhatsApp extractor cron.

Reads the last 6h from ~/.hermes/wa_ingest.jsonl, buckets by chat (no
mechanical filtering — Haiku decides), classifies each bucket in parallel
via the Anthropic SDK using hermes's OAuth credential from auth.json,
and prints a single aggregated JSON envelope to stdout. Hermes cron
injects that stdout into the Opus agent's prompt, which decides what
to actually write to Geo.

Runs under `hermes cron create "0 */6 * * *" --script whatsapp-extractor.py`
(no --no-agent — we want the Opus phase to consume the JSON).
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from anthropic import AsyncAnthropic

HERMES_HOME = Path(os.path.expanduser("~/.hermes"))
JSONL_PATH = HERMES_HOME / "wa_ingest.jsonl"
AUTH_PATH = HERMES_HOME / "auth.json"
CONFIG_PATH = Path(__file__).parent.parent / "config.yaml"


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


WINDOW_HOURS = 6
HAIKU_MODEL = _nano_model()
MAX_CONCURRENT = 6
PER_CALL_TIMEOUT_S = 45.0
RETRY_ATTEMPTS = 2
RETRY_BACKOFF_S = 1.5
MAX_TOKENS_OUT = 2000

OAUTH_BETA = "oauth-2025-04-20"
CLAUDE_CODE_USER_AGENT = "claude-cli/2.1.152 (external, cli)"

HAIKU_PROMPT_TEMPLATE = """Você é classificador. NÃO resume, NÃO escreve, NÃO cria nada. Sua única tarefa: olhar essa conversa e propor (em JSON) o que pode valer a pena guardar no cérebro do Gabriel. Outro agente mais inteligente vai decidir o que de fato fazer com sua proposta — você só sugere.

Chat: {label} (group={is_group}, jid={chat_id})
Mensagens (cronológicas, últimas {window}h):
{messages}

Procure SOMENTE por:
- FATO sobre pessoa/projeto/decisão/preferência — algo que ainda vai ser verdade mês que vem
- TAREFA: o Gabriel se comprometeu (explícita ou implicitamente) a fazer algo
- LEMBRETE temporal: data específica importa
- URGENTE: alguém esperando ele agora (pergunta direta, deadline batendo)

NÃO sugira: conversa fiada, piadas, reações, notícias, encaminhamentos, combinados vagos. Dúvida = não sugere.

Retorne JSON estrito (sem markdown, sem prefácio, sem ```):
{{
  "chat": "{label}",
  "chat_id": "{chat_id}",
  "is_group": {is_group_lit},
  "proposals": {{
    "facts": [{{"content": "...", "about": "..."}}],
    "tasks": [{{"title": "...", "notes": "...", "due_hint": "YYYY-MM-DD ou null"}}],
    "reminders": [{{"trigger_at_hint": "YYYY-MM-DDTHH:MM", "action": "..."}}],
    "urgent": [{{"text": "...", "sender": "..."}}]
  }}
}}

Se nada vale a pena: retorne proposals com todas as listas vazias. Bias: propor MENOS."""


def log(msg: str) -> None:
    print(f"[whatsapp-extractor] {msg}", file=sys.stderr, flush=True)


def load_oauth_token() -> str | None:
    if not AUTH_PATH.exists():
        return None
    try:
        data = json.loads(AUTH_PATH.read_text(encoding="utf-8"))
    except Exception as e:
        log(f"auth.json unreadable: {e}")
        return None
    pool = (data.get("credential_pool") or {}).get("anthropic") or []
    entries = [e for e in pool if isinstance(e, dict) and e.get("access_token")]
    if not entries:
        return None
    entries.sort(key=lambda e: (e.get("priority", 999), -(e.get("expires_at_ms") or 0)))
    chosen = entries[0]
    exp_ms = chosen.get("expires_at_ms")
    if exp_ms and exp_ms / 1000.0 < datetime.now(timezone.utc).timestamp() + 60:
        log(f"primary anthropic OAuth token expired (id={chosen.get('id')})")
    return chosen.get("access_token")


def _is_empty_record(rec: dict) -> bool:
    """True for records that have literally no content (decrypt failures,
    empty-bodied media). These aren't messages — they're failed events."""
    if rec.get("type") == "unknown" and not (rec.get("text") or "").strip():
        return True
    return False


def _is_one_way_chat(chat: str) -> bool:
    """True for WhatsApp pseudo-chats Gabriel can't reply to anyway:
    newsletters (channels) and status broadcasts."""
    return chat.endswith("@newsletter") or chat.endswith("@broadcast")


def read_window() -> list[dict]:
    if not JSONL_PATH.exists():
        return []
    cutoff = datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)
    out: list[dict] = []
    dropped_empty = 0
    dropped_oneway = 0
    with JSONL_PATH.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                ts_raw = rec.get("ts", "")
                ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
            except Exception:
                continue
            if ts < cutoff:
                continue
            if _is_empty_record(rec):
                dropped_empty += 1
                continue
            if _is_one_way_chat(rec.get("chat") or ""):
                dropped_oneway += 1
                continue
            out.append(rec)
    if dropped_empty or dropped_oneway:
        log(f"dropped: empty/decrypt-fail={dropped_empty} one-way-channels={dropped_oneway}")
    return out


def bucket_by_chat(records: list[dict]) -> list[dict]:
    by_chat: dict[str, dict] = {}
    for r in records:
        chat = r.get("chat") or ""
        if not chat:
            continue
        bucket = by_chat.get(chat)
        if bucket is None:
            bucket = {
                "chat_id": chat,
                "is_group": bool(r.get("is_group")),
                "messages": [],
                "_name_counts": {},
            }
            by_chat[chat] = bucket
        bucket["messages"].append(r)
        name = r.get("push_name")
        if name and not r.get("from_me"):
            bucket["_name_counts"][name] = bucket["_name_counts"].get(name, 0) + 1
    out: list[dict] = []
    for chat_id, bucket in by_chat.items():
        names = bucket["_name_counts"]
        if names:
            bucket["label"] = max(names.items(), key=lambda kv: kv[1])[0]
        else:
            bucket["label"] = chat_id
        bucket["messages"].sort(key=lambda r: r.get("ts", ""))
        del bucket["_name_counts"]
        out.append(bucket)
    return out


def format_messages(messages: list[dict]) -> str:
    lines: list[str] = []
    for m in messages:
        if m.get("from_me"):
            sender = "eu (Gabriel)"
        else:
            sender = m.get("push_name") or (m.get("sender") or "?")
        ts = (m.get("ts") or "")[:19].replace("T", " ")
        text = (m.get("text") or "").strip().replace("\n", " ")
        mtype = m.get("type") or ""
        if mtype not in ("text", ""):
            text = f"[{mtype}] {text}".strip()
        if not text:
            text = f"[{mtype or 'sem conteúdo'}]"
        lines.append(f"{ts} {sender}: {text}")
    return "\n".join(lines)


def parse_haiku_response(raw: str) -> dict | None:
    text = (raw or "").strip()
    if not text:
        return None
    if text.startswith("```"):
        fence = text.splitlines()
        if len(fence) > 1:
            text = "\n".join(fence[1:])
        if text.endswith("```"):
            text = text[: text.rfind("```")]
        text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if 0 <= start < end:
            try:
                return json.loads(text[start : end + 1])
            except Exception:
                return None
        return None


_usage_totals = {"input_tokens": 0, "output_tokens": 0, "cache_read": 0, "cache_creation": 0, "calls": 0}


async def classify_bucket(client: AsyncAnthropic, bucket: dict) -> dict:
    prompt = HAIKU_PROMPT_TEMPLATE.format(
        label=bucket["label"],
        chat_id=bucket["chat_id"],
        is_group=bucket["is_group"],
        is_group_lit="true" if bucket["is_group"] else "false",
        window=WINDOW_HOURS,
        messages=format_messages(bucket["messages"]),
    )
    empty_proposals = {"facts": [], "tasks": [], "reminders": [], "urgent": []}
    fallback = {
        "chat": bucket["label"],
        "chat_id": bucket["chat_id"],
        "is_group": bucket["is_group"],
        "proposals": empty_proposals,
    }
    last_err: str | None = None
    resp = None
    for attempt in range(RETRY_ATTEMPTS + 1):
        try:
            resp = await asyncio.wait_for(
                client.messages.create(
                    model=HAIKU_MODEL,
                    max_tokens=MAX_TOKENS_OUT,
                    messages=[{"role": "user", "content": prompt}],
                ),
                timeout=PER_CALL_TIMEOUT_S,
            )
            break
        except asyncio.TimeoutError:
            last_err = f"timeout (attempt {attempt + 1})"
        except Exception as e:
            last_err = f"{type(e).__name__}: {str(e)[:160]} (attempt {attempt + 1})"
        if attempt < RETRY_ATTEMPTS:
            await asyncio.sleep(RETRY_BACKOFF_S * (attempt + 1))
    if resp is None:
        fallback["error"] = last_err or "unknown failure"
        return fallback

    usage = getattr(resp, "usage", None)
    if usage is not None:
        _usage_totals["input_tokens"] += getattr(usage, "input_tokens", 0) or 0
        _usage_totals["output_tokens"] += getattr(usage, "output_tokens", 0) or 0
        _usage_totals["cache_read"] += getattr(usage, "cache_read_input_tokens", 0) or 0
        _usage_totals["cache_creation"] += getattr(usage, "cache_creation_input_tokens", 0) or 0
        _usage_totals["calls"] += 1

    text_parts = [b.text for b in resp.content if getattr(b, "type", None) == "text"]
    parsed = parse_haiku_response("".join(text_parts))
    if not isinstance(parsed, dict):
        fallback["error"] = "unparseable response"
        return fallback
    if not isinstance(parsed.get("proposals"), dict):
        parsed["proposals"] = empty_proposals
    for k in ("facts", "tasks", "reminders", "urgent"):
        if not isinstance(parsed["proposals"].get(k), list):
            parsed["proposals"][k] = []
    parsed.setdefault("chat", bucket["label"])
    parsed.setdefault("chat_id", bucket["chat_id"])
    parsed.setdefault("is_group", bucket["is_group"])
    return parsed


def has_proposals(bucket_result: dict) -> bool:
    p = bucket_result.get("proposals") or {}
    return any(p.get(k) for k in ("facts", "tasks", "reminders", "urgent"))


async def main() -> int:
    token = load_oauth_token()
    if not token:
        log("no anthropic OAuth token in auth.json — aborting")
        return 1

    records = read_window()
    buckets = bucket_by_chat(records)
    log(f"window={WINDOW_HOURS}h records={len(records)} buckets={len(buckets)}")

    if not buckets:
        envelope = {
            "window_end_utc": datetime.now(timezone.utc).isoformat(),
            "window_hours": WINDOW_HOURS,
            "buckets_processed": 0,
            "buckets_with_proposals": 0,
            "buckets": [],
        }
        print(json.dumps(envelope, ensure_ascii=False))
        return 0

    client = AsyncAnthropic(
        auth_token=token,
        default_headers={
            "anthropic-beta": OAUTH_BETA,
            "user-agent": CLAUDE_CODE_USER_AGENT,
            "x-app": "cli",
        },
    )

    sem = asyncio.Semaphore(MAX_CONCURRENT)

    async def gated(bucket: dict) -> dict:
        async with sem:
            return await classify_bucket(client, bucket)

    results = await asyncio.gather(*(gated(b) for b in buckets))

    keep = [r for r in results if has_proposals(r)]
    errored = [r for r in results if r.get("error")]
    log(f"results: kept={len(keep)} errored={len(errored)}")
    if errored:
        for r in errored[:5]:
            log(f"  err sample [{r.get('chat','?')[:30]}]: {r.get('error','?')[:120]}")
    u = _usage_totals
    in_cost = u["input_tokens"] * 1.00 / 1_000_000
    out_cost = u["output_tokens"] * 5.00 / 1_000_000
    log(
        f"usage: calls={u['calls']} input={u['input_tokens']} output={u['output_tokens']} "
        f"cache_read={u['cache_read']} cache_creation={u['cache_creation']} "
        f"est_api_cost=${in_cost + out_cost:.4f}"
    )

    now = datetime.now(timezone.utc)
    envelope = {
        "window_start_utc": (now - timedelta(hours=WINDOW_HOURS)).isoformat(),
        "window_end_utc": now.isoformat(),
        "window_hours": WINDOW_HOURS,
        "buckets_processed": len(buckets),
        "buckets_with_proposals": len(keep),
        "buckets_with_errors": len(errored),
        "buckets": keep,
        "errors": [
            {"chat": r.get("chat"), "chat_id": r.get("chat_id"), "error": r.get("error")}
            for r in errored
        ],
    }
    print(json.dumps(envelope, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
