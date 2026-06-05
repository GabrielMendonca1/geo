#!/usr/bin/env python3
"""
whatsapp-extractor.py — self-contained WhatsApp extractor, fully on Gabriel's
Claude Code account (Claude Max OAuth), like the brain-vault Haiku ingest.

Pipeline (no gateway, no Codex, no agent phase):
  1. read the last 6h from ~/.hermes/wa_ingest.jsonl, bucket by chat
  2. CLASSIFY each bucket in parallel with Haiku (model.nano) → proposals
  3. DECIDE with Opus (model.full) — one call, hermes choosing what is genuinely
     worth keeping: dedup, drop noise, emit final {blocks, tasks, urgent}.
     Patient rate-limit-aware retry (Claude Max OAuth throttles Opus).
  4. PERSIST (all file-native, works app-closed): facts → block .md files,
     commitments → Tasks/<UUID>.json task files; only urgent → a Telegram DM.
     Each block weaves [[wikilinks]] + a `Parte de [[MOC — X]]` home from the
     live vault context (geo_context.py) so captures land in the graph.

All inference uses the Claude Max OAuth token from the macOS Keychain
("Claude Code-credentials"), refreshed in place. Register with --no-agent so
the LLM gateway never runs:

    hermes cron edit whatsapp-extractor --no-agent
"""

from __future__ import annotations

import asyncio
import getpass
import importlib.util
import json
import os
import re
import subprocess
import sys
import unicodedata
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
from geo_context import render_brain_context

HERMES_HOME = Path(os.path.expanduser("~/.hermes"))
JSONL_PATH = HERMES_HOME / "wa_ingest.jsonl"
AUTH_PATH = HERMES_HOME / "auth.json"
ENV_PATH = HERMES_HOME / ".env"
CONFIG_PATH = Path(__file__).parent.parent / "config.yaml"

GABRIEL_TELEGRAM_CHAT_ID = "5225262193"


def _config_model(key: str, env_key: str, fallback: str) -> str:
    env = os.environ.get(env_key)
    if env:
        return env
    try:
        import yaml

        data = yaml.safe_load(CONFIG_PATH.read_text()) or {}
        val = (data.get("model") or {}).get(key)
        if val:
            return str(val)
    except Exception:
        pass
    return fallback


def _nano_model() -> str:
    return _config_model("nano", "HERMES_NANO_MODEL", "claude-haiku-4-5")


def _full_model() -> str:
    return _config_model("full", "HERMES_FULL_MODEL", "claude-opus-4-8")


WINDOW_HOURS = int(os.environ.get("HERMES_WA_WINDOW_HOURS", "6"))
HAIKU_MODEL = _nano_model()
MAX_CONCURRENT = 6
PER_CALL_TIMEOUT_S = 45.0
DECIDE_TIMEOUT_S = 120.0
RETRY_ATTEMPTS = 2
RETRY_BACKOFF_S = 1.5
RATE_LIMIT_BACKOFF_S = 15.0
RATE_LIMIT_BACKOFF_MAX_S = 90.0
DECIDE_ATTEMPTS = 5
MAX_TOKENS_OUT = 2000
DECIDE_MAX_TOKENS_OUT = 4000

OAUTH_BETA = "oauth-2025-04-20"
CLAUDE_CODE_USER_AGENT = "claude-cli/2.1.152 (external, cli)"
ANTHROPIC_BASE = "https://api.anthropic.com"
ANTHROPIC_VERSION = "2023-06-01"
CLAUDE_CODE_SYSTEM = "You are Claude Code, Anthropic's official CLI for Claude."


def _headers_oauth(token: str) -> dict:
    return {
        "content-type": "application/json",
        "authorization": f"Bearer {token}",
        "anthropic-version": ANTHROPIC_VERSION,
        "anthropic-beta": OAUTH_BETA,
        "user-agent": CLAUDE_CODE_USER_AGENT,
        "x-app": "cli",
    }

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

