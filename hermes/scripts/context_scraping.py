#!/usr/bin/env python3
"""
context_scraping.py — self-contained context scraper, fully on Gabriel's
Claude Code account (Claude Max OAuth), like the brain-vault Haiku ingest.

Pipeline (no gateway, no agent phase):
  1. scan /mnt/garime/state/inbox/wa_ingest.jsonl ONCE per run, bucket by chat.
     The same pass yields the new-message window (past the watermark), a bounded
     72h context tail per chat (HERMES_WA_CONTEXT_LOOKBACK_HOURS) and the
     bootstrap tail for chats with new messages. CONTEXT_MAX_CHARS=6000
     measures rendered prompt size, including timestamps and media enrichment.
  2. CLASSIFY each bucket in parallel with Haiku (model.nano) → proposals. Each
     WhatsApp bucket is shown CONTEXTO (the 72h tail + the previous live summary,
     read-only, for interpretation) and MENSAGENS NOVAS — only the latter may
     produce proposals. Emails get no replay.
  3. DECIDE via one stateless `pi -p` subprocess — openai-codex /
     gpt-5.6-luna / thinking high by default (HERMES_WA_DECIDE_PROVIDER,
     HERMES_WA_DECIDE_MODEL, HERMES_WA_DECIDE_EFFORT). No session, no tools,
     no skills/extensions/prompt-templates/context-files: the prompt is the
     only input. Runs only when CLASSIFY kept at least one proposal, and
     emits the final {blocks, tasks, urgent}.
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
import hashlib
import importlib
import json
import os
import re
import subprocess
import sys
import unicodedata
import uuid
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
from geo_context import render_brain_context

PKG_DIR = Path(__file__).resolve().parent
GARIME_MOUNT = Path("/mnt/garime")
STATE_DIR = GARIME_MOUNT / "pi" / "state"
JSONL_PATH = GARIME_MOUNT / "state" / "inbox" / "wa_ingest.jsonl"
EMAIL_JSONL_PATH = GARIME_MOUNT / "state" / "inbox" / "email_ingest.jsonl"
OUTBOX_DIR = GARIME_MOUNT / "pi" / "wa-outbox"
AUTH_PATH = Path(os.path.expanduser("~/.prime/agent/auth.json"))
ENV_PATH = STATE_DIR / ".env"
STATE_PATH = STATE_DIR / "context_scraping.state.json"
CHATS_PATH = STATE_DIR / "context_scraping.chats.json"
PROPOSALS_PATH = STATE_DIR / "task_proposals.json"
TASK_ARCHIVE_DIR = STATE_DIR / "task_archive"
ARCHIVE_LOG = TASK_ARCHIVE_DIR / "archive_log.jsonl"

GABRIEL_TELEGRAM_CHAT_ID = "5225262193"

ALIASES: dict[str, list[str]] = {
    "danilo": ["danilo", "danilo oliveira"],
}


def _load_geo_write():
    import importlib
    import importlib.util

    pdir = PKG_DIR / "plugins" / "geo-tools"
    spec = importlib.util.spec_from_file_location(
        "geo_tools", pdir / "__init__.py", submodule_search_locations=[str(pdir)]
    )
    pkg = importlib.util.module_from_spec(spec)
    sys.modules["geo_tools"] = pkg
    spec.loader.exec_module(pkg)
    return importlib.import_module("geo_tools.geo_write")


geo_write = _load_geo_write()
tasks_fs = importlib.import_module("geo_tools.tasks_fs")
GeoError = geo_write._GeoError
WRITER = "context-scraping"
MAX_BLOCKS_PER_RUN = int(os.environ.get("HERMES_MAX_BLOCKS_PER_RUN", "3"))
MAX_TASKS_PER_RUN = int(os.environ.get("HERMES_MAX_TASKS_PER_RUN", "3"))


def _config_model(key: str, env_key: str, fallback: str) -> str:
    env = os.environ.get(env_key)
    if env:
        return env
    return fallback


def _nano_model() -> str:
    return _config_model("nano", "HERMES_NANO_MODEL", "claude-haiku-4-5")


def _decide_provider() -> str:
    return os.environ.get("HERMES_WA_DECIDE_PROVIDER") or "openai-codex"


def _decide_model() -> str:
    return os.environ.get("HERMES_WA_DECIDE_MODEL") or "gpt-5.6-luna"


def _decide_effort() -> str:
    return os.environ.get("HERMES_WA_DECIDE_EFFORT") or "high"


# Persisted watermark (STATE_PATH, key last_processed_ts) is the real anti-overlap
# mechanism: only records past it are "new". WINDOW_HOURS is just
# the bootstrap lookback the very first time a chat/state file is seen.
WINDOW_HOURS = int(os.environ.get("HERMES_WA_WINDOW_HOURS", "2"))
# Read-only replay handed to CLASSIFY so it can interpret the new messages.
# Never a proposal source: only messages past the watermark can produce those.
CONTEXT_LOOKBACK_HOURS = int(os.environ.get("HERMES_WA_CONTEXT_LOOKBACK_HOURS", "72"))
CONTEXT_MAX_MSGS = int(os.environ.get("HERMES_WA_CONTEXT_MAX_MSGS", "120"))
CONTEXT_MAX_CHARS = int(os.environ.get("HERMES_WA_CONTEXT_MAX_CHARS", "6000"))
EMAIL_WINDOW_HOURS = int(os.environ.get("HERMES_EMAIL_WINDOW_HOURS", "24"))
EMAIL_TEXT_CAP = 1200
MAX_PROPOSALS_PER_RUN = int(os.environ.get("HERMES_MAX_PROPOSALS_PER_RUN", "3"))
PROPOSAL_TTL_DAYS = 7
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

MEDIA_DIR = STATE_DIR / "wa_media"
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

ORIGEM: {source_note}
Chat: {label} (group={is_group_lit}, jid={chat_id})

===== CONTEXTO — SOMENTE PARA INTERPRETAR, NUNCA PARA PROPOR =====
Nada daqui pode virar proposta. Serve só para você entender do que as MENSAGENS NOVAS estão falando (pronomes, "isso", "aquilo combinado", quem é quem, o que já foi resolvido). Se algo interessante aparece só aqui, IGNORE: já foi visto num ciclo anterior.

RESUMO VIVO ANTERIOR DESTA CONVERSA:
{prev_summary}

MENSAGENS ANTERIORES (cronológicas, últimas {context_hours}h, já processadas):
{context_messages}

===== MENSAGENS NOVAS — A ÚNICA FONTE DE PROPOSTAS =====
Toda proposta que você retornar tem que sair DAQUI:
{messages}

Procure SOMENTE por (sempre nas MENSAGENS NOVAS):
- FATO sobre pessoa/projeto/decisão/preferência — algo que ainda vai ser verdade mês que vem — inclui decisão tomada na conversa.
- TAREFA: o Gabriel se comprometeu (explícita ou implicitamente) a fazer algo
- LEMBRETE temporal: data específica importa
- URGENTE: alguém esperando ele agora (pergunta direta, deadline batendo)
- PESSOA: fato/mudança de estado sobre pessoa nomeada (fechou negócio, mudou de cidade, pediu algo) — algo que dá continuidade à relação.
- COMBINADO SOCIAL: plano informal com alguém (jantar, café, "bora sexta") — mesmo sem compromisso firme.
- CLIMA (no máx 1, bias forte a VAZIO): só se o Gabriel EXPRESSOU explicitamente como está o dia dele. Uma linha situacional. NUNCA clínico, NUNCA inferido de tom, NUNCA sobre terceiros.

NÃO sugira: conversa fiada, piadas, reações, notícias, encaminhamentos, combinados vagos. Dúvida = não sugere.

NÃO sugira nada que só aparece no CONTEXTO. Se a mesma coisa aparece no CONTEXTO e nas MENSAGENS NOVAS, ela já foi processada — só proponha se a mensagem nova acrescenta algo (mudou o prazo, foi concluída, virou outra coisa).

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

DECIDE_PROMPT_TEMPLATE = """Você é o segundo cérebro do Gabriel (garime). Abaixo estão propostas extraídas por um classificador rápido de duas origens: conversas de WhatsApp das últimas {window}h e emails recém-chegados (cada entrada traz "source": "whatsapp" ou "email"; em email a "conversa" é uma caixa de entrada, o Gabriel é o destinatário, não o autor). Você é o filtro inteligente: decida o que REALMENTE vale guardar. Dedup, una propostas relacionadas, descarte ruído. Bias para BLOCOS: guardar MENOS, com qualidade. Bias para TAREFAS: puxar pro AUTÔNOMO (ver CONFIANÇA).

