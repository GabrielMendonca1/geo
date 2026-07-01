"""In-process Haiku extraction for Geo brain search.

Reuses the Claude Max OAuth credential from the macOS Keychain (the store the
`claude` CLI owns) — the same proven path the whatsapp-extractor cron uses — to
call Haiku directly via the Anthropic SDK with no subprocess spawn. Given a
question and the full text of the top matched blocks, returns ONLY the facts
that answer the question, cited by block title. Returns None on any failure so
the caller can fall back to raw search results.
"""

from __future__ import annotations

import asyncio
import getpass
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

KEYCHAIN_SERVICE = "Claude Code-credentials"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_ENDPOINTS = (
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
)
TOKEN_EXPIRY_BUFFER_MS = 60_000
OAUTH_BETA = "oauth-2025-04-20"
CLAUDE_CODE_USER_AGENT = "claude-cli/2.1.152 (external, cli)"
AUTH_PATH = Path(os.path.expanduser("~/.hermes/auth.json"))
CONFIG_PATH = Path(os.path.expanduser("~/.hermes/config.yaml"))
MAX_TOKENS_OUT = 900
PER_CALL_TIMEOUT_S = 25.0


def _log(msg: str) -> None:
    print(f"[geo-haiku] {msg}", file=sys.stderr, flush=True)


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


def _keychain_read() -> Optional[dict]:
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as e:
        _log(f"keychain lookup failed: {e}")
        return None
    if out.returncode != 0:
        return None
    try:
        full = json.loads(out.stdout.strip())
    except Exception:
        return None
    return full if isinstance(full.get("claudeAiOauth"), dict) else None


def _keychain_write(full: dict) -> bool:
    try:
        blob = json.dumps(full)
        w = subprocess.run(
            ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
             "-a", getpass.getuser(), "-w", blob],
            capture_output=True, text=True, timeout=10,
        )
        return w.returncode == 0
    except Exception as e:
        _log(f"keychain write error: {e}")
        return False


def _refresh_oauth(refresh_token: str) -> Optional[dict]:
    body = urllib.parse.urlencode(
        {"grant_type": "refresh_token", "refresh_token": refresh_token,
         "client_id": OAUTH_CLIENT_ID}
    ).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded",
               "User-Agent": CLAUDE_CODE_USER_AGENT}
    for url in OAUTH_TOKEN_ENDPOINTS:
        try:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
            if data.get("access_token"):
                return data
        except Exception as e:
            _log(f"refresh at {url} failed: {type(e).__name__}: {str(e)[:120]}")
    return None


def _keychain_oauth_token() -> Optional[str]:
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
    refreshed = _refresh_oauth(refresh)
    if not refreshed:
        return access
    oauth["accessToken"] = refreshed["access_token"]
    oauth["refreshToken"] = refreshed.get("refresh_token", refresh)
    oauth["expiresAt"] = now_ms + int(refreshed.get("expires_in", 3600)) * 1000
    _keychain_write(full)
    return oauth["accessToken"]


def _authjson_oauth_token() -> Optional[str]:
    if not AUTH_PATH.exists():
        return None
    try:
        data = json.loads(AUTH_PATH.read_text(encoding="utf-8"))
    except Exception:
        return None
    pool = (data.get("credential_pool") or {}).get("anthropic") or []
    entries = [e for e in pool if isinstance(e, dict) and e.get("access_token")]
    if not entries:
        return None
    entries.sort(key=lambda e: (e.get("priority", 999), -(e.get("expires_at_ms") or 0)))
    return entries[0].get("access_token")


def load_oauth_token() -> Optional[str]:
    return _keychain_oauth_token() or _authjson_oauth_token()


RANK_PROMPT = """Você é o roteador semântico do cérebro do Gabriel. Dada a mensagem atual dele e um manifesto de blocks do Geo, escolha APENAS os blocks que provavelmente ajudam a responder/agir nesse turno.

Regras:
- Entenda sinônimos e contexto, não só palavras iguais.
- Seja conservador: retorne no máximo {limit} blocks.
- Se nada tiver relação real, retorne [].
- Responda SOMENTE JSON estrito, sem markdown: {{"ids":["arquivo.md"]}}

Mensagem: {query}

Manifesto de blocks:
{manifest}"""