DECIDE_PROMPT_TEMPLATE = """Você é o segundo cérebro do Gabriel (hermes). Abaixo estão propostas extraídas de conversas de WhatsApp das últimas {window}h por um classificador rápido. Você é o filtro inteligente: decida o que REALMENTE vale guardar. Dedup, una propostas relacionadas, descarte ruído. Bias: guardar MENOS, com qualidade.

CONTEXTO DO CÉREBRO (vault real do Gabriel, files-are-truth — use para LINKAR e DEDUPLICAR):
{brain_context}

PROPOSTAS (JSON, uma entrada por chat):
{proposals_json}

Como decidir:
- FATO durável sobre pessoa/projeto/decisão/preferência → um bloco. layer "agent" se é fato sólido e auto-evidente; layer "review" se merece o olhar dele antes de virar canônico. Auto-extraído de chat tende a "review".
- COMPROMISSO/algo a fazer → uma task. title curto e acionável, notes com o contexto. Toda task no Geo TEM prazo: due em ISO 8601 UTC (ex: 2026-06-10T13:00:00Z). Sem prazo claro no contexto, escolha uma data-alvo razoável — nunca null.
- URGENTE: alguém esperando ele agora, decisão/deadline batendo → urgent (ele recebe no Telegram).
- Conversa fiada, piada, combinado vago, fofoca, novidade qualquer → descarta.
- DEDUP CONTRA O VAULT: se o CONTEXTO já tem um bloco ou task sobre o mesmo assunto, NÃO recrie — descarta. Só cria se acrescenta algo genuinamente novo.
- Não invente nada fora das propostas. Dúvida = não guarda.

Para cada bloco:
- "title": nota Zettelkasten (substantivo/conceito, não frase).
- "type": fleeting|literature|permanent. "layer": "review" (padrão p/ auto-extraído) ou "agent".
- "body": markdown curto (1 a 3 frases, português) que SEMPRE:
  1) abre com `Parte de [[MOC — X]]` apontando p/ uma MOC REAL da lista de contexto. Sem essa linha a nota vira ilha morta — não emita nenhuma sem ela.
  2) envolve cada pessoa/projeto/conceito saliente em [[wikilinks]]. Linke para títulos REAIS do contexto quando existirem; nunca invente um título de MOC fora da lista.

Retorne JSON estrito (sem markdown, sem prefácio, sem ```):
{{"blocks": [{{"title": "...", "body": "Parte de [[MOC — X]]\\n...com [[wikilinks]]...", "type": "fleeting", "layer": "review"}}], "tasks": [{{"title": "...", "notes": "...", "due": "2026-06-10T13:00:00Z"}}], "urgent": [{{"text": "...", "chat": "..."}}]}}

Se nada vale: retorne as três listas vazias."""


def log(msg: str) -> None:
    print(f"[whatsapp-extractor] {msg}", file=sys.stderr, flush=True)


KEYCHAIN_SERVICE = "Claude Code-credentials"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_ENDPOINTS = (
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
)
TOKEN_EXPIRY_BUFFER_MS = 60_000


def _keychain_read() -> dict | None:
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception as e:
        log(f"keychain lookup failed: {e}")
        return None
    if out.returncode != 0:
        return None
    try:
        full = json.loads(out.stdout.strip())
    except Exception as e:
        log(f"keychain payload unparseable: {e}")
        return None
    return full if isinstance(full.get("claudeAiOauth"), dict) else None


def _keychain_write(full: dict) -> bool:
    try:
        blob = json.dumps(full)
        json.loads(blob)
        w = subprocess.run(
            ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
             "-a", getpass.getuser(), "-w", blob],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if w.returncode != 0:
            log(f"keychain write failed rc={w.returncode}: {w.stderr.strip()[:120]}")
            return False
        return True
    except Exception as e:
        log(f"keychain write error: {e}")
        return False


def _refresh_oauth(refresh_token: str) -> dict | None:
    body = urllib.parse.urlencode(
        {"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": OAUTH_CLIENT_ID}
    ).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded", "User-Agent": CLAUDE_CODE_USER_AGENT}
    for url in OAUTH_TOKEN_ENDPOINTS:
        try:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
            if data.get("access_token"):
                return data
            log(f"refresh at {url}: response had no access_token")
        except Exception as e:
            log(f"refresh at {url} failed: {type(e).__name__}: {str(e)[:120]}")
    return None


