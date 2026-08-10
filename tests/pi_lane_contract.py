#!/usr/bin/env python3
"""Contract harness for the DECIDE lane (context_scraping -> prime-agent).

Encodes the TARGET contract:
  - The lane is a single stateless `prime-agent -p` subprocess: no session, no
    tools, no skills/extensions/prompt-templates/context-files. The prompt is
    the only input, so two runs of the same window cannot influence each other.
  - Provider/model/effort default to openai-codex / gpt-5.6-sol / high and are
    each overridable (HERMES_WA_DECIDE_PROVIDER, _MODEL, _EFFORT).
  - The lane runs at most once per cycle, and only when CLASSIFY kept at least
    one proposal.
  - Every failure (timeout, rc!=0, empty stdout, non-JSON) surfaces as
    PiLaneError and propagates, so the watermark is not advanced and the next
    cycle reprocesses the window.

Run: python3 tests/pi_lane_contract.py   (exit 0 = all cases green)
Targets the SOURCE copies by default; override with GEO_SCRIPTS_DIR.
"""

from __future__ import annotations

import ast
import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from geo_time_contract import SCRIPTS_DIR, _load_extractor  # noqa: E402

SOURCE = SCRIPTS_DIR / "context_scraping.py"
DECIDE_ENV = ("HERMES_WA_DECIDE_PROVIDER", "HERMES_WA_DECIDE_MODEL", "HERMES_WA_DECIDE_EFFORT")
NANO_ENV = ("HERMES_NANO_MODEL",)

FAILS: list[str] = []


def check(name: str, got, want) -> None:
    ok = got == want
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: got={got!r} want={want!r}")
    if not ok:
        FAILS.append(name)


def ok(name: str, cond: bool, detail: str = "") -> None:
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}{(': ' + detail) if detail else ''}")
    if not cond:
        FAILS.append(name)


def _clear_env() -> None:
    for k in DECIDE_ENV + NANO_ENV:
        os.environ.pop(k, None)


class FakeProc:
    def __init__(self, rc: int = 0, out: bytes = b"", err: bytes = b"", hang: bool = False):
        self.returncode = rc
        self._out = out
        self._err = err
        self._hang = hang
        self.killed = False

    async def communicate(self):
        if self._hang:
            await asyncio.sleep(3600)
        return self._out, self._err

    def kill(self):
        self.killed = True

    async def wait(self):
        return self.returncode


class Spawn:
    """Stand-in for asyncio.create_subprocess_exec: records argv, returns a fake."""

    def __init__(self, proc_factory):
        self.calls: list[list[str]] = []
        self._factory = proc_factory
        self.last: FakeProc | None = None

    async def __call__(self, *argv, **kwargs):
        self.calls.append(list(argv))
        self.last = self._factory()
        return self.last


def _run(coro):
    return asyncio.run(coro)


def _expect_raises(fn, exc):
    try:
        _run(fn())
    except exc as e:
        return e
    except Exception as e:  # noqa: BLE001
        return e
    return None


def case_argv_default(wa) -> None:
    print("\n-- argv: hermetic + stateless by default --")
    _clear_env()
    argv = wa._pi_argv("PROMPT")
    check(
        "argv exact contract",
        argv,
        [
            wa.PI_BIN,
            "-p",
            "--no-session",
            "--no-tools",
            "--no-skills",
            "--no-context-files",
            "--no-extensions",
            "--no-prompt-templates",
            "--provider", "openai-codex",
            "--model", "gpt-5.6-sol",
            "--thinking", "high",
            "--", "PROMPT",
        ],
    )
    for banned in ("-c", "--continue", "--session-dir", "--resume", "--fork", "--cwd"):
        ok(f"argv omits {banned}", banned not in argv)
    ok("prompt is last and after --", argv[-1] == "PROMPT" and argv[-2] == "--")
    ok("no session state constants survive",
       not hasattr(wa, "PI_SESSION_DIR") and not hasattr(wa, "PI_CWD"))


