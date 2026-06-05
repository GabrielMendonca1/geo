#!/usr/bin/env python3
"""
day-command.py — the /day Telegram command.

Fetches Gabriel's day record + open tasks (today and this week) from the Geo
app over its localhost HTTP API, asks the cheap NANO model (config.yaml
model.nano) to produce a short summary, one non-obvious insight, and a compact
task list, then sends the result to Gabriel's Telegram.

Standalone: meant to be run by hermes cron OR spawned via Bash when Gabriel
types "/day". It does NOT run inside the gateway process, so it talks to the
Telegram Bot API directly (TELEGRAM_BOT_TOKEN from ~/.hermes/.env) and reuses
hermes's Anthropic OAuth credential from auth.json — same pattern as
whatsapp-extractor.py. Run it with the hermes venv interpreter:

    /Users/biel/.hermes/hermes-agent/venv/bin/python \
        ~/.hermes/scripts/day-command.py
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from anthropic import AsyncAnthropic

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)
import geo_context

HERMES_HOME = Path(os.path.expanduser("~/.hermes"))
AUTH_PATH = HERMES_HOME / "auth.json"
ENV_PATH = HERMES_HOME / ".env"
CONFIG_PATH = Path(__file__).parent.parent / "config.yaml"

GABRIEL_TELEGRAM_CHAT_ID = "5225262193"
DEFAULT_TZ = "America/Sao_Paulo"

PER_CALL_TIMEOUT_S = 45.0
RETRY_ATTEMPTS = 2
RETRY_BACKOFF_S = 1.5
MAX_TOKENS_OUT = 1200

OAUTH_BETA = "oauth-2025-04-20"
CLAUDE_CODE_USER_AGENT = "claude-cli/2.1.152 (external, cli)"

PROMPT_TEMPLATE = """Você é o segundo cérebro do Gabriel. Hoje é {today} ({weekday}). Abaixo está o registro do dia dele no Geo (as intenções que ele escreveu) e as tarefas abertas. Produza um briefing curto, em português, voz direta, SEM markdown (nada de asteriscos, crases ou #), pronto para mandar no Telegram.

REGISTRO DO DIA (intenções/blocos vinculados):
{day_context}

TAREFAS ABERTAS HOJE:
{tasks_today}

TAREFAS ABERTAS ESTA SEMANA:
{tasks_week}

Responda EXATAMENTE neste formato (três seções, sem preâmbulo):

Resumo
<um parágrafo curto, 2 a 4 frases, do que o dia do Gabriel é>

Insight
<UMA ideia/ângulo não óbvio que ele provavelmente não considerou — conexão entre tarefas, risco escondido, sequência melhor, ou pergunta certa. Uma frase, sem fluff motivacional.>

Tarefas
Hoje:
- <tarefa> (<hora se houver>)
Semana:
- <tarefa> (<dia/hora se houver>)

Se uma lista estiver vazia, escreva "- nada aberto". Não invente tarefas nem fatos."""


def log(msg: str) -> None:
    print(f"[day-command] {msg}", file=sys.stderr, flush=True)


def _nano_model() -> str:
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


def _timezone() -> ZoneInfo:
    try:
        import yaml

        data = yaml.safe_load(CONFIG_PATH.read_text()) or {}
        tz = data.get("timezone") or DEFAULT_TZ
        return ZoneInfo(str(tz))
    except Exception:
        return ZoneInfo(DEFAULT_TZ)


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


def _token_from_auth_json() -> str | None:
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
        log(f"auth.json anthropic OAuth token expired (id={chosen.get('id')})")
    return chosen.get("access_token")


def _token_from_keychain() -> str | None:
    try:
        proc = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True,
            text=True,
            timeout=5.0,
        )
    except Exception as e:
        log(f"keychain lookup failed: {e}")
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        oauth = json.loads(proc.stdout.strip()).get("claudeAiOauth") or {}
    except Exception as e:
        log(f"keychain creds unparseable: {e}")
        return None
    exp = oauth.get("expiresAt")
    if exp and exp / 1000.0 < datetime.now(timezone.utc).timestamp() + 60:
        log("keychain anthropic OAuth token expired")
    return oauth.get("accessToken")


def load_oauth_token() -> str | None:
    return _token_from_auth_json() or _token_from_keychain()


def _fmt_anchor(anchor: str, tz: ZoneInfo) -> str:
    try:
        dt = datetime.fromisoformat(anchor.replace("Z", "+00:00")).astimezone(tz)
        return dt.strftime("%d/%m %H:%M")
    except Exception:
        return anchor


def _anchor_date(anchor: str, tz: ZoneInfo) -> str | None:
    try:
        dt = datetime.fromisoformat(anchor.replace("Z", "+00:00")).astimezone(tz)
        return dt.date().isoformat()
    except Exception:
        return None


def _fmt_tasks(tasks: list[dict], tz: ZoneInfo) -> str:
    if not tasks:
        return "(nenhuma)"
    lines = []
    for t in tasks:
        title = t.get("title") or t.get("id") or "?"
        anchor = t.get("anchor")
        kind = t.get("kind") or "task"
        when = f" — {_fmt_anchor(anchor, tz)}" if anchor else ""
        lines.append(f"- {title} [{kind}]{when}")
    return "\n".join(lines)


async def fetch_geo(geo) -> dict:
    client = await geo.GeoAPIClient.get_instance()
    tz = _timezone()
    today_str = datetime.now(tz).date().isoformat()

    day = None
    day_context = ""
    try:
        day = await client.get("/days/today")
    except Exception as e:
        log(f"days/today failed: {e}")

    if isinstance(day, dict) and day.get("block_ids"):
        try:
            blocks = await client.get("/blocks")
            by_id = {b["id"]: b.get("title") for b in blocks if isinstance(b, dict)}
        except Exception as e:
            log(f"blocks list failed: {e}")
            by_id = {}
        parts = []
        for bid in day.get("block_ids", []):
            title = by_id.get(bid)
            if not title:
                continue
            try:
                body = await client.get("/blocks/by-title", title=title)
                parts.append(_strip_frontmatter(body.get("markdown", "")))
            except Exception as e:
                log(f"block fetch failed ({title}): {e}")
        day_context = "\n\n".join(p for p in parts if p)

    today_tasks: list[dict] = []
    week_tasks: list[dict] = []
    try:
        week_tasks = await client.get("/tasks/upcoming", within_days=7) or []
        if not isinstance(week_tasks, list):
            week_tasks = []
    except Exception as e:
        log(f"tasks/upcoming failed: {e}")
    today_tasks = [
        t for t in week_tasks
        if isinstance(t, dict) and _anchor_date(t.get("anchor", ""), tz) == today_str
    ]

    await geo.GeoAPIClient.reset_instance()
    return {
        "tz": tz,
        "today_str": today_str,
        "day": day,
        "day_context": day_context,
        "today_tasks": today_tasks,
        "week_tasks": week_tasks,
    }


async def run_nano(token: str, model: str, geo_data: dict) -> str | None:
    tz = geo_data["tz"]
    now = datetime.now(tz)
    day_context = geo_data["day_context"] or "(o Gabriel ainda não registrou intenções hoje)"
    prompt = PROMPT_TEMPLATE.format(
        today=geo_data["today_str"],
        weekday=now.strftime("%A"),
        day_context=day_context,
        tasks_today=_fmt_tasks(geo_data["today_tasks"], tz),
        tasks_week=_fmt_tasks(geo_data["week_tasks"], tz),
    )
    client = AsyncAnthropic(
        auth_token=token,
        default_headers={
            "anthropic-beta": OAUTH_BETA,
            "user-agent": CLAUDE_CODE_USER_AGENT,
            "x-app": "cli",
        },
    )
    last_err = None
    for attempt in range(RETRY_ATTEMPTS + 1):
        try:
            resp = await asyncio.wait_for(
                client.messages.create(
                    model=model,
                    max_tokens=MAX_TOKENS_OUT,
                    messages=[{"role": "user", "content": prompt}],
                ),
                timeout=PER_CALL_TIMEOUT_S,
            )
            parts = [b.text for b in resp.content if getattr(b, "type", None) == "text"]
            return "".join(parts).strip() or None
        except asyncio.TimeoutError:
            last_err = f"timeout (attempt {attempt + 1})"
        except Exception as e:
            last_err = f"{type(e).__name__}: {str(e)[:160]} (attempt {attempt + 1})"
        if attempt < RETRY_ATTEMPTS:
            await asyncio.sleep(RETRY_BACKOFF_S * (attempt + 1))
    log(f"nano call failed: {last_err}")
    return None


async def send_telegram(text: str) -> bool:
    token = _read_env_value("TELEGRAM_BOT_TOKEN")
    if not token:
        log("no TELEGRAM_BOT_TOKEN — cannot send")
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


async def deliver(text: str) -> bool:
    if "--send" in sys.argv:
        return await send_telegram(text)
    print(text)
    return True


async def main() -> int:
    token = load_oauth_token()
    if not token:
        log("no anthropic OAuth token in auth.json — aborting")
        return 1

    try:
        geo = load_geo_client()
    except Exception as e:
        log(f"cannot load geo client: {e}")
        return 1

    try:
        geo_data = await fetch_geo(geo)
    except Exception as e:
        log(f"geo fetch failed (is Geo.app open?): {e}")
        await deliver("/day: não consegui ler o Geo agora. Abre o app e tenta de novo.")
        return 1

    model = _nano_model()
    log(
        f"model={model} today_tasks={len(geo_data['today_tasks'])} "
        f"week_tasks={len(geo_data['week_tasks'])} day_ctx_chars={len(geo_data['day_context'])}"
    )

    summary = await run_nano(token, model, geo_data)
    if not summary:
        await deliver("/day: o modelo falhou agora. Tenta de novo daqui a pouco.")
        return 1

    ok = await deliver(summary)
    log(f"sent={ok}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