CONTEXTO DO CÉREBRO (vault real do Gabriel, files-are-truth — use para LINKAR e DEDUPLICAR):
{brain_context}

CONTEXTO DAS CONVERSAS (resumo vivo por chat ativo neste ciclo — use para entender o QUE já vinha acontecendo, não é proposta):
{chat_summaries}

TASKS EXISTENTES NO GARIME (cada uma com seu id — para criar/dedup E para o CICLO DE VIDA abaixo):
{tasks_context}

PROPOSTAS (JSON, uma entrada por chat):
{proposals_json}

Como decidir:
- FATO durável sobre pessoa/projeto/decisão/preferência → um bloco. layer "agent" se é fato sólido e auto-evidente; layer "review" se merece o olhar dele antes de virar canônico. Auto-extraído de chat tende a "review".
- COMPROMISSO/algo a fazer → uma task quando houver AÇÃO CLARA (verbo acionável: mandar, pagar, resolver, enviar, responder, agendar) e DONO CLARO = o Gabriel (não outra pessoa, não o grupo). Prazo explícito NÃO é mais obrigatório — sem prazo, deixe "due" null e o sistema põe pra hoje. Sem ação clara ou sem dono claro, não é task — vira linha de contexto no bloco pessoa/projeto (people[]) ou digest.social. NÃO crie task de convite social casual ("bora sair", "vamos marcar"), de logística de encontro (horário/local de algo já combinado), ou de micro-passo de conversa em andamento ("manda o link", "me avisa quando chegar") — isso é ruído conversacional, não compromisso. title curto e acionável; tasks não carregam prosa — contexto durável vira bloco. PRAZO (due): NÃO invente horário. Se a conversa dá dia E hora explícitos → due em hora LOCAL naive, SEM 'Z' (ex: 2026-06-22T13:00:00) — NÃO converta pra UTC, o código faz isso. Se dá só o dia → due como SÓ DATA (ex: 2026-06-22), sem hora — o sistema põe no fim daquele dia. NUNCA data no passado, NUNCA horário aleatório.
- CONFIANÇA (obrigatório em toda task): campo "confidence" = "alta" ou "ambigua".
  - "alta" → o sistema CRIA a task sozinho. Use quando a ação é clara E o dono é o Gabriel. Na dúvida razoável entre alta e ambígua, escolha ALTA — o custo de uma task a mais é baixo, o de perder um compromisso é alto.
  - "ambigua" → NÃO cria; o sistema pergunta ao Gabriel no WhatsApp antes. Reserve para quando falta a INTENÇÃO dele: alguém pediu/cobrou algo e ele não respondeu nem assumiu, o email sugere uma ação mas ninguém a atribuiu a ele, ou é um "talvez" sem dono.
  - Email de robô/marketing/newsletter/notificação automática não vira task nem proposta — descarta.
  - "origem" (obrigatório): de onde veio, curto — nome do chat ou "email <conta>: <remetente/assunto>". É o que o Gabriel vê ao ser perguntado.
- URGENTE: alguém esperando ele agora, decisão/deadline batendo → urgent (ele recebe no Telegram).
- Conversa fiada, piada, combinado vago, fofoca, novidade qualquer → descarta.
- SINAL: só vira bloco ou task se tiver conteúdo acionável ou memorável de verdade. "Bom dia", reação, emoji solto, "tudo bem?", combinado que já era óbvio → sem sinal, descarta (não é bloco nem task).
- DEDUP CONTRA O VAULT: se o CONTEXTO já tem um bloco ou task sobre o mesmo assunto, NÃO recrie — descarta. Só cria se acrescenta algo genuinamente novo.
- DEDUP CONTRA TASKS EXISTENTES: se uma TASK EXISTENTE (ativa OU concluída recente) já cobre o mesmo compromisso, NÃO recrie a task — descarta. Algo já concluído só vira task nova se for claramente um novo ciclo/pedido.
- PESSOA: fato durável sobre pessoa nomeada → people[]. target_block = título EXATO da lista "Blocos existentes" se a pessoa já tem bloco; senão null (código cria bloco novo review). note curta, 1 frase.
- COMBINADO SOCIAL informal → digest.social (uma linha leve). NUNCA vira task. SÓ vira task se o Gabriel se comprometeu EXPLICITAMENTE a executar algo acionável com dia definido — aí segue o caminho normal de tasks.
- Não duplique em digest.social/people algo que já virou task ou já existe no CONTEXTO.
- Não invente nada fora das propostas. Dúvida = não guarda.
- CICLO DE VIDA DE TASKS EXISTENTES — só com evidência EXPLÍCITA na conversa (dúvida = não mexe):
  - Se uma task ATIVA já foi FEITA → action "complete" com o id EXATO. BARRA DE EVIDÊNCIA: só marque complete com prova explícita de conclusão na conversa ("já resolvi", "paguei", "mandei", comprovante/print enviado, a outra pessoa confirmando o recebimento). Suspeita, silêncio, "vou fazer", ou o assunto ter só saído de pauta NÃO bastam — nesse caso não mexe.
  - Se uma task ATIVA mudou de prazo ou de escopo/título (foi remarcada, adiada, renomeada) → action "update" com o id EXATO e os campos "title" e/ou "due" (pelo menos um). PREFIRA "update" de uma task existente a criar uma task nova parecida: se o compromisso é o mesmo e só mudou a data ou a redação, é update, não task nova.
  - Se uma task ATIVA foi claramente CANCELADA, virou obsoleta, ou é DUPLICATA de outra → action "delete" com o id EXATO.
  - As tasks CONCLUÍDAS recentes aparecem na lista de contexto só para você saber o que já foi feito — NÃO as recrie como task nova e NÃO as reabra.
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
{{"blocks": [{{"title": "...", "body": "Parte de [[MOC — X]]\\n...com [[wikilinks]]...", "type": "fleeting", "layer": "review"}}], "tasks": [{{"title": "...", "due": "2026-06-22 ou null", "confidence": "alta", "origem": "Antônio Gili"}}], "urgent": [{{"text": "...", "chat": "..."}}], "people": [{{"target_block": "Antônio Gili ou null", "person": "Antônio", "note": "...", "moc": "MOC — Pessoal"}}], "digest": {{"social": ["jantar sexta com [[Bernardo Biglia]]"]}}, "task_updates": [{{"id": "ABC-123...", "action": "complete", "reason": "Antonio confirmou que o QR PIX já está no ar"}}, {{"id": "DEF-456...", "action": "update", "due": "2026-06-25", "title": "opcional — novo título", "reason": "Marcos adiou a entrega pra quinta"}}]}}
action só pode ser "complete", "delete" ou "update". Em "update", mande "title" e/ou "due" (pelo menos um); "due" segue o MESMO formato das tasks novas (só data YYYY-MM-DD, ou hora local naive YYYY-MM-DDTHH:MM:SS sem 'Z').

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


TOKEN_EXPIRY_BUFFER_MS = 60_000
_auth_error_calls = 0


def load_oauth_token() -> str | None:
    if not AUTH_PATH.exists():
        log(f"auth do pi ausente: {AUTH_PATH}")
        return None
    try:
        data = json.loads(AUTH_PATH.read_text(encoding="utf-8"))
    except Exception as e:
        log(f"auth do pi ilegivel ({AUTH_PATH}): {e}")
        return None
    entry = data.get("anthropic") if isinstance(data, dict) else None
    if not isinstance(entry, dict):
        log(f"auth do pi sem bloco anthropic: {AUTH_PATH}")
        return None
    access = entry.get("access") or entry.get("access_token")
    if not access:
        log(f"auth do pi sem access token: {AUTH_PATH}")
        return None
    exp_ms = entry.get("expires") or entry.get("expires_at_ms")
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    if exp_ms and now_ms >= int(exp_ms) - TOKEN_EXPIRY_BUFFER_MS:
        log(f"auth do pi expirada ({AUTH_PATH}) — o pi é dono do refresh, curator não renova")
        return None
    return access


