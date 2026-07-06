#!/usr/bin/env python3
"""
context_scraping.py — self-contained context scraper, fully on Gabriel's
Claude Code account (Claude Max OAuth), like the brain-vault Haiku ingest.

Pipeline (no gateway, no Codex, no agent phase):
  1. read the last 6h from ~/.hermes/wa_ingest.jsonl, bucket by chat
  2. CLASSIFY each bucket in parallel with Haiku (model.nano) → proposals
  3. DECIDE with Sonnet 5 by default (or HERMES_WA_DECIDE_MODEL) — one call,
     hermes choosing what is genuinely worth keeping: dedup, drop noise, emit
     final {blocks, tasks, urgent}.
     Patient rate-limit-aware retry (Claude Max OAuth can throttle included usage).
  4. PERSIST (all file-native, works app-closed): facts → block .md files,
     commitments → Tasks/<UUID>.json task files; only urgent → a Telegram DM.
     Each block weaves [[wikilinks]] + a `Parte de [[MOC — X]]` home from the
     live vault context (geo_context.py) so captures land in the graph.

All inference uses the Claude Max OAuth token from the macOS Keychain
("Claude Code-credentials"), refreshed in place. Register with --no-agent so
the LLM gateway never runs:

    hermes cron edit context-scraping --no-agent
"""

from __future__ import annotations

import asyncio
import getpass
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
STATE_PATH = HERMES_HOME / "context_scraping.state.json"
CHATS_PATH = HERMES_HOME / "context_scraping.chats.json"
TASK_ARCHIVE_DIR = HERMES_HOME / "task_archive"
ARCHIVE_LOG = TASK_ARCHIVE_DIR / "archive_log.jsonl"

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


def _decide_model() -> str:
    # WhatsApp uses the direct Claude OAuth API, not the Claude Code CLI model alias.
    # Keep this job independent from model.full because other standalone scripts
    # (close-day, geo-context) may still want Opus/Haiku defaults.
    return os.environ.get("HERMES_WA_DECIDE_MODEL") or "claude-opus-4-8"


def _decide_effort() -> str:
    return os.environ.get("HERMES_WA_DECIDE_EFFORT") or "xhigh"


# Persisted watermark (STATE_PATH, key last_processed_ts) is the real anti-overlap
# mechanism: read_window() only returns messages newer than it. WINDOW_HOURS is just
# the bootstrap lookback the very first time a chat/state file is seen.
WINDOW_HOURS = int(os.environ.get("HERMES_WA_WINDOW_HOURS", "2"))
HAIKU_MODEL = _nano_model()
MAX_CONCURRENT = 6
PER_CALL_TIMEOUT_S = 45.0
DECIDE_TIMEOUT_S = 300.0
RETRY_ATTEMPTS = 2
RETRY_BACKOFF_S = 1.5
RATE_LIMIT_BACKOFF_S = 15.0
RATE_LIMIT_BACKOFF_MAX_S = 90.0
DECIDE_ATTEMPTS = 5
MAX_TOKENS_OUT = 2000
DECIDE_MAX_TOKENS_OUT = 32000
CHATS_VERSION = 1
SUMMARY_CHAR_CAP = 1500
BOOTSTRAP_MAX_MSGS = 1500
BOOTSTRAP_CHUNK_MSGS = 250
CHAT_PRUNE_DAYS = 90
MAX_TASK_MUTATIONS = 5

MEDIA_DIR = HERMES_HOME / "wa_media"
FFMPEG_BIN = os.environ.get("HERMES_FFMPEG_BIN", "/opt/homebrew/bin/ffmpeg")
WHISPER_BIN = os.environ.get("HERMES_WHISPER_BIN", "/opt/homebrew/bin/whisper-cli")
WHISPER_MODEL = Path(os.path.expanduser(os.environ.get("HERMES_WHISPER_MODEL", "~/.cache/whisper/ggml-large-v3-turbo.bin")))
FFMPEG_TIMEOUT_S = 60
WHISPER_TIMEOUT_S = 300
VISION_IMG_MAX_BYTES = 5_000_000
PDF_MAX_BYTES = 10_000_000
MEDIA_ENRICH_KINDS = {"audio", "image", "document"}
_media_memo: dict[str, str] = {}

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
- FATO sobre pessoa/projeto/decisão/preferência — algo que ainda vai ser verdade mês que vem — inclui decisão tomada na conversa.
- TAREFA: o Gabriel se comprometeu (explícita ou implicitamente) a fazer algo
- LEMBRETE temporal: data específica importa
- URGENTE: alguém esperando ele agora (pergunta direta, deadline batendo)
- PESSOA: fato/mudança de estado sobre pessoa nomeada (fechou negócio, mudou de cidade, pediu algo) — algo que dá continuidade à relação.
- COMBINADO SOCIAL: plano informal com alguém (jantar, café, "bora sexta") — mesmo sem compromisso firme.
- CLIMA (no máx 1, bias forte a VAZIO): só se o Gabriel EXPRESSOU explicitamente como está o dia dele. Uma linha situacional. NUNCA clínico, NUNCA inferido de tom, NUNCA sobre terceiros.

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
    "urgent": [{{"text": "...", "sender": "..."}}],
    "people": [{{"person": "...", "note": "..."}}],
    "social": [{{"person": "...", "plan": "...", "when_hint": "hoje|sexta|YYYY-MM-DD ou null"}}],
    "mood": [{{"note": "..."}}]
  }}
}}