def _keychain_oauth_token() -> str | None:
    full = _keychain_read()
    if full is None:
        return None
    oauth = full["claudeAiOauth"]
    access = oauth.get("accessToken")
    exp_ms = oauth.get("expiresAt")
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    if access and (not exp_ms or now_ms < exp_ms - TOKEN_EXPIRY_BUFFER_MS):
        return access
    refresh = oauth.get("refreshToken")
    if not refresh:
        return access
    log("keychain Claude Max OAuth token expired — refreshing via refresh_token")
    refreshed = _refresh_oauth(refresh)
    if not refreshed:
        return access
    oauth["accessToken"] = refreshed["access_token"]
    oauth["refreshToken"] = refreshed.get("refresh_token", refresh)
    oauth["expiresAt"] = now_ms + int(refreshed.get("expires_in", 3600)) * 1000
    if _keychain_write(full):
        log("keychain token refreshed and persisted")
    return oauth["accessToken"]


def _authjson_oauth_token() -> str | None:
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


def load_oauth_token() -> str | None:
    return _keychain_oauth_token() or _authjson_oauth_token()


def _read_env_value(key: str) -> str | None:
    if os.environ.get(key):
        return os.environ[key]
    if not ENV_PATH.exists():
        return None
    try:
        for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            if k.strip() == key:
                return v.strip().strip('"').strip("'")
    except Exception as e:
        log(f".env unreadable: {e}")
    return None


def _is_empty_record(rec: dict) -> bool:
    if rec.get("type") == "unknown" and not (rec.get("text") or "").strip():
        return True
    return False


def _is_one_way_chat(chat: str) -> bool:
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


def parse_json_response(raw: str) -> dict | None:
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


_usage_totals = {"input_tokens": 0, "output_tokens": 0, "calls": 0}


def _track_usage(usage) -> None:
    if not isinstance(usage, dict):
        return
    _usage_totals["input_tokens"] += usage.get("input_tokens", 0) or 0
    _usage_totals["output_tokens"] += usage.get("output_tokens", 0) or 0
    _usage_totals["calls"] += 1


async def _call_model(
    http: httpx.AsyncClient,
    headers: dict,
    model: str,
    prompt: str,
    max_tokens: int,
    timeout_s: float,
    attempts: int = RETRY_ATTEMPTS + 1,
) -> str | None:
    body = {
        "model": model,
        "max_tokens": max_tokens,
        "system": [{"type": "text", "text": CLAUDE_CODE_SYSTEM}],
        "messages": [{"role": "user", "content": prompt}],
    }
    last_err: str | None = None
    for attempt in range(attempts):
        delay = RETRY_BACKOFF_S * (attempt + 1)
        try:
            resp = await http.post(
                f"{ANTHROPIC_BASE}/v1/messages", headers=headers, json=body, timeout=timeout_s
            )
            if resp.status_code == 429:
                last_err = f"RateLimit 429 (attempt {attempt + 1})"
                delay = min(RATE_LIMIT_BACKOFF_S * (2 ** attempt), RATE_LIMIT_BACKOFF_MAX_S)
                try:
                    delay = max(delay, float(resp.headers.get("retry-after", 0)))
                except Exception:
                    pass
            elif resp.status_code >= 400:
                last_err = f"HTTP {resp.status_code}: {resp.text[:160]} (attempt {attempt + 1})"
            else:
                data = resp.json()
                _track_usage(data.get("usage"))
                return "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
        except httpx.TimeoutException:
            last_err = f"timeout (attempt {attempt + 1})"
        except Exception as e:
            last_err = f"{type(e).__name__}: {str(e)[:160]} (attempt {attempt + 1})"
        if attempt < attempts - 1:
            await asyncio.sleep(delay)
    log(f"model call failed ({model}): {last_err}")
    return None


