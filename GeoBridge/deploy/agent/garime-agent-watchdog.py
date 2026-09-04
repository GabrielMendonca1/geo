#!/usr/bin/env python3
"""Watchdog do agente único: garante que a sessão tmux existe; se morreu, levanta de novo."""
import os
import subprocess
import sys

TMUX = os.environ.get("GARIME_AGENT_TMUX", "/usr/bin/tmux")
SESSION = os.environ.get("GARIME_AGENT_SESSION", "garime-agent")
SERVICE = "garime-agent.service"


def main() -> int:
    live = subprocess.run([TMUX, "has-session", "-t", SESSION], capture_output=True)
    if live.returncode == 0:
        return 0
    print(f"sessão {SESSION} morta — reativando {SERVICE}", file=sys.stderr)
    subprocess.run(["systemctl", "start", SERVICE], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