Se nada vale a pena: retorne proposals com todas as listas vazias. Bias: propor MENOS."""

DECIDE_PROMPT_TEMPLATE = """Você é o segundo cérebro do Gabriel (hermes). Abaixo estão propostas extraídas de conversas de WhatsApp das últimas {window}h por um classificador rápido. Você é o filtro inteligente: decida o que REALMENTE vale guardar. Dedup, una propostas relacionadas, descarte ruído. Bias: guardar MENOS, com qualidade.

CONTEXTO DO CÉREBRO (vault real do Gabriel, files-are-truth — use para LINKAR e DEDUPLICAR):
{brain_context}

CONTEXTO DAS CONVERSAS (resumo vivo por chat ativo neste ciclo — use para entender o QUE já vinha acontecendo, não é proposta):
{chat_summaries}

TASKS EXISTENTES NO GEO (cada uma com seu id — para criar/dedup E para o CICLO DE VIDA abaixo):
{tasks_context}

PROPOSTAS (JSON, uma entrada por chat):
{proposals_json}

Como decidir:
- FATO durável sobre pessoa/projeto/decisão/preferência → um bloco. layer "agent" se é fato sólido e auto-evidente; layer "review" se merece o olhar dele antes de virar canônico. Auto-extraído de chat tende a "review".
- COMPROMISSO/algo a fazer → uma task. title curto e acionável; tasks não carregam prosa — contexto durável vira bloco. PRAZO (due): NÃO invente horário. Se a conversa dá dia E hora explícitos → due em hora LOCAL naive, SEM 'Z' (ex: 2026-06-22T13:00:00) — NÃO converta pra UTC, o código faz isso. Se dá só o dia, ou nenhum horário → due como SÓ DATA (ex: 2026-06-22), sem hora — o sistema põe no fim daquele dia. Sem prazo claro no contexto → use a data de hoje ou um dia desta semana. NUNCA data no passado, NUNCA horário aleatório.
- URGENTE: alguém esperando ele agora, decisão/deadline batendo → urgent (ele recebe no Telegram).
- Conversa fiada, piada, combinado vago, fofoca, novidade qualquer → descarta.
- SINAL: só vira bloco ou task se tiver conteúdo acionável ou memorável de verdade. "Bom dia", reação, emoji solto, "tudo bem?", combinado que já era óbvio → sem sinal, descarta (não é bloco nem task).
- DEDUP CONTRA O VAULT: se o CONTEXTO já tem um bloco ou task sobre o mesmo assunto, NÃO recrie — descarta. Só cria se acrescenta algo genuinamente novo.
- DEDUP CONTRA TASKS EXISTENTES: se uma TASK EXISTENTE (ativa OU concluída recente) já cobre o mesmo compromisso, NÃO recrie a task — descarta. Algo já concluído só vira task nova se for claramente um novo ciclo/pedido.
- PESSOA: fato durável sobre pessoa nomeada → people[]. target_block = título EXATO da lista "Blocos existentes" se a pessoa já tem bloco; senão null (código cria bloco novo review). note curta, 1 frase.
- COMBINADO SOCIAL informal → digest.social (uma linha leve). NUNCA vira task. SÓ vira task se o Gabriel se comprometeu EXPLICITAMENTE a executar algo acionável com dia definido — aí segue o caminho normal de tasks.
- CLIMA → digest.clima, UMA linha neutra sobre o DIA do Gabriel, ou null. Na dúvida, null. PROIBIDO: rastrear humor, pontuar sentimento, clima por pessoa. Não existe campo de humor por pessoa — é estrutural.
- Não duplique em digest.social/people algo que já virou task ou já existe no CONTEXTO.
- Não invente nada fora das propostas. Dúvida = não guarda.
- CICLO DE VIDA DE TASKS EXISTENTES — só com evidência EXPLÍCITA na conversa (dúvida = não mexe):
  - Se o contexto/resumo mostra que uma task ATIVA já foi FEITA → task_updates com action "complete" e o id EXATO dela.
  - Se uma task ATIVA foi claramente CANCELADA, virou obsoleta, ou é DUPLICATA de outra → action "delete" com o id EXATO.
  - Use SOMENTE ids que aparecem na lista de TASKS EXISTENTES. NUNCA invente id. NUNCA reabra uma task concluída. No máximo poucas mutações por ciclo — só as inequívocas.
  - "reason" curta em português citando a evidência da conversa.

Para cada bloco:
- "title": o ASSUNTO real da conversa, em português com acentos, ≤60 caracteres, substantivo/conceito específico (Zettelkasten) — nunca uma frase genérica e nunca só uma data.
  PROIBIDO: "Resumo WhatsApp", "Conversa com {{nome}}", título repetindo prefixo óbvio tipo "WhatsApp —", ou qualquer título que não diga do que se trata.
  BOM: "Prazo do SPEC da Marqserv adiado pra sexta", "Antonio pede ajuste no QR PIX do GT Coach".
  RUIM: "Resumo WhatsApp — Antonio", "Conversa 2026-07-04", "Atualização do grupo".
- "type": fleeting|literature|permanent. "layer": "review" (padrão p/ auto-extraído) ou "agent".
- "body": markdown curto (1 a 3 frases, português) que SEMPRE:
  1) abre com `Parte de [[MOC — X]]` apontando p/ uma MOC REAL da lista de contexto. Sem essa linha a nota vira ilha morta — não emita nenhuma sem ela.
  2) envolve cada pessoa/projeto/conceito saliente em [[wikilinks]]. Linke para títulos REAIS do contexto quando existirem; nunca invente um título de MOC fora da lista.