PI_BIN = os.environ.get("HERMES_PI_BIN", "/home/biel/.local/bin/pi")
PI_DECIDE_TIMEOUT_S = float(os.environ.get("HERMES_PI_TIMEOUT_S", "900"))


class PiLaneError(RuntimeError):
    pass


def _pi_argv(prompt: str) -> list[str]:
    return [
        PI_BIN,
        "-p",
        "--no-session",
        "--no-tools",
        "--no-skills",
        "--no-context-files",
        "--no-extensions",
        "--no-prompt-templates",
        "--provider", _decide_provider(),
        "--model", _decide_model(),
        "--thinking", _decide_effort(),
    ]


async def _pi_complete(prompt: str, timeout_s: float) -> str:
    argv = _pi_argv(prompt)
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except Exception as e:
        raise PiLaneError(f"nao consegui executar {PI_BIN}: {type(e).__name__}: {e}") from e
    try:
        out, err = await asyncio.wait_for(proc.communicate(prompt.encode("utf-8")), timeout=timeout_s)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except Exception:
            pass
        await proc.wait()
        raise PiLaneError(f"pi excedeu {timeout_s}s na lane DECIDE")
    if proc.returncode != 0:
        tail = (err or b"").decode(errors="replace").strip()[-400:]
        raise PiLaneError(f"pi saiu rc={proc.returncode}: {tail}")
    text = (out or b"").decode(errors="replace").strip()
    if not text:
        raise PiLaneError("pi devolveu saida vazia na lane DECIDE")
    return text


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


def _msg_key(rec: dict) -> str:
    """Stable identity for a message. msg_id when present; otherwise a hash of the
    immutable fields, so a record without an id still dedups against itself across
    the two views (new window vs context replay) of the same JSONL line."""
    mid = _as_text(rec.get("msg_id")).strip()
    if mid:
        return f"id:{mid}"
    basis = "\x1f".join(
        _as_text(rec.get(k)) for k in ("ts", "chat", "sender", "push_name", "type", "text")
    )
    basis += "\x1f" + ("1" if rec.get("from_me") else "0")
    return "h:" + hashlib.sha1(basis.encode("utf-8")).hexdigest()


def _is_group_chat(rec: dict) -> bool:
    if rec.get("is_group"):
        return True
    return _as_text(rec.get("chat")).endswith("@g.us")