EXTRACT_PROMPT = """Você está consultando o "cérebro" do Gabriel — os blocks (notas) pessoais dele abaixo. Sua única tarefa: extrair APENAS o que responde à pergunta. Não resuma tudo, não invente nada fora dos blocks. Cite cada fato com o título do block entre [[colchetes duplos]]. Reproduza valores exatos (nomes, números, datas) literalmente. Se a resposta não estiver nos blocks, responda exatamente: "Não encontrei isso nos blocks do Gabriel." Seja telegráfico, sem preâmbulo, sem cabeçalhos markdown.

Pergunta: {query}

Blocks:
{context}"""


def _text_from_response(resp) -> str:
    return "".join(b.text for b in resp.content if getattr(b, "type", None) == "text").strip()


async def rank_blocks(query: str, candidates: list[dict], limit: int = 4) -> Optional[list[str]]:
    """Semantically pick relevant Geo block ids from a compact manifest.

    Uses the same Claude Max OAuth + model.nano path as whatsapp-extractor.
    Returns None on failure so caller can fall back to lexical ranking.
    """
    if not (query or "").strip() or not candidates:
        return None
    token = load_oauth_token()
    if not token:
        _log("no anthropic OAuth token (keychain/auth.json)")
        return None
    try:
        from anthropic import AsyncAnthropic
    except Exception as e:
        _log(f"anthropic sdk import failed: {e}")
        return None

    rows = []
    for c in candidates:
        rows.append(
            json.dumps(
                {
                    "id": c.get("id"),
                    "title": c.get("title"),
                    "excerpt": (c.get("excerpt") or "")[:260],
                },
                ensure_ascii=False,
            )
        )
    manifest = "\n".join(rows)
    prompt = RANK_PROMPT.format(query=query, manifest=manifest, limit=limit)
    client = AsyncAnthropic(
        auth_token=token,
        default_headers={
            "anthropic-beta": OAUTH_BETA,
            "user-agent": CLAUDE_CODE_USER_AGENT,
            "x-app": "cli",
        },
    )
    try:
        resp = await asyncio.wait_for(
            client.messages.create(
                model=_nano_model(),
                max_tokens=350,
                messages=[{"role": "user", "content": prompt}],
            ),
            timeout=PER_CALL_TIMEOUT_S,
        )
    except Exception as e:
        _log(f"rank_blocks failed: {type(e).__name__}: {str(e)[:160]}")
        return None
    text = _text_from_response(resp)
    try:
        raw = text.strip()
        if raw.startswith("```"):
            raw = raw.strip("`").strip()
            if raw.lower().startswith("json"):
                raw = raw[4:].strip()
        if "{" in raw and "}" in raw:
            raw = raw[raw.find("{"): raw.rfind("}") + 1]
        data = json.loads(raw)
        ids = data.get("ids") if isinstance(data, dict) else data
        if not isinstance(ids, list):
            return None
        known = {str(c.get("id")) for c in candidates}
        out = [str(x) for x in ids if str(x) in known]
        return out[:limit]
    except Exception as e:
        _log(f"rank_blocks non-json response: {e}: {text[:160]}")
        return None


async def extract(query: str, context_text: str) -> Optional[str]:
    if not (query or "").strip() or not (context_text or "").strip():
        return None
    token = load_oauth_token()
    if not token:
        _log("no anthropic OAuth token (keychain/auth.json)")
        return None
    try:
        from anthropic import AsyncAnthropic
    except Exception as e:
        _log(f"anthropic sdk import failed: {e}")
        return None
    client = AsyncAnthropic(
        auth_token=token,
        default_headers={
            "anthropic-beta": OAUTH_BETA,
            "user-agent": CLAUDE_CODE_USER_AGENT,
            "x-app": "cli",
        },
    )
    prompt = EXTRACT_PROMPT.format(query=query, context=context_text)
    try:
        resp = await asyncio.wait_for(
            client.messages.create(
                model=_nano_model(),
                max_tokens=MAX_TOKENS_OUT,
                messages=[{"role": "user", "content": prompt}],
            ),
            timeout=PER_CALL_TIMEOUT_S,
        )
    except Exception as e:
        _log(f"extract failed: {type(e).__name__}: {str(e)[:160]}")
        return None
    text = "".join(b.text for b in resp.content if getattr(b, "type", None) == "text").strip()
    return text or None