Retorne JSON estrito (sem markdown, sem prefácio, sem ```):
{{"blocks": [{{"title": "...", "body": "Parte de [[MOC — X]]\\n...com [[wikilinks]]...", "type": "fleeting", "layer": "review"}}], "tasks": [{{"title": "...", "due": "2026-06-22"}}], "urgent": [{{"text": "...", "chat": "..."}}], "people": [{{"target_block": "Antônio Gili ou null", "person": "Antônio", "note": "...", "moc": "MOC — Pessoal"}}], "digest": {{"clima": "linha leve única ou null", "social": ["jantar sexta com [[Bernardo Biglia]]"]}}, "task_updates": [{{"id": "ABC-123...", "action": "complete", "reason": "Antonio confirmou que o QR PIX já está no ar"}}]}}

Se nada vale: retorne as listas vazias."""


SUMMARY_UPDATE_PROMPT_TEMPLATE = """Você mantém um RESUMO VIVO desta conversa — o estado durável da relação, não um log.

Chat: {label} (group={is_group}, jid={chat_id})

RESUMO ANTERIOR:
{prev_summary}

MENSAGENS NOVAS (cronológicas):
{new_messages}

Funda o resumo anterior com as mensagens novas. Preserve fatos, compromissos e o estado da relação ainda vigentes; descarte conversa fiada. Foque no que está em aberto, no que foi combinado, quem espera o quê, e decisões tomadas. Português corrido, sem markdown, no máximo ~1200 caracteres.

Retorne JSON estrito (sem markdown, sem prefácio, sem ```):
{{"summary": "..."}}"""


SUMMARY_BOOTSTRAP_CHUNK_PROMPT_TEMPLATE = """Você resume um trecho de conversa de WhatsApp, guardando só o estado durável.

Chat: {label} (group={is_group}, jid={chat_id})

MENSAGENS (cronológicas):
{messages}

Resuma este trecho em no máximo ~600 caracteres, só o durável: fatos, compromissos, combinados, decisões. Português corrido, sem markdown.