def _parse_utc_ts(value) -> datetime:
    parsed = datetime.fromisoformat(_as_text(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


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


def _advance_watermark_keyed(state: dict, records: list[dict], ts_key: str, ids_key: str) -> None:
    ts_values = [r.get("ts") for r in records if r.get("ts")]
    if not ts_values:
        return
    new_ts = max(ts_values)
    last_ts = state.get(ts_key) or ""
    if new_ts > last_ts:
        state[ts_key] = new_ts
        state[ids_key] = [r.get("msg_id") for r in records if r.get("ts") == new_ts and r.get("msg_id")]
        state["last_run_at"] = _now_z()
        save_state(state)
    elif new_ts == last_ts:
        existing = list(state.get(ids_key) or [])
        new_ids = [r.get("msg_id") for r in records if r.get("ts") == new_ts and r.get("msg_id")]
        state[ids_key] = existing + [i for i in new_ids if i not in existing]
        state["last_run_at"] = _now_z()
        save_state(state)


def _advance_watermark(state: dict, records: list[dict]) -> None:
    ts_values = [r.get("ts") for r in records if r.get("ts")]
    if not ts_values:
        return
    new_ts = max(ts_values)
    last_ts = state.get("last_processed_ts") or ""
    new_ids = [
        (_as_text(r.get("msg_id")).strip() or _msg_key(r))
        for r in records
        if r.get("ts") == new_ts
    ]
    if new_ts > last_ts:
        state["last_processed_ts"] = new_ts
        state["boundary_msg_ids"] = new_ids
    elif new_ts == last_ts:
        existing = list(state.get("boundary_msg_ids") or [])
        state["boundary_msg_ids"] = existing + [i for i in new_ids if i not in existing]
    else:
        return
    state["last_run_at"] = _now_z()
    save_state(state)


def _email_uid(msg_id) -> int | None:
    raw = _as_text(msg_id)
    head = raw.split("@", 1)[0].strip()
    try:
        return int(head)
    except Exception:
        return None


def _email_uids(state: dict) -> dict:
    uids = state.get("email_uids")
    return uids if isinstance(uids, dict) else {}


def _advance_email_watermark(state: dict, records: list[dict]) -> None:
    uids = dict(_email_uids(state))
    changed = False
    for r in records:
        uid = _email_uid(r.get("msg_id"))
        if uid is None:
            continue
        acct = r.get("account") or "?"
        cur = uids.get(acct)
        if not isinstance(cur, int) or uid > cur:
            uids[acct] = uid
            changed = True
    if not changed:
        return
    state["email_uids"] = uids
    state["last_run_at"] = _now_z()
    save_state(state)


def scan_wa_jsonl(
    watermark: str | None,
    boundary_msg_ids: list[str] | None = None,
    known_chat_ids: set[str] | frozenset[str] = frozenset(),
) -> dict:
    """Single pass over wa_ingest.jsonl per run.

    Returns {"new": [...], "context": {chat: metadata}, "bootstrap": {chat: [...]}}:
      new       — past the watermark; the ONLY records allowed to yield proposals
      context   — last CONTEXT_LOOKBACK_HOURS per chat, new records excluded by
                  key, tail-bounded; read-only replay for CLASSIFY
      bootstrap — latest 1500 records only for chats with new messages this run
    """
    empty = {"new": [], "context": {}, "bootstrap": {}}
    if not JSONL_PATH.exists():
        return empty
    wm_dt = None
    if watermark:
        try:
            wm_dt = _parse_utc_ts(watermark)
        except Exception:
            wm_dt = None
    boundary_ids = set(boundary_msg_ids or [])
    now = datetime.now(timezone.utc)
    fallback_cutoff = now - timedelta(hours=WINDOW_HOURS)
    context_cutoff = now - timedelta(hours=CONTEXT_LOOKBACK_HOURS)
    end_dt = None
    end_raw = os.environ.get("HERMES_WA_WINDOW_END")
    if end_raw:
        try:
            end_dt = _parse_utc_ts(end_raw)
        except Exception:
            end_dt = None
    if end_dt is not None:
        context_cutoff = end_dt - timedelta(hours=CONTEXT_LOOKBACK_HOURS)
    records: list[dict] = []
    dropped_empty = 0
    dropped_oneway = 0
    dropped_malformed = 0
    try:
        with JSONL_PATH.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    ts_raw = rec.get("timestamp") or rec.get("ts", "")
                    ts = _parse_utc_ts(ts_raw)
                except Exception:
                    dropped_malformed += 1
                    continue
                if end_dt is not None and ts > end_dt:
                    continue
                if _is_empty_record(rec):
                    dropped_empty += 1
                    continue
                chat = rec.get("chat") or ""
                if _is_one_way_chat(chat):
                    dropped_oneway += 1
                    continue
                records.append(rec)
    except OSError as e:
        log(f"whatsapp scan failed: {type(e).__name__}")
        return empty
    if dropped_empty or dropped_oneway or dropped_malformed:
        log(f"dropped: malformed={dropped_malformed} empty={dropped_empty} one_way={dropped_oneway}")
    records.sort(key=lambda r: _parse_utc_ts(r.get("timestamp") or r.get("ts")))
    out: list[dict] = []
    for rec in records:
        ts = _parse_utc_ts(rec.get("timestamp") or rec.get("ts"))
        key = _msg_key(rec)
        is_new = True
        if wm_dt is not None:
            if ts < wm_dt:
                is_new = False
            elif ts == wm_dt and (rec.get("msg_id") in boundary_ids or key in boundary_ids):
                is_new = False
        elif ts < fallback_cutoff:
            is_new = False
        if is_new:
            out.append(rec)
    new_keys = {_msg_key(r) for r in out}
    context: dict[str, dict[str, dict]] = {}
    for rec in records:
        chat = rec.get("chat") or ""
        ts = _parse_utc_ts(rec.get("timestamp") or rec.get("ts"))
        key = _msg_key(rec)
        if chat and ts >= context_cutoff and key not in new_keys:
            context.setdefault(chat, {})[key] = rec
    ctx_out: dict[str, dict] = {}
    for chat, messages_by_key in context.items():
        context_list = sorted(
            messages_by_key.values(),
            key=lambda r: _parse_utc_ts(r.get("timestamp") or r.get("ts")),
        )
        context_list, was_truncated = _trim_context(context_list)
        ctx_out[chat] = {
            "context": context_list,
            "context_truncated": was_truncated,
        }
    new_ids = {r.get("chat") or "" for r in out} - {""}
    bootstrap = {chat: deque(maxlen=BOOTSTRAP_MAX_MSGS) for chat in new_ids}
    for rec in records:
        chat = rec.get("chat") or ""
        if chat in bootstrap:
            bootstrap[chat].append(rec)
    boot_out = {chat: list(messages) for chat, messages in bootstrap.items()}
    return {"new": out, "context": ctx_out, "bootstrap": boot_out}


def scan_email_jsonl(uids: dict | None = None) -> dict:
    empty = {"new": []}
    if not EMAIL_JSONL_PATH.exists():
        return empty
    seen_uids = uids if isinstance(uids, dict) else {}
    fallback_cutoff = datetime.now(timezone.utc) - timedelta(hours=EMAIL_WINDOW_HOURS)
    dropped_noid = 0
    out: list[dict] = []
    try:
        with EMAIL_JSONL_PATH.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                acct = rec.get("account") or "?"
                uid = _email_uid(rec.get("msg_id"))
                if uid is None:
                    dropped_noid += 1
                    continue
                last_uid = seen_uids.get(acct)
                if isinstance(last_uid, int):
                    if uid <= last_uid:
                        continue
                else:
                    try:
                        ts = _parse_utc_ts(rec.get("ts"))
                    except Exception:
                        ts = None
                    if ts is not None and ts < fallback_cutoff:
                        continue
                subject = (rec.get("subject") or "").strip()
                body = (rec.get("text") or "").strip()
                if not subject and not body:
                    continue
                out.append({
                    "ts": rec.get("ts"),
                    "msg_id": rec.get("msg_id"),
                    "chat": f"email:{rec.get('account') or '?'}",
                    "account": rec.get("account") or "?",
                    "sender": rec.get("sender") or "?",
                    "push_name": rec.get("sender") or "?",
                    "from_me": False,
                    "is_group": False,
                    "type": "email",
                    "source": "email",
                    "subject": subject,
                    "text": f"assunto: {subject} | {body[:EMAIL_TEXT_CAP]}",
                })
    except Exception as e:
        log(f"email window read failed: {e}")
        return empty
    if dropped_noid:
        log(f"email dropped: sem uid no msg_id={dropped_noid}")
    out.sort(key=lambda r: r.get("ts", ""))
    return {"new": out}


def bucket_by_account(records: list[dict]) -> list[dict]:
    out: list[dict] = []
    for r in records:
        acct = r.get("account") or "?"
        sender = _as_text(r.get("sender")).strip() or "?"
        subject = _as_text(r.get("subject")).strip()
        if not subject:
            text = _as_text(r.get("text"))
            subject = text.partition("assunto: ")[2].partition(" |")[0].strip() or "?"
        out.append({
            "chat_id": f"email:{acct}:{_msg_key(r)}",
            "is_group": False,
            "source": "email",
            "label": f"email {acct}: {sender}/{subject}",
            "messages": [r],
            "context": [],
            "context_truncated": False,
        })
    return out


def bucket_by_chat(records: list[dict], context: dict[str, dict] | None = None) -> list[dict]:
    by_chat: dict[str, dict] = {}
    for r in records:
        chat = r.get("chat") or ""
        if not chat:
            continue
        bucket = by_chat.get(chat)
        if bucket is None:
            bucket = {
                "chat_id": chat,
                "is_group": False,
                "source": "whatsapp",
                "messages": [],
                "context": [],
                "context_truncated": False,
                "_name_counts": {},
            }
            by_chat[chat] = bucket
        bucket["is_group"] = bucket["is_group"] or _is_group_chat(r)
        bucket["messages"].append(r)
        name = r.get("push_name")
        if name and not r.get("from_me"):
            bucket["_name_counts"][name] = bucket["_name_counts"].get(name, 0) + 1
    out: list[dict] = []
    ctx = context or {}
    for chat_id, bucket in by_chat.items():
        names = bucket["_name_counts"]
        if names:
            bucket["label"] = max(names.items(), key=lambda kv: kv[1])[0]
        else:
            bucket["label"] = chat_id
        bucket["messages"].sort(key=lambda r: r.get("ts", ""))
        del bucket["_name_counts"]
        msg_meta = ctx.get(chat_id) or {}
        if isinstance(msg_meta, list):
            msg_meta = {"context": msg_meta, "context_truncated": False}
        bucket["context"] = list(msg_meta.get("context") or [])
        bucket["context_truncated"] = bool(msg_meta.get("context_truncated", False))
        for r in bucket["context"]:
            bucket["is_group"] = bucket["is_group"] or _is_group_chat(r)
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


def _format_message_line(m: dict) -> str:
    if m.get("from_me"):
        sender = "eu (Gabriel)"
    else:
        sender = m.get("push_name") or (m.get("sender") or "?")
    ts = (m.get("timestamp") or m.get("ts") or "")[:19].replace("T", " ")
    text = (m.get("text") or "").strip().replace("\n", " ")
    mtype = m.get("type") or ""
    enriched = m.get("_media_text")
    if enriched is None:
        media_path = _as_text((m.get("media") or {}).get("path"))
        enriched = _media_memo.get(media_path) if media_path else None
    if enriched:
        text = f"{enriched} {text}".strip() if text else enriched
    elif mtype not in ("text", ""):
        text = f"[{mtype}] {text}".strip()
    if not text:
        text = f"[{mtype or 'sem conteúdo'}]"
    return f"{ts} {sender}: {text}"


def format_messages(messages: list[dict]) -> str:
    return "\n".join(_format_message_line(m) for m in messages)


def _measure_formatted_size(messages: list[dict]) -> int:
    if not messages:
        return 0
    return sum(len(_format_message_line(message)) for message in messages) + len(messages) - 1


def _trim_context(messages: list[dict], max_msgs: int | None = None,
                  max_chars: int | None = None) -> tuple[list[dict], bool]:
    """Keep the most recent messages that fit both rendered-output caps."""
    cap_msgs = CONTEXT_MAX_MSGS if max_msgs is None else max_msgs
    cap_chars = CONTEXT_MAX_CHARS if max_chars is None else max_chars
    kept = list(messages[-max(0, cap_msgs):]) if cap_msgs > 0 else []
    truncated = len(kept) != len(messages)
    while kept and _measure_formatted_size(kept) > max(0, cap_chars):
        kept.pop(0)
        truncated = True
    if not kept and messages:
        truncated = True
    return kept, truncated


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
                if resp.status_code in (401, 403):
                    global _auth_error_calls
                    _auth_error_calls += 1
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


def format_prompt(bucket: dict, prev_summary: str = "") -> str:
    is_email = bucket.get("source") == "email"
    source_note = (
        "EMAIL — cada 'mensagem' é um email recebido pelo Gabriel (remetente + assunto no texto). "
        "Ele é o destinatário, não o autor. Newsletter/marketing/notificação automática é ruído: ignore."
        if is_email else "WhatsApp — conversa real, o Gabriel é um dos interlocutores."
    )
    if is_email:
        context_block = "(email não tem replay de contexto)"
        summary_block = "(email não tem resumo vivo)"
    else:
        ctx_msgs = bucket.get("context") or []
        context_block = format_messages(ctx_msgs) if ctx_msgs else "(sem mensagens anteriores no periodo)"
        if bucket.get("context_truncated"):
            context_block = "[...contexto truncado a 6000 chars (120 mensagens)]\n" + context_block
        summary_block = _as_text(prev_summary).strip() or "(sem resumo anterior)"
    return HAIKU_PROMPT_TEMPLATE.format(
        source_note=source_note,
        label=bucket["label"],
        chat_id=bucket["chat_id"],
        is_group=bucket["is_group"],
        is_group_lit="true" if bucket["is_group"] else "false",
        window=WINDOW_HOURS,
        context_hours=CONTEXT_LOOKBACK_HOURS,
        context_messages=context_block,
        prev_summary=summary_block,
        messages=format_messages(bucket["messages"]),
    )


async def classify_bucket(http: httpx.AsyncClient, headers: dict, bucket: dict,
                          prev_summary: str = "") -> dict:
    prompt = format_prompt(bucket, prev_summary)
    empty_proposals = {"facts": [], "tasks": [], "reminders": [], "urgent": [], "people": [], "social": [], "mood": []}
    raw = await _call_model(http, headers, HAIKU_MODEL, prompt, MAX_TOKENS_OUT, PER_CALL_TIMEOUT_S)
    if raw is None:
        raise PiLaneError(f"CLASSIFY falhou para {bucket['chat_id']}")
    parsed = parse_json_response(raw)
    if not isinstance(parsed, dict):
        raise PiLaneError(f"CLASSIFY devolveu JSON invalido para {bucket['chat_id']}")
    if not isinstance(parsed.get("proposals"), dict):
        parsed["proposals"] = empty_proposals
    for k in ("facts", "tasks", "reminders", "urgent", "people", "social", "mood"):
        if not isinstance(parsed["proposals"].get(k), list):
            parsed["proposals"][k] = []
    parsed.setdefault("chat", bucket["label"])
    parsed.setdefault("chat_id", bucket["chat_id"])
    parsed.setdefault("is_group", bucket["is_group"])
    parsed["source"] = bucket.get("source") or "whatsapp"
    return parsed


def _auth_error_from_response(exc: BaseException) -> bool:
    current: BaseException | None = exc
    seen: set[int] = set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        response = getattr(current, "response", None)
        status_code = getattr(response, "status_code", None)
        if status_code is None:
            status_code = getattr(current, "status_code", None)
        if status_code in (401, 403):
            return True
        if re.search(r"(?:HTTP\s*)?(?:401|403)\b", str(current), re.IGNORECASE):
            return True
        current = current.__cause__ or current.__context__
    return False


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


def select_full_history(chat_ids: set[str], bootstrap: dict[str, list[dict]]) -> dict[str, list[dict]]:
    """Bootstrap tails for never-seen chats, taken from the single run scan —
    no second pass over the JSONL."""
    return {c: (bootstrap.get(c) or [])[-BOOTSTRAP_MAX_MSGS:] for c in chat_ids}


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


async def update_chat_summaries(http: httpx.AsyncClient, headers: dict, sem: asyncio.Semaphore, buckets: list[dict], store: dict, bootstrap: dict[str, list[dict]] | None = None) -> tuple[str, bool]:
    chats = store.setdefault("chats", {})
    ok = True
    new_ids = {b["chat_id"] for b in buckets if b["chat_id"] not in chats}
    hist = select_full_history(new_ids, bootstrap or {}) if new_ids else {}

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
        {"chat": k.get("chat"), "source": k.get("source") or "whatsapp",
         "is_group": k.get("is_group"), "proposals": k.get("proposals")}
        for k in kept
    ]
    prompt = DECIDE_PROMPT_TEMPLATE.format(
        window=WINDOW_HOURS,
        brain_context=brain_context,
        chat_summaries=chat_summaries,
        tasks_context=tasks_context,
        proposals_json=json.dumps(payload, ensure_ascii=False, indent=2),
    )
    prompt += "\n\nIMPORTANTE: responda APENAS com o JSON pedido — sem markdown, sem prefacio, sem comentario."
    raw = await _pi_complete(prompt, PI_DECIDE_TIMEOUT_S)
    parsed = parse_json_response(raw)
    if not isinstance(parsed, dict):
        raise PiLaneError(f"pi devolveu JSON invalido na lane DECIDE: {raw[:300]}")
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


BLOCKS_DIR = Path("/mnt/garime/Gabriel") / "40 Conhecimento"
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
    blayer = layer if layer in ("agent", "review") else "review"
    res = geo_write.write_block(
        writer=WRITER, title=title, body=body or "", type="fleeting", layer=blayer, tags=None
    )
    path = res.get("path") or res.get("id") or ""
    try:
        return _nfc(str(Path(path).relative_to(BLOCKS_DIR)))
    except Exception:
        return _nfc(str(path))


def _classify_block_dup(msg: str) -> tuple[str | None, str | None]:
    if "simhash_dup" in msg:
        m = re.search(r"bloco ([0-9A-Fa-f-]{36})", msg)
        return "simhash", (m.group(1) if m else None)
    if msg.startswith("bloco duplicado"):
        m = re.search(r"id=([^,]+)", msg)
        return "title", (m.group(1).strip() if m else None)
    return None, None


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


def _norm_stem(s: str) -> str:
    s = _nfc(s or "").replace("-", " ")
    s = re.sub(r"\s+", " ", s).strip()
    s = unicodedata.normalize("NFKD", s.casefold())
    return "".join(c for c in s if not unicodedata.combining(c))


PERSON_FUZZY_MIN_LEN = 4


def _alias_group(stem_norm: str) -> set[str] | None:
    for canon, aliases in ALIASES.items():
        group = {_norm_stem(canon)} | {_norm_stem(a) for a in aliases}
        if stem_norm in group:
            return group
    return None


def _find_person_block(title: str) -> Path | None:
    t = _nfc((title or "").strip())
    if not t:
        return None
    for name in (t + ".md", _sanitize_filename(t) + ".md"):
        p = BLOCKS_DIR / name
        if p.exists():
            return p
    target = _norm_stem(t)
    group = _alias_group(target)
    candidates: list[Path] = []
    for p in BLOCKS_DIR.glob("*.md"):
        stem_norm = _norm_stem(p.stem)
        if stem_norm == target:
            return p
        if group and stem_norm in group:
            candidates.append(p)
        elif (
            len(target) >= PERSON_FUZZY_MIN_LEN
            and len(stem_norm) >= PERSON_FUZZY_MIN_LEN
            and (stem_norm.startswith(target) or target.startswith(stem_norm))
        ):
            candidates.append(p)
    unique = list(dict.fromkeys(candidates))
    if len(unique) == 1:
        return unique[0]
    if len(unique) > 1:
        log(f"person match ambiguous for {t!r}: {[p.stem for p in unique]} — skipping")
        return None
    return None


def append_person_continuity(target_block: str | None, person: str, note: str, moc: str, date_iso: str) -> str:
    note = (note or "").strip()
    if not note:
        return "skip"
    path = _find_person_block(target_block) if target_block else None
    if path is None and person:
        path = _find_person_block(person)
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


DIARY_PATH = BLOCKS_DIR / "Diário de contexto.md"
DIARY_MAX_DAYS = 30
_DAY_BLOCK_RE = re.compile(r"<!-- geo:day:(\d{4}-\d{2}-\d{2}) -->\n(.*?)\n<!-- /geo:day:\1 -->", re.DOTALL)


def _parse_diary_days(text: str) -> dict[str, str]:
    return {m.group(1): m.group(2) for m in _DAY_BLOCK_RE.finditer(text)}


def upsert_daily_digest(date_iso: str, people_lines: list[str], social_lines: list[str],
                        descartes_lines: list[str] | None = None) -> str:
    descartes_lines = descartes_lines or []
    if DIARY_PATH.exists():
        text = DIARY_PATH.read_text(encoding="utf-8")
        m = re.search(r"^id:\s*(\S+)", text, re.MULTILINE)
        block_id = m.group(1) if m else str(uuid.uuid4()).upper()
        days = _parse_diary_days(text)
    else:
        block_id = str(uuid.uuid4()).upper()
        days = {}
    day_text = days.get(date_iso) or (
        f"## {date_iso}\n\n"
        f"### Combinados\n<!-- geo:social:{date_iso} -->\n<!-- /geo:social:{date_iso} -->\n\n"
        f"### Pessoas\n<!-- geo:pessoas:{date_iso} -->\n<!-- /geo:pessoas:{date_iso} -->\n\n"
        f"### Descartes automáticos\n<!-- geo:descartes:{date_iso} -->\n<!-- /geo:descartes:{date_iso} -->\n\n"
        f"[[{date_iso}]]"
    )
    for name, new in ((f"social:{date_iso}", social_lines), (f"pessoas:{date_iso}", people_lines),
                      (f"descartes:{date_iso}", descartes_lines)):
        cur = _fenced_lines(day_text, name)
        for ln in new:
            ln = ("- " + ln.strip().lstrip("- ")).rstrip()
            if ln.strip("- ").strip() and not any(_norm(ln) == _norm(c) for c in cur):
                cur.append(ln)
        day_text = _replace_fenced(day_text, name, cur)
    days[date_iso] = day_text.strip("\n")
    cutoff = (datetime.now() - timedelta(days=DIARY_MAX_DAYS)).strftime("%Y-%m-%d")
    kept_dates = sorted((d for d in days if d >= cutoff), reverse=True)
    body = "# Diário de contexto\nParte de [[MOC — Rotina]]\n"
    for d in kept_dates:
        body += f"\n<!-- geo:day:{d} -->\n{days[d]}\n<!-- /geo:day:{d} -->\n"
    fm = f"---\nid: {block_id}\ntype: fleeting\nlayer: review\n---\n"
    _atomic_write(DIARY_PATH, fm + body)
    return DIARY_PATH.name


TASKS_DIR = Path("/mnt/garime/state/tasks")
EXPIRED_DIR = TASKS_DIR / ".expired"
EXPIRED_REVIEW_PATH = BLOCKS_DIR / "Tasks expiradas.md"
TASK_EXPIRY_DAYS = 7


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


COMPLETED_DEDUP_DAYS = 14


def _completed_at(task: dict, fallback_modified: bool = False) -> datetime | None:
    raw = task.get("completedAt") or ""
    if not raw and fallback_modified:
        raw = task.get("modifiedAt") or ""
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except Exception:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _recent_completed_match(title) -> str | None:
    norm = geo_write._normalize(_as_text(title))
    if not norm:
        return None
    cutoff = datetime.now(timezone.utc) - timedelta(days=COMPLETED_DEDUP_DAYS)
    for f in sorted(TASKS_DIR.glob("*.json")):
        if ".sync-conflict-" in f.name:
            continue
        try:
            t = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        if t.get("status") != "completed":
            continue
        if geo_write._normalize(_as_text(t.get("title"))) != norm:
            continue
        done = _completed_at(t)
        if done is not None and done >= cutoff:
            return _as_text(t.get("id")).strip() or f.stem
    return None


def _pending_title_owner(title, skip_id: str) -> str | None:
    norm = geo_write._normalize(_as_text(title))
    if not norm:
        return None
    for f in geo_write._task_files():
        try:
            t = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        tid = _as_text(t.get("id")).strip() or f.stem
        if tid == skip_id:
            continue
        if (t.get("status") == "pending"
                and (t.get("body") or {}).get("kind") == "task"
                and geo_write._normalize(_as_text(t.get("title"))) == norm):
            return tid
    return None


def write_task_file(title, due) -> tuple[str, bool]:
    done_id = _recent_completed_match(title)
    if done_id:
        log(f"task skipped (dedup, completed <{COMPLETED_DEDUP_DAYS}d): {done_id}.json [{_as_text(title)[:40]}]")
        return f"{done_id}.json", False
    if not _as_text(due).strip():
        due = _resolve_due(None)
    try:
        task = geo_write.write_task(writer=WRITER, title=_as_text(title), due=due)
        return f"{task.get('id')}.json", True
    except GeoError as e:
        msg = str(e)
        m = re.search(r"id=([0-9A-Fa-f-]+)", msg)
        if "duplicada" in msg and m:
            existing = m.group(1)
            log(f"task skipped (dedup, same title): {existing}.json [{_as_text(title)[:40]}]")
            return f"{existing}.json", False
        raise


def _proposal_hash(title) -> str:
    norm = geo_write._normalize(_as_text(title)) or _as_text(title).strip().lower()
    return hashlib.sha1(norm.encode("utf-8")).hexdigest()[:6]


def _load_proposals(state: dict) -> list[dict]:
    items: list[dict] = []
    try:
        raw = json.loads(PROPOSALS_PATH.read_text(encoding="utf-8"))
        if isinstance(raw, list):
            items = [p for p in raw if isinstance(p, dict)]
    except Exception:
        items = []
    legacy = state.pop("task_proposals", None)
    if isinstance(legacy, dict) and legacy:
        known = {p.get("hash") for p in items}
        for h, v in legacy.items():
            if h in known or not isinstance(v, dict):
                continue
            items.append({
                "hash": h,
                "title": v.get("title", ""),
                "origin": v.get("origem", ""),
                "due": v.get("due", ""),
                "ts": v.get("at", ""),
                "status": "pending",
            })
        _save_proposals(items)
        save_state(state)
        log(f"proposals migrated from state: {len(legacy)}")
    return items


def _save_proposals(items: list[dict]) -> None:
    try:
        _atomic_write(PROPOSALS_PATH, json.dumps(items, ensure_ascii=False, indent=2) + "\n")
    except Exception as e:
        log(f"proposals save failed: {e}")


def _prune_proposals(state: dict) -> list[dict]:
    items = _load_proposals(state)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=PROPOSAL_TTL_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    kept = [p for p in items if (p.get("ts") or "") >= cutoff]
    if len(kept) != len(items):
        _save_proposals(kept)
    return kept


def propose_task(title, origem: str, state: dict, due: str = "") -> str | None:
    title = _as_text(title).strip()
    if not title:
        return None
    props = _prune_proposals(state)
    h = _proposal_hash(title)
    if any(p.get("hash") == h for p in props):
        log(f"proposal skipped (já proposta <{PROPOSAL_TTL_DAYS}d): {h} [{title[:40]}]")
        return None
    owner = _pending_title_owner(title, skip_id="")
    if owner:
        log(f"proposal skipped (task pendente {owner} com mesmo título): [{title[:40]}]")
        return None
    if _recent_completed_match(title):
        log(f"proposal skipped (concluída recente): [{title[:40]}]")
        return None
    msg = f'🤔 detectei possível tarefa: "{title}" (de {origem or "?"}). Crio? responda: sim {h}'
    try:
        OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
        _atomic_write(OUTBOX_DIR / f"task-proposal-{h}.txt", msg + "\n")
    except Exception as e:
        log(f"proposal write failed [{title[:40]}]: {e}")
        return None
    props.append({
        "hash": h,
        "title": title,
        "origin": origem,
        "due": due,
        "ts": _now_z(),
        "status": "pending",
    })
    _save_proposals(props)
    log(f"proposal: task-proposal-{h}.txt [{title[:40]}]")
    return h


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
            at = _completed_at(t, fallback_modified=True)
            if at is not None and at >= cutoff:
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


CHAT_LIVE_ACTIVE_DAYS = 14
_JID_SHAPE_RE = re.compile(r"@(s\.whatsapp\.net|lid|g\.us)$", re.IGNORECASE)


def _label_unusable(label: str) -> bool:
    if not label or label.strip(" .") == "":
        return True
    if _JID_SHAPE_RE.search(label):
        return True
    return False


MATERIALIZE_TZ = ZoneInfo("America/Sao_Paulo")


def _materialize_if_due(store: dict, state: dict) -> None:
    today = datetime.now(MATERIALIZE_TZ).strftime("%Y-%m-%d")
    if state.get("last_materialized_on") == today:
        log(f"materialize skipped — already ran on {today}")
        return
    materialize_chat_summaries(store)
    state["last_materialized_on"] = today
    save_state(state)


def materialize_chat_summaries(store: dict) -> int:
    chats = store.get("chats")
    if not isinstance(chats, dict):
        return 0
    cutoff = (datetime.now(timezone.utc) - timedelta(days=CHAT_LIVE_ACTIVE_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    date_iso = datetime.now().strftime("%Y-%m-%d")
    n = 0
    for chat_id, entry in chats.items():
        if not isinstance(entry, dict):
            continue
        if (entry.get("last_msg_ts") or "") < cutoff:
            continue
        summary = _as_text(entry.get("summary")).strip()
        label = _as_text(entry.get("label")).strip()
        if not summary or _label_unusable(label):
            if summary:
                log(f"chat summary skipped, unusable label [{chat_id}]: {label!r}")
            continue
        path = _find_person_block(label)
        if path is None:
            log(f"chat summary skipped, no canonical person block [{chat_id}]: {label!r}")
            continue
        if _read_layer(path.read_text(encoding="utf-8")) == "user":
            log(f"chat summary skipped, target is layer:user [{chat_id}]: {path.stem!r}")
            continue
        try:
            res = append_person_continuity(path.stem, label, summary.replace("\n", " ").strip(), "", date_iso)
            if res not in ("skip", "dup"):
                n += 1
        except Exception as e:
            log(f"chat summary materialize failed [{label[:30]}]: {e}")
    return n


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
        if not tid or action not in ("complete", "delete", "update"):
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
            task["completedAt"] = task["modifiedAt"]
            if not dry:
                _atomic_write(path, json.dumps(task, ensure_ascii=False))
            log(f"{'[dry] ' if dry else ''}task complete {tid}: {reason}")
        elif action == "update":
            if status == "completed":
                log(f"task_update update skipped — already completed: {tid}")
                continue
            new_title = _as_text(u.get("title")).strip()
            new_due = None
            due_raw = u.get("due")
            if isinstance(due_raw, str) and due_raw.strip():
                new_due = geo_write._normalize_anchor(due_raw.strip(), geo_write._LOCAL_TZ)
                if not new_due:
                    log(f"task_update update skipped (malformed due) {tid}: {due_raw!r}")
                    continue
                try:
                    due_dt = datetime.fromisoformat(new_due.replace("Z", "+00:00"))
                except Exception:
                    due_dt = None
                now_local = datetime.now(_local_tz())
                if due_dt is not None and due_dt < now_local:
                    eod = _end_of_day_local(now_local.year, now_local.month, now_local.day)
                    if eod < now_local:
                        eod = eod + timedelta(days=1)
                    clamped = eod.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    log(f"task_update update due no passado, clampado {tid}: {new_due} → {clamped}")
                    new_due = clamped
            if not new_title and not new_due:
                log(f"task_update update skipped (no title/due): {tid}")
                continue
            body = task.get("body")
            if new_due and (not isinstance(body, dict) or body.get("kind") != "task"):
                log(f"task_update update skipped (not a task kind) {tid}")
                continue
            if new_title:
                dup = _pending_title_owner(new_title, tid)
                if dup:
                    log(f"task_update update skipped (title já pendente em {dup}): {tid}")
                    continue
                task["title"] = new_title
            if new_due:
                body["due"] = new_due
                reminders = [r for r in (task.get("reminders") or []) if isinstance(r, dict)]
                if any((r.get("trigger") or {}).get("kind") == "absolute" for r in reminders):
                    task["reminders"] = tasks_fs._default_reminders(body)
                else:
                    task["reminders"] = [{**r, "fired": False} for r in reminders]
            task["modifiedAt"] = _now_z()
            if not dry:
                _atomic_write(path, json.dumps(task, ensure_ascii=False))
            log(f"{'[dry] ' if dry else ''}task update {tid} (title={new_title or '—'} due={new_due or '—'}): {reason}")
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


def _append_expired_review(new_lines: list[str]) -> None:
    if not new_lines:
        return
    if EXPIRED_REVIEW_PATH.exists():
        text = EXPIRED_REVIEW_PATH.read_text(encoding="utf-8")
        m = re.search(r"^id:\s*(\S+)", text, re.MULTILINE)
        block_id = m.group(1) if m else str(uuid.uuid4()).upper()
        existing = [l for l in text.splitlines() if l.startswith("- ")]
    else:
        block_id = str(uuid.uuid4()).upper()
        existing = []
    existing.extend(new_lines)
    fm = f"---\nid: {block_id}\ntype: fleeting\nlayer: review\n---\n"
    body = "# Tasks expiradas\nParte de [[MOC — Rotina]]\n\n" + "\n".join(existing) + "\n"
    _atomic_write(EXPIRED_REVIEW_PATH, fm + body)


def expire_stale_tasks(dry: bool, now: datetime | None = None) -> list[dict]:
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(days=TASK_EXPIRY_DAYS)
    today = now.strftime("%Y-%m-%d")
    expired: list[dict] = []
    review_lines: list[str] = []
    for f in sorted(TASKS_DIR.glob("*.json")):
        if ".sync-conflict-" in f.name:
            continue
        try:
            t = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        if t.get("status") != "pending":
            continue
        body = t.get("body")
        if not isinstance(body, dict) or body.get("kind") != "task":
            continue
        due_raw = body.get("due")
        if not isinstance(due_raw, str) or not due_raw.strip():
            continue
        try:
            due_dt = datetime.fromisoformat(due_raw.replace("Z", "+00:00"))
        except Exception:
            continue
        if due_dt.tzinfo is None:
            due_dt = due_dt.replace(tzinfo=timezone.utc)
        else:
            due_dt = due_dt.astimezone(timezone.utc)
        if due_dt >= cutoff:
            continue
        tid = _as_text(t.get("id")).strip()
        title = _as_text(t.get("title")).strip()
        due_day = due_dt.strftime("%Y-%m-%d")
        review_lines.append(f"- {today} · {title} (due {due_day}) · {tid}")
        if not dry:
            EXPIRED_DIR.mkdir(parents=True, exist_ok=True)
            os.replace(f, EXPIRED_DIR / f.name)
        log(f"{'[dry] ' if dry else ''}task expired {tid}: due {due_day} < now-{TASK_EXPIRY_DAYS}d")
        expired.append({"id": tid, "title": title, "due": due_day})
    if not dry:
        _append_expired_review(review_lines)
    return expired


async def persist(decided: dict, state: dict | None = None) -> dict:
    blocks = decided.get("blocks") or []
    tasks = decided.get("tasks") or []
    urgent = decided.get("urgent") or []
    date_iso = datetime.now().strftime("%Y-%m-%d")
    stats = {"blocks_created": 0, "blocks_appended": 0, "blocks_capped": 0,
             "dedup_skips": 0, "tasks_created": 0, "tasks_capped": 0,
             "tasks_proposed": 0, "urgent": 0, "task_mutations": 0}
    descartes_lines: list[str] = []

    for b in blocks:
        title = _as_text(b.get("title")).strip()
        if not title:
            continue
        if _is_generic_title(title):
            log(f"block discarded (generic title): {title[:60]!r}")
            continue
        body = _as_text(b.get("body"))
        if stats["blocks_created"] >= MAX_BLOCKS_PER_RUN:
            descartes_lines.append(f"bloco não criado (cap): {title}")
            stats["blocks_capped"] += 1
            log(f"block capped (>{MAX_BLOCKS_PER_RUN}/run): {title[:60]!r}")
            continue
        try:
            rid = write_block_file(title, body, b.get("type") or "fleeting", b.get("layer") or "review")
            stats["blocks_created"] += 1
            log(f"block: {rid}")
        except GeoError as e:
            kind, ref = _classify_block_dup(str(e))
            if kind == "title" and ref:
                try:
                    ares = geo_write.append_block(writer=WRITER, block_path_or_id=ref, lines=body or title)
                    stats["blocks_appended"] += 1
                    log(f"block appended (title collision) → {ares.get('path')}")
                except Exception as ae:
                    log(f"block append failed [{title[:40]}]: {ae}")
            elif kind == "simhash":
                descartes_lines.append(f"bloco dedup (simhash): {title}")
                stats["dedup_skips"] += 1
                log(f"block dedup-skipped (simhash) [{title[:40]}]")
            else:
                log(f"block write rejected [{title[:40]}]: {e}")
        except Exception as e:
            log(f"block write failed [{title[:40]}]: {e}")

    for t in tasks:
        title = _as_text(t.get("title")).strip()
        if not title:
            continue
        due = t.get("due")
        if _as_text(t.get("confidence")).strip().lower().startswith("ambig"):
            if state is None:
                log(f"task ambígua sem state — descartada: {title[:60]!r}")
                continue
            if stats["tasks_proposed"] >= MAX_PROPOSALS_PER_RUN:
                descartes_lines.append(f"proposta não enviada (cap): {title}")
                log(f"proposal capped (>{MAX_PROPOSALS_PER_RUN}/run): {title[:60]!r}")
                continue
            if propose_task(title, _as_text(t.get("origem")).strip(), state, due=_as_text(due).strip()):
                stats["tasks_proposed"] += 1
            continue
        if stats["tasks_created"] >= MAX_TASKS_PER_RUN:
            descartes_lines.append(f"task não criada (cap): {title} (due {_as_text(due) or '—'})")
            stats["tasks_capped"] += 1
            log(f"task capped (>{MAX_TASKS_PER_RUN}/run): {title[:60]!r}")
            continue
        try:
            rid, created = write_task_file(title, due)
            if created:
                stats["tasks_created"] += 1
            else:
                stats["dedup_skips"] += 1
            log(f"task: {rid} [{title[:40]}]{'' if created else ' (dedup skip)'}")
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
    social = [_as_text(x).strip() for x in (d.get("social") or []) if _as_text(x).strip()]
    if social or people_lines or descartes_lines:
        try:
            log(f"digest: {upsert_daily_digest(date_iso, people_lines, social, descartes_lines)}")
        except Exception as e:
            log(f"digest write failed: {e}")

    mutated = apply_task_updates(decided.get("task_updates") or [], dry=False)
    stats["urgent"] = len(urgent)
    stats["task_mutations"] = len(mutated)
    return stats


async def run_whatsapp() -> int:
    dry = "--dry-run" in sys.argv
    token = load_oauth_token()
    if not token:
        log(f"nenhuma credencial anthropic utilizável — semear {AUTH_PATH.name}")
        return 1

    state = load_state()
    store = load_chats()
    watermark = state.get("last_processed_ts")
    known_chat_ids = set((store.get("chats") or {}).keys())
    scan = scan_wa_jsonl(watermark, state.get("boundary_msg_ids"), known_chat_ids)
    records = scan["new"]
    context_by_chat = scan["context"]
    bootstrap_by_chat = scan["bootstrap"]
    email_uids = _email_uids(state)
    email_scan = scan_email_jsonl(email_uids)
    email_records = email_scan["new"]
    buckets = bucket_by_chat(records, context_by_chat) + bucket_by_account(email_records)
    log(f"window_hours={WINDOW_HOURS} watermark_set={int(bool(watermark))} wa_new={len(records)} "
        f"email_window_hours={EMAIL_WINDOW_HOURS} email_accounts={len(email_uids)} "
        f"email_new={len(email_records)} buckets={len(buckets)} dry_run={int(dry)}")
    ctx_buckets = [b for b in buckets if b.get("source") != "email"]
    log(f"context: lookback={CONTEXT_LOOKBACK_HOURS}h caps={CONTEXT_MAX_MSGS}msgs/{CONTEXT_MAX_CHARS}chars "
        f"chats_with_context={sum(1 for b in ctx_buckets if b.get('context'))} "
        f"msgs={sum(len(b.get('context') or []) for b in ctx_buckets)}")
    if not buckets:
        print("[context-scraping] no messages in window")
        return 0

    headers = _headers_oauth(token)
    sem = asyncio.Semaphore(MAX_CONCURRENT)

    async with httpx.AsyncClient() as http:
        await enrich_window_media(records, http, headers)

        prior_summaries = {
            cid: (entry or {}).get("summary") or ""
            for cid, entry in (store.get("chats") or {}).items()
        }

        async def gated(bucket: dict) -> dict:
            async with sem:
                return await classify_bucket(
                    http, headers, bucket, prior_summaries.get(bucket["chat_id"], "")
                )

        results = await asyncio.gather(*(gated(b) for b in buckets), return_exceptions=True)
        successful = [
            (bucket, result)
            for bucket, result in zip(buckets, results)
            if isinstance(result, dict)
        ]
        failed = [
            (bucket, result)
            for bucket, result in zip(buckets, results)
            if isinstance(result, BaseException)
        ]
        for bucket, exc in failed:
            log(f"CLASSIFY failed [{bucket['chat_id']}]: {type(exc).__name__}: {exc}")
        if failed and any(_auth_error_from_response(exc) for _, exc in failed):
            log("HINT: Check OAuth credentials")
        if results and not successful:
            log(f"all {len(results)} buckets errored — no classification happened")
            return 1

        keep = [result for _, result in successful if has_proposals(result)]
        log(f"classify: with_proposals={len(keep)} errored={len(failed)}")

        successful_wa_ids = {
            bucket["chat_id"] for bucket, _ in successful
            if bucket.get("source") != "email"
        }
        failed_wa_ids = {
            bucket["chat_id"] for bucket, _ in failed
            if bucket.get("source") != "email"
        }
        failed_email = any(bucket.get("source") == "email" for bucket, _ in failed)
        watermark_records = [
            record for record in records
            if (record.get("chat") or "") in successful_wa_ids
        ]
        if failed_wa_ids:
            failed_records = [
                record for record in records
                if (record.get("chat") or "") in failed_wa_ids
            ]
            if failed_records:
                first_failed_ts = min(
                    _parse_utc_ts(record.get("timestamp") or record.get("ts"))
                    for record in failed_records
                )
                watermark_records = [
                    record for record in watermark_records
                    if _parse_utc_ts(record.get("timestamp") or record.get("ts")) <= first_failed_ts
                ]
            else:
                watermark_records = []

        chat_buckets = [
            bucket for bucket, _ in successful
            if bucket.get("source") != "email"
        ]
        ctx, summary_ok = await update_chat_summaries(
            http, headers, sem, chat_buckets, store, bootstrap_by_chat
        )
        advance_ok = summary_ok
        if not keep:
            print("[context-scraping] classifier surfaced nothing")
            if not dry:
                _advance_watermark(state, watermark_records)
                if not failed_email:
                    _advance_email_watermark(state, email_records)
                save_chats(store)
                _materialize_if_due(store, state)
            return 0

        brain_context = render_brain_context()
        tasks_context = _recent_tasks_context()
        decided, decide_ok = await decide(http, headers, keep, brain_context, ctx, tasks_context)
    log(
        f"decided: blocks={len(decided.get('blocks', []))} "
        f"tasks={len(decided.get('tasks', []))} "
        f"tasks_ambiguas={sum(1 for t in decided.get('tasks', []) if isinstance(t, dict) and _as_text(t.get('confidence')).strip().lower().startswith('ambig'))} "
        f"urgent={len(decided.get('urgent', []))} "
        f"task_updates={len(decided.get('task_updates', []))} "
        f"calls={_usage_totals['calls']} in={_usage_totals['input_tokens']} out={_usage_totals['output_tokens']}"
    )

    if dry:
        apply_task_updates(decided.get("task_updates") or [], dry=True)
        expire_stale_tasks(dry=True)
        print(json.dumps(decided, ensure_ascii=False, indent=2))
        return 0

    stats = await persist(decided, state)
    ne = len(expire_stale_tasks(dry=False))
    if advance_ok and decide_ok:
        _advance_watermark(state, watermark_records)
        if not failed_email:
            _advance_email_watermark(state, email_records)
        save_chats(store)
    else:
        log("watermark/chats not advanced (classify/summary/decide error) — overlapping retry next cycle")
    _materialize_if_due(store, state)
    print(
        f"[context-scraping] persisted blocks_created={stats['blocks_created']} "
        f"blocks_appended={stats['blocks_appended']} blocks_capped={stats['blocks_capped']} "
        f"dedup_skips={stats['dedup_skips']} tasks_created={stats['tasks_created']} "
        f"tasks_proposed={stats['tasks_proposed']} "
        f"tasks_capped={stats['tasks_capped']} urgent_dm={stats['urgent']} "
        f"task_mutations={stats['task_mutations']} expired={ne}"
    )
    return 0


def _require_mount() -> bool:
    try:
        r = subprocess.run(["mountpoint", "-q", str(GARIME_MOUNT)], timeout=10)
        return r.returncode == 0
    except Exception as e:
        log(f"mountpoint check failed: {e}")
        return False


async def main(source: str = "whatsapp") -> int:
    if not _require_mount():
        log(f"{GARIME_MOUNT} not mounted — aborting")
        return 1
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
