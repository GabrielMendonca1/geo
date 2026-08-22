#!/usr/bin/env python3
"""Contract harness for the single always-on agent routes of GeoBridge.

Encodes the TARGET contract:
  - `GET /term/health` is the combined status of the home: `mac_online` (TCP
    probe) plus the state of the fixed tmux session `GEO_AGENT_SESSION`. It is
    read-only, never spawns, and never 5xxs — tmux down is `running:false`.
  - `POST /term/agent-ensure` always targets `GEO_AGENT_SESSION`; the client
    cannot choose the session, and an existing session is reused, never
    duplicated. It guarantees the session, not the `pi` inside it.
  - Both routes sit behind the same gate as the rest of `/term/*`: disabled →
    404, wrong term token → 401.
  - The pre-existing routes (`/term/list`, `/term/agents`) keep their exact
    payload shape.

Run: python3 tests/bridge_agent_contract.py   (exit 0 = all cases green)
Targets the SOURCE copy of GeoBridge/geobridge.py.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "GeoBridge" / "geobridge.py"
TERM_TOKEN = "term-token-de-teste"

FAILS: list[str] = []


def check(name: str, got, want) -> None:
    ok(name, got == want, f"got={got!r} want={want!r}")


def ok(name: str, cond: bool, detail: str = "") -> None:
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}{(': ' + detail) if detail else ''}")
    if not cond:
        FAILS.append(name)


def load_bridge():
    os.environ["GEO_TERM_ENABLED"] = "1"
    spec = importlib.util.spec_from_file_location("geobridge_under_test", SOURCE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.TOKEN = "token-geral-de-teste"
    mod.TERM_TOKEN = TERM_TOKEN
    mod.TERM_ENABLED = True
    mod.TERM_TMUX = "/nonexistent/tmux"
    mod.LOG_PATH = os.path.join(tempfile.mkdtemp(), "geobridge.log")
    mod.STATUS_UNITS = []
    mod.status_mac_online = lambda: True
    mod.status_agents = lambda: []
    mod.vm_session_agent = lambda session: None
    return mod


def request(port, path, method="GET", token=TERM_TOKEN):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method)
    if method == "POST":
        req.data = b""
    if token is not None:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


def case_gate(mod, port):
    print("\n== gate do term token")
    check("health sem token", request(port, "/term/health", token=None)[0], 401)
    check("health com token errado", request(port, "/term/health", token="nao")[0], 401)
    check("ensure sem token", request(port, "/term/agent-ensure", "POST", token=None)[0], 401)
    mod.TERM_ENABLED = False
    check("health com /term/* desligado", request(port, "/term/health")[0], 404)
    check("ensure com /term/* desligado", request(port, "/term/agent-ensure", "POST")[0], 404)
    mod.TERM_ENABLED = True


def case_health_shape(mod, port):
    print("\n== /term/health")
    mod.status_mac_online = lambda: True
    mod.vm_session_agent = lambda session: ("pi", "/mnt/garime/Vault")
    status, body = request(port, "/term/health")
    check("codigo", status, 200)
    check("chaves", sorted(body), ["agent", "mac_online", "ok"])
    check("agent", body["agent"], {"session": "garime-agent", "running": True, "agent": "pi", "busy": False})
    check("mac_online", body["mac_online"], True)
    ok("sem campo vm_online", "vm_online" not in body, "o 200 e o sinal da VM")

    mod.status_mac_online = lambda: False
    mod.vm_session_agent = lambda session: ("", "")
    _, body = request(port, "/term/health")
    check("sessao sem agente", body["agent"], {"session": "garime-agent", "running": False, "agent": ""})
    check("mac offline", body["mac_online"], False)


def case_health_never_5xx(mod, port):
    print("\n== /term/health nunca 5xx")
    mod.status_mac_online = lambda: True

    def boom(session):
        raise OSError("tmux morto")

    mod.vm_session_agent = boom
    status, body = request(port, "/term/health")
    check("tmux morto -> codigo", status, 200)
    check("tmux morto -> running", body["agent"]["running"], False)

    mod.vm_session_agent = lambda session: None
    _, body = request(port, "/term/health")
    check("sessao ausente -> running", body["agent"]["running"], False)


def case_ensure_fixed_session(mod, port):
    print("\n== /term/agent-ensure")
    seen: list[str] = []
    mod.vm_session_agent = lambda session: None

    original = mod.Handler._term_session
    mod.Handler._term_session = lambda self, session: seen.append(session)
    status, body = request(port, "/term/agent-ensure", "POST")
    check("codigo", status, 200)
    check("sessao usada", seen, ["garime-agent"])
    check("corpo", body, {"ok": True, "agent": {"session": "garime-agent", "running": False, "agent": ""}})

    seen.clear()
    request(port, "/term/agent-ensure?session=mobile", "POST")
    check("param session e ignorado", seen, ["garime-agent"])

    def boom(self, session):
        raise OSError("sem pty")

    mod.Handler._term_session = boom
    status, body = request(port, "/term/agent-ensure", "POST")
    check("spawn falhou", (status, body), (503, {"error": "unavailable"}))
    mod.Handler._term_session = original


def case_ensure_reuses_session(mod, port):
    print("\n== /term/agent-ensure reusa a sessao")
    calls: list[tuple] = []

    class FakeSession:
        alive = True

    original = mod.term_get_or_spawn
    mod.term_get_or_spawn = lambda session, *a, **kw: (calls.append((session, a)), FakeSession())[1]
    mod.TERM_REGISTRY.clear()
    request(port, "/term/agent-ensure", "POST")
    check("spawn na primeira chamada", [c[0] for c in calls], ["garime-agent"])
    mod.TERM_REGISTRY["garime-agent"] = FakeSession()
    request(port, "/term/agent-ensure", "POST")
    check("sessao viva nao respawna", len(calls), 1)
    mod.TERM_REGISTRY.clear()
    mod.term_get_or_spawn = original


def case_existing_routes(mod, port):
    print("\n== rotas antigas intactas")
    status, body = request(port, "/term/agents")
    check("agents codigo", status, 200)
    check("agents chaves", sorted(body), ["agents", "mac_online", "units"])
    status, body = request(port, "/term/list")
    check("list codigo", status, 200)
    check("list chaves", sorted(body), ["sessions"])
    check("health geral sem auth", request(port, "/health", token=None), (200, {"ok": True}))


def main() -> int:
    print(f"source={SOURCE}")
    if not SOURCE.exists():
        print("  [FAIL] geobridge.py ausente")
        return 1
    mod = load_bridge()
    check("default de GEO_AGENT_SESSION", mod.AGENT_SESSION, "garime-agent")
    server = ThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        case_gate(mod, port)
        case_health_shape(mod, port)
        case_health_never_5xx(mod, port)
        case_ensure_fixed_session(mod, port)
        case_ensure_reuses_session(mod, port)
        case_existing_routes(mod, port)
    finally:
        server.shutdown()
        server.server_close()
    print(f"\n{'='*48}\n{len(FAILS)} failing case(s): {FAILS or 'none'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