async def classify_bucket(http: httpx.AsyncClient, headers: dict, bucket: dict) -> dict:
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
    raw = await _call_model(http, headers, HAIKU_MODEL, prompt, MAX_TOKENS_OUT, PER_CALL_TIMEOUT_S)
    if raw is None:
        fallback["error"] = "model call failed"
        return fallback
    parsed = parse_json_response(raw)
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


async def decide(http: httpx.AsyncClient, headers: dict, kept: list[dict]) -> dict:
    payload = [
        {"chat": k.get("chat"), "is_group": k.get("is_group"), "proposals": k.get("proposals")}
        for k in kept
    ]
    prompt = DECIDE_PROMPT_TEMPLATE.format(
        window=WINDOW_HOURS,
        proposals_json=json.dumps(payload, ensure_ascii=False, indent=2),
    )
    raw = await _call_model(http, headers, _full_model(), prompt, DECIDE_MAX_TOKENS_OUT, DECIDE_TIMEOUT_S, attempts=DECIDE_ATTEMPTS)
    if raw is None:
        log(f"Opus decide unavailable (rate-limited) — falling back to {HAIKU_MODEL} this run")
        raw = await _call_model(http, headers, HAIKU_MODEL, prompt, DECIDE_MAX_TOKENS_OUT, DECIDE_TIMEOUT_S)
    empty = {"blocks": [], "tasks": [], "urgent": []}
    if raw is None:
        return empty
    parsed = parse_json_response(raw)
    if not isinstance(parsed, dict):
        return empty
    out: dict = {}
    for key in ("blocks", "tasks", "urgent"):
        v = parsed.get(key)
        out[key] = v if isinstance(v, list) else []
    return out


BLOCKS_DIR = Path.home() / "Library" / "Application Support" / "Geo" / "Blocks"
_SANITIZE_RE = re.compile(r'[/:\\*?"<>|]')
_TYPES = ("fleeting", "literature", "permanent", "moc", "project")
_LAYERS = ("user", "agent", "review", "shared")


def _nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s)


def _sanitize_filename(title: str) -> str:
    name = _SANITIZE_RE.sub("-", title or "").replace(" ", "-").strip("-")
    return _nfc(name) or "Block"


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def _unique_path(folder: Path, slug: str) -> Path:
    candidate = folder / f"{slug}.md"
    n = 1
    while candidate.exists():
        candidate = folder / f"{slug}-{n}.md"
        n += 1
    return candidate


def write_block_file(title: str, body: str, type_: str, layer: str) -> str:
    if type_ not in _TYPES:
        type_ = "fleeting"
    if layer not in ("agent", "review", "shared"):
        layer = "review"
    block_id = str(uuid.uuid4()).upper()
    fm = f"---\nid: {block_id}\ntype: {type_}\nlayer: {layer}\n---\n"
    b = body or ""
    if not b.startswith("#"):
        b = f"# {title}\n{b}" if b else f"# {title}\n"
    token = f"[[{datetime.now().strftime('%Y-%m-%d')}]]"
    if token not in b:
        if b and not b.endswith("\n"):
            b += "\n"
        b += token + "\n"
    path = _unique_path(BLOCKS_DIR, _sanitize_filename(title))
    _atomic_write(path, fm + b)
    return _nfc(str(path.relative_to(BLOCKS_DIR)))


async def send_telegram(text: str) -> bool:
    token = _read_env_value("TELEGRAM_BOT_TOKEN")
    if not token:
        log("no TELEGRAM_BOT_TOKEN — cannot send urgent DM")
        return False
    import httpx

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {"chat_id": GABRIEL_TELEGRAM_CHAT_ID, "text": text, "disable_web_page_preview": True}
    try:
        async with httpx.AsyncClient(timeout=15.0) as c:
            resp = await c.post(url, json=payload)
        if resp.status_code != 200:
            log(f"telegram send {resp.status_code}: {resp.text[:200]}")
            return False
        return True
    except Exception as e:
        log(f"telegram send error: {e}")
        return False


