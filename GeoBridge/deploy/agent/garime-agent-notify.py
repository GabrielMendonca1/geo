#!/usr/bin/env python3
"""Push de fim de task: quando o agente sai de 'trabalhando' para 'ocioso' após um
período real de trabalho, manda um resumo pelo WhatsApp (wa-outbox do sidecar)."""
import glob
import json
import os
import subprocess
import sys
import time

ENV_FILE = os.environ.get("GARIME_AGENT_ENV", "/opt/garime/agent/agent.env")
if os.path.exists(ENV_FILE):
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())

SESSIONS_DIR = os.environ["GARIME_AGENT_SESSION_DIR"]
SESSION = os.environ.get("GARIME_AGENT_SESSION", "garime-agent")
OUTBOX = os.path.expanduser("~/.pi/wa-outbox")
STATE = os.environ.get("NOTIFY_STATE", "/var/tmp/garime-agent-notify.json")
FRESH = 30          # s: transcript escrito há menos que isso = trabalhando (status)
GRACE = 180         # s: tolerância de 'ainda trabalhando' pro push (tools longas geram silêncio)
MIN_WORK = 90       # s: só notifica se trabalhou ao menos isso
COOLDOWN = 600      # s: entre notificações de fim de task
ASK_COOLDOWN = 900  # s: entre pushes de pergunta


def asking_question():
    """Detecta dialog aberto no pane do agente; devolve dict do ask ou None."""
    try:
        os.environ.setdefault("GEO_TERM_TMUX", os.environ.get("GARIME_AGENT_TMUX", "/usr/bin/tmux"))
        if "/opt/garime" not in sys.path:
            sys.path.insert(0, "/opt/garime")
        import geobridge as g
        text = g.agent_ask_capture(SESSION)
        if text is None:
            return None
        info = g.agent_ask_parse(text)
        if isinstance(info, dict) and info.get("asking") and (info.get("question") or info.get("raw_hint")):
            return info
    except Exception:
        pass
    return None


def newest_jsonl():
    files = glob.glob(os.path.join(SESSIONS_DIR, "*.jsonl"))
    if not files:
        return None, None
    path = max(files, key=os.path.getmtime)
    return path, os.path.getmtime(path)


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {"working_since": None, "notified_at": 0}


def save_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def last_assistant_text(path):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 65536))
            tail = f.read().decode("utf-8", "replace")
        texts = []
        for line in tail.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            msg = entry.get("message") or entry
            if msg.get("role") == "assistant":
                content = msg.get("content")
                if isinstance(content, str) and content.strip():
                    texts.append(content.strip())
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            t = (block.get("text") or "").strip()
                            if t:
                                texts.append(t)
        return texts[-1] if texts else ""
    except Exception:
        return ""


def main() -> int:
    os.makedirs(OUTBOX, exist_ok=True)
    path, mtime = newest_jsonl()
    now = time.time()
    working = bool(mtime and now - mtime <= FRESH)
    # pro push, silêncio de transcript até GRACE não conta como fim de task
    working_for_notify = bool(mtime and now - mtime <= GRACE)

    state = load_state()

    # push de pergunta: agente preso num dialog esperando resposta
    ask = asking_question() if not working_for_notify else None
    if ask is None:
        state["ask_active"] = False
    elif now - state.get("asked_at", 0) > ASK_COOLDOWN:
        q = " ".join(str(ask.get("question") or ask.get("raw_hint") or "").split())[:300]
        name = time.strftime("agent-ask-%Y%m%d-%H%M%S.txt")
        try:
            with open(os.path.join(OUTBOX, name), "w") as f:
                f.write("❓ garime-agent perguntou:\n" + q)
            state["asked_at"] = now
            state["ask_active"] = True
        except OSError:
            pass

    if working_for_notify:
        if state.get("working_since") is None:
            state["working_since"] = now
        state["last_busy"] = now
        save_state(state)
        return 0

    since = state.pop("working_since", None)
    state["working_since"] = None
    worked_for = (state.get("last_busy", now)) - since if since else 0
    if since and worked_for >= MIN_WORK and now - state.get("notified_at", 0) > COOLDOWN:
        snippet = last_assistant_text(path) if path else ""
        snippet = " ".join(snippet.split())
        if len(snippet) > 350:
            snippet = snippet[:347] + "…"
        body = "✅ garime-agent terminou (%dmin)\n" % round(worked_for / 60)
        body += snippet if snippet else "(sem texto final no transcript)"
        name = time.strftime("agent-done-%Y%m%d-%H%M%S.txt")
        try:
            with open(os.path.join(OUTBOX, name), "w") as f:
                f.write(body)
            state["notified_at"] = now
        except OSError:
            pass
    save_state(state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