Retorne JSON estrito (sem markdown, sem prefácio, sem ```):
{{"summary": "..."}}"""


def log(msg: str) -> None:
    print(f"[context-scraping] {msg}", file=sys.stderr, flush=True)


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


def load_state() -> dict:
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state: dict) -> None:
    try:
        _atomic_write(STATE_PATH, json.dumps(state, ensure_ascii=False))
    except Exception as e:
        log(f"state save failed: {e}")


def _advance_watermark(state: dict, records: list[dict]) -> None:
    ts_values = [r.get("ts") for r in records if r.get("ts")]
    if not ts_values:
        return
    new_ts = max(ts_values)
    last_ts = state.get("last_processed_ts") or ""
    if new_ts > last_ts:
        state["last_processed_ts"] = new_ts
        state["boundary_msg_ids"] = [r.get("msg_id") for r in records if r.get("ts") == new_ts and r.get("msg_id")]
        state["last_run_at"] = _now_z()
        save_state(state)
    elif new_ts == last_ts:
        existing = list(state.get("boundary_msg_ids") or [])
        new_ids = [r.get("msg_id") for r in records if r.get("ts") == new_ts and r.get("msg_id")]
        state["boundary_msg_ids"] = existing + [i for i in new_ids if i not in existing]
        state["last_run_at"] = _now_z()
        save_state(state)


def read_window(watermark: str | None, boundary_msg_ids: list[str] | None = None) -> list[dict]:
    if not JSONL_PATH.exists():
        return []
    wm_dt = None
    if watermark:
        try:
            wm_dt = datetime.fromisoformat(watermark.replace("Z", "+00:00"))
        except Exception:
            wm_dt = None
    boundary_ids = set(boundary_msg_ids or [])
    fallback_cutoff = datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)
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
            if wm_dt is not None:
                if ts < wm_dt:
                    continue
                if ts == wm_dt and rec.get("msg_id") in boundary_ids:
                    continue
            elif ts < fallback_cutoff:
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


def _transcribe_audio(path: Path) -> str:
    wav = path.with_suffix(".enrich.wav")
    base = str(wav.with_suffix(""))
    try:
        subprocess.run(
            [FFMPEG_BIN, "-y", "-i", str(path), "-ar", "16000", "-ac", "1", "-f", "wav", str(wav)],
            capture_output=True, timeout=FFMPEG_TIMEOUT_S,
        )
        if not wav.exists():
            return ""
        subprocess.run(
            [WHISPER_BIN, "-m", str(WHISPER_MODEL), "-f", str(wav), "-l", "pt", "-nt", "-otxt", "-of", base],
            capture_output=True, timeout=WHISPER_TIMEOUT_S,
        )
        out = Path(base + ".txt")
        return out.read_text(errors="replace").strip() if out.exists() else ""
    finally:
        for f in (wav, Path(base + ".txt")):
            try:
                f.unlink()
            except Exception:
                pass


async def _vision_describe(http, headers: dict, path: Path, mime: str, caption: str | None) -> str:
    import base64

    b64 = base64.b64encode(path.read_bytes()).decode("ascii")
    blocks = [
        {"type": "image", "source": {"type": "base64", "media_type": mime or "image/jpeg", "data": b64}},
        {"type": "text", "text": f"Descreva esta imagem em 1 frase curta em português. Legenda do usuário (contexto): {caption or '(nenhuma)'}. Só a descrição, sem preâmbulo."},
    ]
    out = await _call_model(
        http, headers, HAIKU_MODEL, "", MAX_TOKENS_OUT, PER_CALL_TIMEOUT_S, content_blocks=blocks
    )
    return (out or "").strip()[:200]


async def _pdf_gist(http, headers: dict, path: Path, caption: str | None) -> str:
    import base64

    b64 = base64.b64encode(path.read_bytes()).decode("ascii")
    blocks = [
        {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": b64}},
        {"type": "text", "text": f"Resuma o conteúdo deste PDF em 1-2 frases em português (gist). Legenda: {caption or '(nenhuma)'}."},
    ]
    out = await _call_model(
        http, headers, HAIKU_MODEL, "", MAX_TOKENS_OUT, PER_CALL_TIMEOUT_S, content_blocks=blocks
    )
    return (out or "").strip()[:300]


async def enrich_media_one(record: dict, http, headers: dict) -> str:
    media = record.get("media") or {}
    path = media.get("path")
    mime = (media.get("mime") or "").lower()
    kind = record.get("type")
    if not path or kind not in MEDIA_ENRICH_KINDS:
        return ""
    if path in _media_memo:
        return _media_memo[path]
    sidecar = Path(path + ".txt")
    if sidecar.exists():
        txt = sidecar.read_text(errors="replace").strip()
        _media_memo[path] = txt
        return txt
    p = Path(path)
    if not p.exists():
        return ""
    result = ""
    cacheable = False
    try:
        if kind == "audio":
            transcript = _transcribe_audio(p)
            if transcript:
                result = f"[áudio transcrito] {transcript}"
                cacheable = True
        elif kind == "image":
            if p.stat().st_size <= VISION_IMG_MAX_BYTES:
                desc = await _vision_describe(http, headers, p, mime, record.get("text"))
                if desc:
                    result = f"[imagem: {desc}]"
                    cacheable = True
            else:
                result = "[imagem: grande demais p/ análise]"
                cacheable = True
        elif kind == "document":
            if mime == "application/pdf" and p.stat().st_size <= PDF_MAX_BYTES:
                gist = await _pdf_gist(http, headers, p, record.get("text"))
                if gist:
                    result = f"[documento PDF: {gist}]"
                    cacheable = True
            else:
                fn = media.get("filename") or p.name
                result = f"[arquivo: {fn} ({mime or 'desconhecido'})]"
                cacheable = True
    except Exception as e:
        log(f"enrich_media failed [{p.name}]: {e}")
        result = ""
        cacheable = False
    if cacheable:
        try:
            _atomic_write(sidecar, result)
        except Exception:
            pass
        _media_memo[path] = result
        return result
    _media_memo[path] = ""
    return ""


async def enrich_window_media(records: list[dict], http, headers: dict) -> None:
    media_recs = [r for r in records if r.get("media") and r.get("type") in MEDIA_ENRICH_KINDS]
    if not media_recs:
        return

    async def one(r: dict) -> None:
        try:
            r["_media_text"] = await enrich_media_one(r, http, headers)
        except Exception as e:
            log(f"enrich_window_media task failed: {e}")
            r["_media_text"] = ""

    await asyncio.gather(*(one(r) for r in media_recs))


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
        enriched = m.get("_media_text")
        if enriched:
            text = f"{enriched} {text}".strip() if text else enriched
        elif mtype not in ("text", ""):
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
    effort: str | None = None,
    adaptive_thinking: bool = False,
    content_blocks: list | None = None,
) -> str | None:
    body = {
        "model": model,
        "max_tokens": max_tokens,
        "system": [{"type": "text", "text": CLAUDE_CODE_SYSTEM}],
        "messages": [{"role": "user", "content": content_blocks if content_blocks is not None else prompt}],
    }
    if effort:
        body["output_config"] = {"effort": effort}
    if adaptive_thinking:
        body["thinking"] = {"type": "adaptive"}
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
    empty_proposals = {"facts": [], "tasks": [], "reminders": [], "urgent": [], "people": [], "social": [], "mood": []}
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
    for k in ("facts", "tasks", "reminders", "urgent", "people", "social", "mood"):
        if not isinstance(parsed["proposals"].get(k), list):
            parsed["proposals"][k] = []
    parsed.setdefault("chat", bucket["label"])
    parsed.setdefault("chat_id", bucket["chat_id"])
    parsed.setdefault("is_group", bucket["is_group"])
    return parsed


def has_proposals(bucket_result: dict) -> bool:
    p = bucket_result.get("proposals") or {}
    return any(p.get(k) for k in ("facts", "tasks", "reminders", "urgent", "people", "social", "mood"))


def load_chats() -> dict:
    try:
        data = json.loads(CHATS_PATH.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("chats"), dict):
            return data
    except Exception:
        pass
    return {"version": CHATS_VERSION, "chats": {}}


def save_chats(store: dict) -> None:
    try:
        chats = store.get("chats")
        if isinstance(chats, dict):
            cutoff = (datetime.now(timezone.utc) - timedelta(days=CHAT_PRUNE_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
            for cid in list(chats.keys()):
                entry = chats.get(cid) or {}
                last = entry.get("last_msg_ts") or ""
                if last and last < cutoff:
                    del chats[cid]
        store["version"] = CHATS_VERSION
        _atomic_write(CHATS_PATH, json.dumps(store, ensure_ascii=False))
    except Exception as e:
        log(f"chats save failed: {e}")


def read_full_history(chat_ids: set[str]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {c: [] for c in chat_ids}
    if not JSONL_PATH.exists() or not chat_ids:
        return out
    with JSONL_PATH.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            chat = rec.get("chat") or ""
            if chat not in out:
                continue
            if _is_empty_record(rec) or _is_one_way_chat(chat):
                continue
            out[chat].append(rec)
    for c in out:
        out[c].sort(key=lambda r: r.get("ts", ""))
        out[c] = out[c][-BOOTSTRAP_MAX_MSGS:]
    return out


async def bootstrap_summary(http: httpx.AsyncClient, headers: dict, sem: asyncio.Semaphore, label: str, chat_id: str, is_group: bool, msgs: list[dict]) -> str | None:
    if not msgs:
        return ""
    chunks = [msgs[i:i + BOOTSTRAP_CHUNK_MSGS] for i in range(0, len(msgs), BOOTSTRAP_CHUNK_MSGS)]

    async def one(chunk: list[dict]) -> str:
        async with sem:
            raw = await _call_model(
                http, headers, HAIKU_MODEL,
                SUMMARY_BOOTSTRAP_CHUNK_PROMPT_TEMPLATE.format(
                    label=label, chat_id=chat_id, is_group=is_group, messages=format_messages(chunk)),
                MAX_TOKENS_OUT, PER_CALL_TIMEOUT_S,
            )
        p = parse_json_response(raw) or {}
        return _as_text(p.get("summary")).strip()

    partials = [s for s in await asyncio.gather(*(one(c) for c in chunks)) if s]
    if not partials:
        return None
    if len(partials) == 1:
        return partials[0][:SUMMARY_CHAR_CAP]
    async with sem:
        raw = await _call_model(
            http, headers, HAIKU_MODEL,
            SUMMARY_UPDATE_PROMPT_TEMPLATE.format(
                label=label, chat_id=chat_id, is_group=is_group,
                prev_summary="\n---\n".join(partials), new_messages="(sem novas)"),
            MAX_TOKENS_OUT, PER_CALL_TIMEOUT_S,
        )
    p = parse_json_response(raw) or {}
    s = _as_text(p.get("summary")).strip()
    return s[:SUMMARY_CHAR_CAP] if s else "\n".join(partials)[:SUMMARY_CHAR_CAP]


async def update_chat_summaries(http: httpx.AsyncClient, headers: dict, sem: asyncio.Semaphore, buckets: list[dict], store: dict) -> tuple[str, bool]:
    chats = store.setdefault("chats", {})
    ok = True
    new_ids = {b["chat_id"] for b in buckets if b["chat_id"] not in chats}
    hist = read_full_history(new_ids) if new_ids else {}

    async def handle(b: dict) -> None:
        nonlocal ok
        cid = b["chat_id"]
        entry = chats.get(cid)
        try:
            if entry is None:
                msgs = hist.get(cid) or b["messages"]
                s = await bootstrap_summary(http, headers, sem, b["label"], cid, b["is_group"], msgs)
                if s is None:
                    ok = False
                    return
                last_ts = max((m.get("ts") or "" for m in msgs), default="")
                chats[cid] = {
                    "label": b["label"],
                    "is_group": b["is_group"],
                    "summary": s,
                    "last_msg_ts": last_ts,
                    "last_updated_at": _now_z(),
                    "msg_count": len(msgs),
                }
            else:
                last_seen = entry.get("last_msg_ts") or ""
                delta = [m for m in b["messages"] if (m.get("ts") or "") > last_seen]
                if not delta:
                    entry["label"] = b["label"]
                    return
                async with sem:
                    raw = await _call_model(
                        http, headers, HAIKU_MODEL,
                        SUMMARY_UPDATE_PROMPT_TEMPLATE.format(
                            label=b["label"], chat_id=cid, is_group=b["is_group"],
                            prev_summary=entry.get("summary", ""), new_messages=format_messages(delta)),
                        MAX_TOKENS_OUT, PER_CALL_TIMEOUT_S,
                    )
                p = parse_json_response(raw) or {}
                s = _as_text(p.get("summary")).strip()
                if not s:
                    ok = False
                    return
                entry.update(
                    summary=s[:SUMMARY_CHAR_CAP],
                    label=b["label"],
                    is_group=b["is_group"],
                    last_msg_ts=max((m.get("ts") or "" for m in delta), default=last_seen),
                    last_updated_at=_now_z(),
                    msg_count=entry.get("msg_count", 0) + len(delta),
                )
        except Exception as e:
            log(f"summary update failed [{b['label'][:30]}]: {e}")
            ok = False

    await asyncio.gather(*(handle(b) for b in buckets))
    lines: list[str] = []
    for b in buckets:
        e = chats.get(b["chat_id"])
        if e and e.get("summary"):
            lines.append(f"### {e['label']} (jid={b['chat_id']})\n{e['summary']}")
    ctx = "\n\n".join(lines) or "(sem resumos de contexto)"
    return ctx, ok


async def decide(http: httpx.AsyncClient, headers: dict, kept: list[dict], brain_context: str, chat_summaries: str, tasks_context: str) -> tuple[dict, bool]:
    payload = [
        {"chat": k.get("chat"), "is_group": k.get("is_group"), "proposals": k.get("proposals")}
        for k in kept
    ]
    prompt = DECIDE_PROMPT_TEMPLATE.format(
        window=WINDOW_HOURS,
        brain_context=brain_context,
        chat_summaries=chat_summaries,
        tasks_context=tasks_context,
        proposals_json=json.dumps(payload, ensure_ascii=False, indent=2),
    )
    decide_model = _decide_model()
    raw = await _call_model(
        http, headers, decide_model, prompt, DECIDE_MAX_TOKENS_OUT, DECIDE_TIMEOUT_S,
        attempts=DECIDE_ATTEMPTS, effort=_decide_effort(), adaptive_thinking=True,
    )
    if raw is None:
        log(f"{decide_model} decide unavailable — falling back to {HAIKU_MODEL} this run")
        raw = await _call_model(http, headers, HAIKU_MODEL, prompt, DECIDE_MAX_TOKENS_OUT, DECIDE_TIMEOUT_S)
    empty = {"blocks": [], "tasks": [], "urgent": [], "people": [], "digest": {}, "task_updates": []}
    if raw is None:
        return empty, False
    parsed = parse_json_response(raw)
    if not isinstance(parsed, dict):
        return empty, False
    out: dict = {}
    for key in ("blocks", "tasks", "urgent"):
        v = parsed.get(key)
        out[key] = v if isinstance(v, list) else []
    people = parsed.get("people")
    out["people"] = people if isinstance(people, list) else []
    digest = parsed.get("digest")
    out["digest"] = digest if isinstance(digest, dict) else {}
    task_updates = parsed.get("task_updates")
    out["task_updates"] = task_updates if isinstance(task_updates, list) else []
    return out, True


BLOCKS_DIR = Path.home() / "GeoVault" / "Blocks"
_SANITIZE_RE = re.compile(r'[/:\\*?"<>|]')
_TYPES = ("fleeting", "literature", "permanent", "moc", "project")
_LAYERS = ("user", "agent", "review", "shared")
_GENERIC_TITLE_RE = re.compile(
    r"^(resumo|conversa|update|atualiza[cç][aã]o|novidades?)\b", re.IGNORECASE
)
_DATE_ONLY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _is_generic_title(title: str) -> bool:
    t = (title or "").strip()
    if not t:
        return True
    if _DATE_ONLY_RE.fullmatch(t):
        return True
    if _GENERIC_TITLE_RE.match(t):
        return True
    return False


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


CONT_CAP = 8


def _read_layer(text: str) -> str | None:
    m = re.search(r"^layer:\s*(\S+)", text or "", re.MULTILINE)
    return _nfc(m.group(1)) if m else None


def _fenced_lines(text: str, name: str) -> list[str]:
    open_t, close_t = f"<!-- geo:{name} -->", f"<!-- /geo:{name} -->"
    if open_t not in text or close_t not in text:
        return []
    inner = text[text.index(open_t) + len(open_t):text.index(close_t)]
    return [ln for ln in (l.strip() for l in inner.splitlines()) if ln]


def _replace_fenced(text: str, name: str, inner_lines: list[str], heading: str | None = None) -> str:
    open_t, close_t = f"<!-- geo:{name} -->", f"<!-- /geo:{name} -->"
    block = open_t + "\n" + "\n".join(inner_lines) + "\n" + close_t
    if open_t in text and close_t in text:
        return text[:text.index(open_t)] + block + text[text.index(close_t) + len(close_t):]
    section = (f"\n## {heading}\n" if heading else "\n") + block + "\n"
    return text.rstrip("\n") + "\n" + section


def _norm(s: str) -> str:
    s = _nfc(s or "").strip()
    s = re.sub(r"^[§\-\s]*", "", s)
    s = re.sub(r"^\d{4}-\d{2}-\d{2}\s*(?:—|-)?\s*", "", s)
    s = re.sub(r"\s+", " ", s)
    return s.lower().strip()


def _find_person_block(title: str) -> Path | None:
    t = _nfc((title or "").strip())
    if not t:
        return None
    for name in (t + ".md", _sanitize_filename(t) + ".md"):
        p = BLOCKS_DIR / name
        if p.exists():
            return p
    return None


def append_person_continuity(target_block: str | None, person: str, note: str, moc: str, date_iso: str) -> str:
    note = (note or "").strip()
    if not note:
        return "skip"
    path = _find_person_block(target_block) if target_block else None
    if path is not None and _read_layer(path.read_text(encoding="utf-8")) == "user":
        path = None
    if path is None:
        body = (f"Parte de [[{moc or 'MOC — Pessoal'}]]\n\n"
                f"## Continuidade (recente)\n"
                f"<!-- geo:cont -->\n§ {date_iso} — {note}\n<!-- /geo:cont -->")
        return write_block_file(person or target_block or note[:50], body, "fleeting", "review")
    text = path.read_text(encoding="utf-8")
    lines = _fenced_lines(text, "cont")
    if any(_norm(note) == _norm(l) for l in lines):
        return "dup"
    lines.append(f"§ {date_iso} — {note}")
    lines = lines[-CONT_CAP:]
    text = _replace_fenced(text, "cont", lines, heading="Continuidade (recente)")
    token = f"[[{date_iso}]]"
    if token not in text:
        text = text.rstrip("\n") + "\n" + token + "\n"
    _atomic_write(path, text)
    return _nfc(str(path.relative_to(BLOCKS_DIR)))


def upsert_daily_digest(date_iso: str, clima: str | None, people_lines: list[str], social_lines: list[str]) -> str:
    path = BLOCKS_DIR / f"Contexto do dia {date_iso}.md"
    if path.exists():
        text = path.read_text(encoding="utf-8")
    else:
        bid = str(uuid.uuid4()).upper()
        text = (f"---\nid: {bid}\ntype: fleeting\nlayer: review\n---\n"
                f"# Contexto do dia {date_iso}\nParte de [[MOC — Rotina]]\n\n"
                f"## Clima\n<!-- geo:clima -->\n<!-- /geo:clima -->\n\n"
                f"## Combinados\n<!-- geo:social -->\n<!-- /geo:social -->\n\n"
                f"## Pessoas\n<!-- geo:pessoas -->\n<!-- /geo:pessoas -->\n\n[[{date_iso}]]\n")
    if clima:
        text = _replace_fenced(text, "clima", [clima.strip()], heading="Clima")
    for name, heading, new in (("social", "Combinados", social_lines), ("pessoas", "Pessoas", people_lines)):
        cur = _fenced_lines(text, name)
        for ln in new:
            ln = ("- " + ln.strip().lstrip("- ")).rstrip()
            if ln.strip("- ").strip() and not any(_norm(ln) == _norm(c) for c in cur):
                cur.append(ln)
        text = _replace_fenced(text, name, cur, heading=heading)
    _atomic_write(path, text)
    return path.name


TASKS_DIR = Path.home() / "GeoVault" / "Tasks"


def _now_z() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _local_tz():
    return datetime.now(timezone.utc).astimezone().tzinfo


def _end_of_day_local(year: int, month: int, day: int) -> datetime:
    return datetime(year, month, day, 23, 59, tzinfo=_local_tz())


def _resolve_due(due) -> str:
    tz = _local_tz()
    now_local = datetime.now(tz)
    dt = None
    if isinstance(due, str) and due.strip():
        s = due.strip()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
            try:
                d = datetime.strptime(s, "%Y-%m-%d")
                dt = _end_of_day_local(d.year, d.month, d.day)
            except Exception:
                dt = None
        else:
            try:
                p = datetime.fromisoformat(s.replace("Z", "+00:00"))
                if (p.hour == 0 and p.minute == 0) or (p.hour == 23 and p.minute == 59):
                    dt = _end_of_day_local(p.year, p.month, p.day)
                else:
                    if p.tzinfo is None:
                        p = p.replace(tzinfo=tz)
                    dt = p.astimezone(tz)
            except Exception:
                dt = None
    if dt is None:
        dt = _end_of_day_local(now_local.year, now_local.month, now_local.day)
    if dt < now_local:
        dt = _end_of_day_local(now_local.year, now_local.month, now_local.day)
        if dt < now_local:
            dt = dt + timedelta(days=1)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _as_text(v) -> str:
    if isinstance(v, str):
        return v
    if isinstance(v, list):
        return "\n".join(_as_text(x) for x in v)
    if v is None:
        return ""
    return str(v)


def write_task_file(title: str, due) -> str:
    task_id = str(uuid.uuid4()).upper()
    now = _now_z()
    due_z = _resolve_due(due)
    task = {
        "id": task_id,
        "title": _as_text(title),
        "body": {"kind": "task", "due": due_z},
        "isAllDay": due_z.endswith(("23:59:00Z", "02:59:00Z")),
        "status": "pending",
        "priority": "unset",
        "tagIds": [],
        "orderIndex": 0,
        "reminders": [],
        "createdAt": now,
        "modifiedAt": now,
    }
    _atomic_write(TASKS_DIR / f"{task_id}.json", json.dumps(task, ensure_ascii=False))
    return f"{task_id}.json"


def _recent_tasks_context(completed_days: int = 14) -> str:
    cutoff = datetime.now(timezone.utc) - timedelta(days=completed_days)
    active: list[str] = []
    done: list[str] = []
    for f in sorted(TASKS_DIR.glob("*.json")):
        try:
            t = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        title = _as_text(t.get("title")).strip()
        if not title:
            continue
        tid = _as_text(t.get("id")).strip()
        if not tid:
            continue
        if t.get("status") == "completed":
            try:
                mod = datetime.fromisoformat((t.get("modifiedAt") or "").replace("Z", "+00:00"))
            except Exception:
                mod = None
            if mod is not None and mod >= cutoff:
                done.append(f"[{tid}] {title}")
        else:
            due = (t.get("body") or {}).get("due") or ""
            active.append(f"[{tid}] {title} (due {due})" if due else f"[{tid}] {title}")
    if not active and not done:
        return "(nenhuma task ativa ou concluída recente)"
    lines: list[str] = []
    if active:
        lines.append("ATIVAS (pendentes):")
        lines.extend(f"- {a}" for a in active)
    if done:
        lines.append(f"CONCLUÍDAS nos últimos {completed_days}d:")
        lines.extend(f"- {d}" for d in done)
    return "\n".join(lines)


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


def apply_task_updates(updates: list[dict], dry: bool) -> list[dict]:
    applied: list[dict] = []
    count = 0
    for u in (updates or []):
        if count >= MAX_TASK_MUTATIONS:
            log(f"task mutation cap {MAX_TASK_MUTATIONS} reached — skipping rest")
            break
        if not isinstance(u, dict):
            continue
        tid = _as_text(u.get("id")).strip()
        action = _as_text(u.get("action")).strip().lower()
        reason = _as_text(u.get("reason")).strip()
        if not tid or action not in ("complete", "delete"):
            log(f"task_update skipped (bad id/action): {u}")
            continue
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", tid):
            log(f"task_update skipped (malformed id): {tid}")
            continue
        path = TASKS_DIR / f"{tid}.json"
        if not path.exists():
            log(f"task_update {action} skipped — id not found: {tid}")
            continue
        try:
            task = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:
            log(f"task_update {action} unreadable {tid}: {e}")
            continue
        status = task.get("status")
        if action == "complete":
            if status == "completed":
                log(f"task_update complete skipped — already completed: {tid}")
                continue
            task["status"] = "completed"
            task["modifiedAt"] = _now_z()
            if not dry:
                _atomic_write(path, json.dumps(task, ensure_ascii=False))
            log(f"{'[dry] ' if dry else ''}task complete {tid}: {reason}")
        else:
            if not dry:
                TASK_ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
                stamp = _now_z().replace(":", "").replace("-", "")
                os.replace(path, TASK_ARCHIVE_DIR / f"{tid}.{stamp}.json")
                with ARCHIVE_LOG.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps({
                        "ts": _now_z(), "id": tid, "action": "delete",
                        "reason": reason, "title": _as_text(task.get("title")),
                    }, ensure_ascii=False) + "\n")
            log(f"{'[dry] ' if dry else ''}task delete/archive {tid}: {reason}")
        applied.append({"id": tid, "action": action, "reason": reason})
        count += 1
    return applied


async def persist(decided: dict) -> tuple[int, int, int, int]:
    blocks = decided.get("blocks") or []
    tasks = decided.get("tasks") or []
    urgent = decided.get("urgent") or []
    nb = nt = 0

    for b in blocks:
        title = _as_text(b.get("title")).strip()
        if not title:
            continue
        if _is_generic_title(title):
            log(f"block discarded (generic title): {title[:60]!r}")
            continue
        try:
            rid = write_block_file(title, _as_text(b.get("body")), b.get("type") or "fleeting", b.get("layer") or "review")
            nb += 1
            log(f"block: {rid}")
        except Exception as e:
            log(f"block write failed [{title[:40]}]: {e}")

    for t in tasks:
        title = _as_text(t.get("title")).strip()
        if not title:
            continue
        try:
            rid = write_task_file(title, t.get("due"))
            nt += 1
            log(f"task: {rid} [{title[:40]}]")
        except Exception as e:
            log(f"task write failed [{title[:40]}]: {e}")

    if urgent:
        lines = [f"WhatsApp — urgente (últimas {WINDOW_HOURS}h):"]
        for u in urgent[:10]:
            chat = _as_text(u.get("chat")) or "?"
            txt = _as_text(u.get("text")).strip()
            if txt:
                lines.append(f"- [{chat}] {txt}")
        if len(lines) > 1:
            await send_telegram("\n".join(lines))

    date_iso = datetime.now().strftime("%Y-%m-%d")
    people_lines: list[str] = []
    for p in decided.get("people") or []:
        if not isinstance(p, dict):
            continue
        note = _as_text(p.get("note")).strip()
        if not note:
            continue
        tgt = _as_text(p.get("target_block")).strip() or None
        moc = _as_text(p.get("moc")).strip() or "MOC — Pessoal"
        person = _as_text(p.get("person")).strip()
        try:
            res = append_person_continuity(tgt, person, note, moc, date_iso)
            log(f"person: {res}")
            people_lines.append(f"[[{person or tgt}]] — {note}")
        except Exception as e:
            log(f"person write failed: {e}")
    d = decided.get("digest")
    d = d if isinstance(d, dict) else {}
    clima = _as_text(d.get("clima")).strip() or None
    social = [_as_text(x).strip() for x in (d.get("social") or []) if _as_text(x).strip()]
    if clima or social or people_lines:
        try:
            log(f"digest: {upsert_daily_digest(date_iso, clima, people_lines, social)}")
        except Exception as e:
            log(f"digest write failed: {e}")

    mutated = apply_task_updates(decided.get("task_updates") or [], dry=False)
    return nb, nt, len(urgent), len(mutated)


async def run_whatsapp() -> int:
    dry = "--dry-run" in sys.argv
    token = load_oauth_token()
    if not token:
        log("no anthropic OAuth token (Keychain/auth.json) — aborting")
        return 1

    state = load_state()
    store = load_chats()
    watermark = state.get("last_processed_ts")
    records = read_window(watermark, state.get("boundary_msg_ids"))
    buckets = bucket_by_chat(records)
    log(f"window={WINDOW_HOURS}h watermark={watermark or 'none'} records={len(records)} buckets={len(buckets)} dry_run={dry}")
    if not buckets:
        print("[context-scraping] no messages in window")
        if records and not dry:
            _advance_watermark(state, records)
        return 0

    headers = _headers_oauth(token)
    sem = asyncio.Semaphore(MAX_CONCURRENT)

    async with httpx.AsyncClient() as http:
        await enrich_window_media(records, http, headers)

        async def gated(bucket: dict) -> dict:
            async with sem:
                return await classify_bucket(http, headers, bucket)

        results = await asyncio.gather(*(gated(b) for b in buckets))
        keep = [r for r in results if has_proposals(r)]
        errored = [r for r in results if r.get("error")]
        log(f"classify: with_proposals={len(keep)} errored={len(errored)}")
        advance_ok = not errored
        ctx, summary_ok = await update_chat_summaries(http, headers, sem, buckets, store)
        advance_ok = advance_ok and summary_ok
        if not keep:
            print("[context-scraping] classifier surfaced nothing")
            if advance_ok and not dry:
                _advance_watermark(state, records)
                save_chats(store)
            return 0

        brain_context = render_brain_context()
        tasks_context = _recent_tasks_context()
        decided, decide_ok = await decide(http, headers, keep, brain_context, ctx, tasks_context)
    log(
        f"decided: blocks={len(decided.get('blocks', []))} "
        f"tasks={len(decided.get('tasks', []))} urgent={len(decided.get('urgent', []))} "
        f"task_updates={len(decided.get('task_updates', []))} "
        f"calls={_usage_totals['calls']} in={_usage_totals['input_tokens']} out={_usage_totals['output_tokens']}"
    )

    if dry:
        apply_task_updates(decided.get("task_updates") or [], dry=True)
        print(json.dumps(decided, ensure_ascii=False, indent=2))
        return 0

    nb, nt, nu, nm = await persist(decided)
    if advance_ok and decide_ok:
        _advance_watermark(state, records)
        save_chats(store)
    else:
        log("watermark/chats not advanced (classify/summary/decide error) — overlapping retry next cycle")
    print(f"[context-scraping] persisted blocks={nb} tasks={nt} urgent_dm={nu} task_mutations={nm}")
    return 0


async def main(source: str = "whatsapp") -> int:
    if source == "whatsapp":
        return await run_whatsapp()
    log(f"unknown source: {source}")
    return 1


if __name__ == "__main__":
    _source = "whatsapp"
    for _arg in sys.argv[1:]:
        if _arg.startswith("--source="):
            _source = _arg.split("=", 1)[1]
    sys.exit(asyncio.run(main(_source)))