def case_argv_overrides(wa) -> None:
    print("\n-- argv: env overrides --")
    _clear_env()
    os.environ["HERMES_WA_DECIDE_PROVIDER"] = "anthropic"
    os.environ["HERMES_WA_DECIDE_MODEL"] = "claude-opus-4-8"
    os.environ["HERMES_WA_DECIDE_EFFORT"] = "medium"
    argv = wa._pi_argv("P")
    check("provider override", argv[argv.index("--provider") + 1], "anthropic")
    check("model override", argv[argv.index("--model") + 1], "claude-opus-4-8")
    check("effort override", argv[argv.index("--thinking") + 1], "medium")

    _clear_env()
    os.environ["HERMES_WA_DECIDE_MODEL"] = "gpt-5.6-luna"
    argv = wa._pi_argv("P")
    check("model alone overrides, provider keeps default",
          (argv[argv.index("--model") + 1], argv[argv.index("--provider") + 1]),
          ("gpt-5.6-luna", "openai-codex"))

    for flag in ("--no-session", "--no-tools", "--no-skills",
                 "--no-context-files", "--no-extensions", "--no-prompt-templates"):
        ok(f"hermetic {flag} survives overrides", flag in argv)
    _clear_env()


def case_single_execution(wa) -> None:
    print("\n-- one execution per cycle --")
    _clear_env()
    spawn = Spawn(lambda: FakeProc(rc=0, out=b'{"blocks": [], "tasks": [], "urgent": []}'))
    real = asyncio.create_subprocess_exec
    asyncio.create_subprocess_exec = spawn
    try:
        kept = [{"chat": "x", "proposals": [{"kind": "fact", "text": "t"}]}]
        decided, decide_ok = _run(wa.decide(None, {}, kept, "", "", ""))
    finally:
        asyncio.create_subprocess_exec = real
    check("subprocess spawned exactly once", len(spawn.calls), 1)
    check("decide reports ok", decide_ok, True)
    check("decided shape", sorted(decided.keys())[:3], ["blocks", "digest", "people"])


def case_failures(wa) -> None:
    print("\n-- failure modes all become PiLaneError --")
    _clear_env()
    real = asyncio.create_subprocess_exec

    def run_with(proc_factory, timeout=5.0):
        spawn = Spawn(proc_factory)
        asyncio.create_subprocess_exec = spawn
        try:
            err = _expect_raises(lambda: wa._pi_complete("P", timeout), wa.PiLaneError)
        finally:
            asyncio.create_subprocess_exec = real
        return err, spawn

    err, spawn = run_with(lambda: FakeProc(hang=True), timeout=0.05)
    ok("timeout -> PiLaneError", isinstance(err, wa.PiLaneError), repr(err))
    ok("timeout message mentions excedeu", "excedeu" in str(err), str(err))
    ok("timed-out process is killed (no zombie on the LUKS mount)",
       spawn.last is not None and spawn.last.killed)

    err, _ = run_with(lambda: FakeProc(rc=1, err=b"boom stderr"))
    ok("rc!=0 -> PiLaneError", isinstance(err, wa.PiLaneError), repr(err))
    ok("rc!=0 message carries rc and stderr tail",
       "rc=1" in str(err) and "boom stderr" in str(err), str(err))

    err, _ = run_with(lambda: FakeProc(rc=0, out=b"   "))
    ok("empty stdout -> PiLaneError", isinstance(err, wa.PiLaneError), repr(err))
    ok("empty message mentions saida vazia", "saida vazia" in str(err), str(err))

    # invalid JSON is rejected one level up, in decide()
    spawn = Spawn(lambda: FakeProc(rc=0, out=b"desculpa, nao consegui decidir agora"))
    asyncio.create_subprocess_exec = spawn
    try:
        err = _expect_raises(lambda: wa.decide(None, {}, [{"chat": "x", "proposals": []}], "", "", ""),
                             wa.PiLaneError)
    finally:
        asyncio.create_subprocess_exec = real
    ok("prose instead of JSON -> PiLaneError", isinstance(err, wa.PiLaneError), repr(err))
    ok("invalid-JSON message names the lane", "JSON invalido" in str(err), str(err))

    # control: fenced JSON must still parse, so the strip survives a model swap
    spawn = Spawn(lambda: FakeProc(rc=0, out=b'```json\n{"blocks": [], "tasks": []}\n```'))
    asyncio.create_subprocess_exec = spawn
    try:
        decided, decide_ok = _run(wa.decide(None, {}, [{"chat": "x", "proposals": []}], "", "", ""))
    finally:
        asyncio.create_subprocess_exec = real
    ok("fenced ```json``` still parses", isinstance(decided, dict) and decide_ok is True)


