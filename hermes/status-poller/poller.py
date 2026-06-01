"""
Status poller — writes ~/.hermes/status.json every 10s so Geo.app's dashboard
chips reflect reality. Reads launchctl, .env, and recent file activity to
derive {provider, channels: {telegram, whatsapp, gmail}}.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path

HERMES_HOME = Path(os.path.expanduser("~/.hermes"))
STATUS_PATH = HERMES_HOME / "status.json"
ENV_PATH = HERMES_HOME / ".env"
CONFIG_PATH = HERMES_HOME / "config.yaml"
WA_JSONL = HERMES_HOME / "wa_ingest.jsonl"
GATEWAY_LOG = HERMES_HOME / "logs" / "gateway.log"
JOBS_FILE = HERMES_HOME / "cron" / "jobs.json"

GATEWAY_LABEL = "ai.hermes.gateway"
WA_INGEST_LABEL = "ai.hermes.whatsapp-ingest"

FRESH_WINDOW_SECONDS = 600.0
POLL_INTERVAL = 10.0


def launchctl_running(label: str) -> bool:
    try:
        proc = subprocess.run(
            ["launchctl", "list", label],
            capture_output=True, text=True, timeout=5,
        )
        if proc.returncode != 0:
            return False
        m = re.search(r'"PID"\s*=\s*(\d+);', proc.stdout)
        return bool(m and int(m.group(1)) > 0)
    except Exception:
        return False


def parse_env() -> dict:
    if not ENV_PATH.exists():
        return {}
    out = {}
    for raw in ENV_PATH.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def parse_provider() -> str:
    if not CONFIG_PATH.exists():
        return "anthropic"
    text = CONFIG_PATH.read_text(errors="replace")
    m = re.search(r'^\s*provider:\s*"?([\w-]+)"?', text, re.MULTILINE)
    if m:
        return m.group(1)
    return "anthropic"


def mtime_ms(path: Path) -> float | None:
    try:
        return path.stat().st_mtime * 1000.0
    except FileNotFoundError:
        return None


def telegram_state(env: dict, gateway_up: bool) -> dict:
    has_token = bool(env.get("TELEGRAM_BOT_TOKEN"))
    if not has_token:
        return {"state": "disconnected", "detail": "no TELEGRAM_BOT_TOKEN"}
    if not gateway_up:
        return {"state": "disconnected", "detail": "gateway down"}
    log_mtime = mtime_ms(GATEWAY_LOG)
    last_seen = None
    if log_mtime and (time.time() - log_mtime / 1000.0) < FRESH_WINDOW_SECONDS:
        last_seen = log_mtime
    return {
        "state": "connected",
        "identity": env.get("TELEGRAM_HOME_CHANNEL") or "telegram",
        "detail": "polling",
        "last_seen_ms": last_seen,
    }


def whatsapp_state() -> dict:
    if not launchctl_running(WA_INGEST_LABEL):
        return {"state": "disconnected", "detail": "ingest sidecar down"}
    jsonl_mtime = mtime_ms(WA_JSONL)
    if jsonl_mtime is None:
        return {
            "state": "connecting",
            "detail": "no messages yet",
            "identity": "WhatsApp (read-only)",
        }
    return {
        "state": "connected",
        "identity": "WhatsApp (read-only)",
        "detail": "sidecar ingest",
        "last_seen_ms": jsonl_mtime,
    }


def gmail_state(env: dict, gateway_up: bool) -> dict:
    has_creds = bool(env.get("GMAIL_OAUTH_TOKEN") or env.get("GOOGLE_REFRESH_TOKEN"))
    if not has_creds:
        return {"state": "connecting", "detail": "Gmail not configured"}
    if not gateway_up:
        return {"state": "disconnected", "detail": "gateway down"}
    return {"state": "connected", "detail": "via hermes gateway"}


def load_crons() -> list:
    if not JOBS_FILE.exists():
        return []
    try:
        raw = json.loads(JOBS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []
    if isinstance(raw, dict):
        raw = raw.get("jobs") or raw.get("items") or []
    if not isinstance(raw, list):
        return []
    out = []
    for job in raw:
        if not isinstance(job, dict):
            continue
        schedule = job.get("schedule") or {}
        if isinstance(schedule, dict):
            schedule_display = (
                schedule.get("display")
                or schedule.get("value")
                or schedule.get("cron")
                or ""
            )
        else:
            schedule_display = str(schedule)
        out.append({
            "id": job.get("id", ""),
            "title": job.get("title") or job.get("name") or job.get("id", ""),
            "schedule": schedule_display,
            "prompt": (job.get("prompt") or "")[:500],
            "enabled": bool(job.get("enabled", True)),
            "state": job.get("state") or ("scheduled" if job.get("enabled", True) else "paused"),
            "last_run_at": job.get("last_run_at"),
            "last_status": job.get("last_status") or "",
            "last_error": job.get("last_error"),
            "next_run_at": job.get("next_run_at"),
        })
    return out


def build_status() -> dict:
    env = parse_env()
    gateway_up = launchctl_running(GATEWAY_LABEL)
    return {
        "provider": parse_provider(),
        "gateway_running": gateway_up,
        "updated_at_ms": time.time() * 1000.0,
        "channels": {
            "telegram": telegram_state(env, gateway_up),
            "whatsapp": whatsapp_state(),
            "gmail": gmail_state(env, gateway_up),
        },
        "crons": load_crons(),
    }


def write_status(payload: dict) -> None:
    tmp = STATUS_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    tmp.replace(STATUS_PATH)


def main() -> None:
    STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            write_status(build_status())
        except Exception as e:
            print(f"[status-poller] error: {e}", flush=True)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