async def persist(geo_client, decided: dict) -> tuple[int, int, int]:
    blocks = decided.get("blocks") or []
    tasks = decided.get("tasks") or []
    urgent = decided.get("urgent") or []
    nb = nt = 0

    for b in blocks:
        title = (b.get("title") or "").strip()
        if not title:
            continue
        try:
            rid = write_block_file(title, b.get("body", "") or "", b.get("type") or "fleeting", b.get("layer") or "review")
            nb += 1
            log(f"block: {rid}")
        except Exception as e:
            log(f"block write failed [{title[:40]}]: {e}")

    for t in tasks:
        title = (t.get("title") or "").strip()
        if not title:
            continue
        body: dict = {"kind": "task"}
        if t.get("due"):
            body["due"] = t["due"]
        payload = {"title": title, "body": body}
        if t.get("notes"):
            payload["notes"] = t["notes"]
        posted = False
        if geo_client is not None:
            try:
                await geo_client.post("/tasks", json=payload)
                posted = True
                nt += 1
                log(f"task: {title[:40]}")
            except Exception as e:
                log(f"task post failed [{title[:40]}]: {e}")
        if not posted:
            try:
                fb = f"TODO: {title}"
                if t.get("notes"):
                    fb += f"\n{t['notes']}"
                if t.get("due"):
                    fb += f"\nVence: {t['due']}"
                rid = write_block_file(title, fb, "fleeting", "review")
                nt += 1
                log(f"task→review block (Geo offline): {rid}")
            except Exception as e:
                log(f"task fallback failed [{title[:40]}]: {e}")

    if urgent:
        lines = [f"WhatsApp — urgente (últimas {WINDOW_HOURS}h):"]
        for u in urgent[:10]:
            chat = u.get("chat") or "?"
            txt = (u.get("text") or "").strip()
            if txt:
                lines.append(f"- [{chat}] {txt}")
        if len(lines) > 1:
            await send_telegram("\n".join(lines))

    return nb, nt, len(urgent)


async def main() -> int:
    dry = "--dry-run" in sys.argv
    token = load_oauth_token()
    if not token:
        log("no anthropic OAuth token (Keychain/auth.json) — aborting")
        return 1

    records = read_window()
    buckets = bucket_by_chat(records)
    log(f"window={WINDOW_HOURS}h records={len(records)} buckets={len(buckets)} dry_run={dry}")
    if not buckets:
        print("[whatsapp-extractor] no messages in window")
        return 0

    headers = _headers_oauth(token)
    sem = asyncio.Semaphore(MAX_CONCURRENT)

    async with httpx.AsyncClient() as http:
        async def gated(bucket: dict) -> dict:
            async with sem:
                return await classify_bucket(http, headers, bucket)

        results = await asyncio.gather(*(gated(b) for b in buckets))
        keep = [r for r in results if has_proposals(r)]
        errored = [r for r in results if r.get("error")]
        log(f"classify: with_proposals={len(keep)} errored={len(errored)}")
        if not keep:
            print("[whatsapp-extractor] classifier surfaced nothing")
            return 0

        decided = await decide(http, headers, keep)
    log(
        f"decided: blocks={len(decided.get('blocks', []))} "
        f"tasks={len(decided.get('tasks', []))} urgent={len(decided.get('urgent', []))} "
        f"calls={_usage_totals['calls']} in={_usage_totals['input_tokens']} out={_usage_totals['output_tokens']}"
    )

    if dry:
        print(json.dumps(decided, ensure_ascii=False, indent=2))
        return 0

    geo = None
    geo_client = None
    try:
        geo = load_geo_client()
        geo_client = await geo.GeoAPIClient.get_instance()
    except Exception as e:
        log(f"Geo HTTP unavailable ({e}) — tasks fall back to review blocks")

    try:
        nb, nt, nu = await persist(geo_client, decided)
    finally:
        if geo is not None:
            try:
                await geo.GeoAPIClient.reset_instance()
            except Exception:
                pass

    print(f"[whatsapp-extractor] persisted blocks={nb} tasks={nt} urgent_dm={nu}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