def case_nano_pin(wa) -> None:
    print("\n-- CLASSIFY/summary model pin --")
    _clear_env()
    check("nano model default is the Haiku pin", wa._nano_model(), "claude-haiku-4-5")
    os.environ["HERMES_NANO_MODEL"] = "claude-opus-4-8"
    check("nano model honours HERMES_NANO_MODEL", wa._nano_model(), "claude-opus-4-8")
    _clear_env()
    bound = [
        n for n in ast.walk(ast.parse(SOURCE.read_text()))
        if isinstance(n, ast.Assign)
        and any(isinstance(t, ast.Name) and t.id == "HAIKU_MODEL" for t in n.targets)
        and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Name)
        and n.value.func.id == "_nano_model"
    ]
    ok("HAIKU_MODEL = _nano_model()", len(bound) == 1, f"{len(bound)} binding(s)")


def _run_whatsapp_ast() -> ast.FunctionDef:
    tree = ast.parse(SOURCE.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "run_whatsapp":
            return node
    raise AssertionError("run_whatsapp not found")


def case_gate_and_watermark() -> None:
    """Structural guard: these are reachability facts about run_whatsapp, which
    is a monolith (disk state + httpx + OAuth) and too costly to drive E2E.
    This is a regression rail against a refactor moving decide above the gate,
    not proof that the runtime path is correct."""
    print("\n-- gate + watermark (structural) --")
    fn = _run_whatsapp_ast()

    gate = None
    for node in ast.walk(fn):
        if isinstance(node, ast.If) and isinstance(node.test, ast.UnaryOp) \
                and isinstance(node.test.op, ast.Not) \
                and isinstance(node.test.operand, ast.Name) and node.test.operand.id == "keep":
            gate = node
            break
    ok("`if not keep:` gate exists", gate is not None)
    if gate is None:
        return
    ok("gate body terminates in return (decide unreachable when keep is empty)",
       isinstance(gate.body[-1], ast.Return))

    decide_calls = [n for n in ast.walk(fn)
                    if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "decide"]
    ok("decide called exactly once in run_whatsapp", len(decide_calls) == 1,
       f"{len(decide_calls)} call(s)")
    if decide_calls:
        ok("decide is called after the gate returns",
           decide_calls[0].lineno > gate.body[-1].lineno)

    # every _advance_* after decide must sit under `if advance_ok and decide_ok`
    gate_node = None
    for node in ast.walk(fn):
        if not isinstance(node, ast.If):
            continue
        test = node.test
        if not isinstance(test, ast.BoolOp) or not isinstance(test.op, ast.And):
            continue
        if not all(isinstance(v, ast.Name) for v in test.values):
            continue
        if {v.id for v in test.values} != {"advance_ok", "decide_ok"}:
            continue
        gate_node = node
        break
    ok("post-decide gate is `and` over exactly advance_ok/decide_ok (an `or` is data loss)",
       gate_node is not None,
       ast.dump(gate_node.test) if gate_node is not None else "no qualifying `if` found")
    guarded = [] if gate_node is None else [
        c.func.id for c in ast.walk(gate_node)
        if isinstance(c, ast.Call) and isinstance(c.func, ast.Name)
        and c.func.id.startswith("_advance_")
    ]
    ok("post-decide watermark advance is gated on advance_ok and decide_ok",
       set(guarded) == {"_advance_watermark", "_advance_email_watermark"}, str(sorted(guarded)))

    if decide_calls:
        line = decide_calls[0].lineno
        wrapped = any(
            isinstance(n, ast.Try) and n.handlers
            and min(c.lineno for c in ast.walk(n) if hasattr(c, "lineno")) <= line
            <= max(c.lineno for c in ast.walk(n) if hasattr(c, "lineno"))
            for n in ast.walk(fn)
        )
        ok("decide is not wrapped in try/except (PiLaneError must propagate)", not wrapped)


def main() -> int:
    print(f"scripts={SCRIPTS_DIR}")
    saved = {k: os.environ.get(k) for k in DECIDE_ENV + NANO_ENV}
    try:
        wa = _load_extractor(SCRIPTS_DIR)
    except Exception as e:  # noqa: BLE001
        print(f"  [FAIL] could not load module: {type(e).__name__}: {e}")
        return 1
    try:
        case_argv_default(wa)
        case_argv_overrides(wa)
        case_single_execution(wa)
        case_failures(wa)
        case_nano_pin(wa)
        case_gate_and_watermark()
    finally:
        _clear_env()
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v
    print(f"\n{'='*48}\n{len(FAILS)} failing case(s): {FAILS or 'none'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
