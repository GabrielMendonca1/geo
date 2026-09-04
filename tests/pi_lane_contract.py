#!/usr/bin/env python3
"""Contract harness for the DECIDE lane (context_scraping -> pi).

Encodes the TARGET contract:
  - The lane is a single stateless `pi -p` subprocess: no session, no tools,
    skills/extensions/prompt-templates/context-files. The prompt enters through
    stdin, so it is not limited by ARG_MAX and runs cannot influence each other.
  - CLASSIFY defaults to openai-codex / gpt-5.6-luna / low; DECIDE defaults to
    openai-codex / gpt-5.6-luna / medium. Both lanes are overridable.
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
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from geo_time_contract import SCRIPTS_DIR, _load_extractor  # noqa: E402

SOURCE = SCRIPTS_DIR / "context_scraping.py"
DECIDE_ENV = ("HERMES_WA_DECIDE_PROVIDER", "HERMES_WA_DECIDE_MODEL", "HERMES_WA_DECIDE_EFFORT")
CLASSIFY_ENV = ("HERMES_WA_CLASSIFY_PROVIDER", "HERMES_WA_CLASSIFY_MODEL", "HERMES_WA_CLASSIFY_EFFORT")

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
    for k in DECIDE_ENV + CLASSIFY_ENV:
        os.environ.pop(k, None)


class FakeProc:
    def __init__(self, rc: int = 0, out: bytes = b"", err: bytes = b"", hang: bool = False):
        self.returncode = rc
        self._out = out
        self._err = err
        self._hang = hang
        self.killed = False
        self.input = None

    async def communicate(self, input=None):
        self.input = input
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
    check("DECIDE model is Luna", wa._decide_model(), "gpt-5.6-luna")
    check("DECIDE provider", wa._decide_provider(), "openai-codex")
    check("DECIDE effort", wa._decide_effort(), "medium")
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
            "--model", "gpt-5.6-luna",
            "--thinking", "medium",
        ],
    )
    for banned in ("-c", "--continue", "--session-dir", "--resume", "--fork", "--cwd"):
        ok(f"argv omits {banned}", banned not in argv)
    ok("prompt is absent from argv", "PROMPT" not in argv and "--" not in argv)
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
    os.environ["HERMES_WA_DECIDE_MODEL"] = "gpt-5.6-sol"
    argv = wa._pi_argv("P")
    check("model alone overrides, provider keeps default",
          (argv[argv.index("--model") + 1], argv[argv.index("--provider") + 1]),
          ("gpt-5.6-sol", "openai-codex"))

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
    ok("prompt is sent through stdin", bool(spawn.last and spawn.last.input))
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


def case_classify_pin(wa) -> None:
    print("\n-- CLASSIFY model pin --")
    _clear_env()
    check("CLASSIFY provider", wa._classify_provider(), "openai-codex")
    check("CLASSIFY model", wa._classify_model(), "gpt-5.6-luna")
    check("CLASSIFY effort", wa._classify_effort(), "low")
    argv = wa._pi_argv("P", wa._classify_provider(), wa._classify_model(), wa._classify_effort())
    check("CLASSIFY argv provider", argv[argv.index("--provider") + 1], "openai-codex")
    check("CLASSIFY argv model", argv[argv.index("--model") + 1], "gpt-5.6-luna")
    check("CLASSIFY argv effort", argv[argv.index("--thinking") + 1], "low")
    os.environ["HERMES_WA_CLASSIFY_MODEL"] = "gpt-5.6-sol"
    check("CLASSIFY override", wa._classify_model(), "gpt-5.6-sol")
    _clear_env()


def _rec(ts: str, msg_id: str | None, chat: str = "5511@c.us", text: str = "x", **extra) -> dict:
    rec = {
        "ts": ts,
        "msg_id": msg_id,
        "chat": chat,
        "sender": "5511",
        "push_name": "Pessoa",
        "type": "text",
        "text": text,
        "from_me": False,
    }
    rec.update(extra)
    return rec


def _scan_records(wa, records: list[dict], watermark: str, boundary=None) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "wa.jsonl"
        path.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
        old_path = wa.JSONL_PATH
        old_end = os.environ.get("HERMES_WA_WINDOW_END")
        wa.JSONL_PATH = path
        os.environ["HERMES_WA_WINDOW_END"] = "2026-08-11T12:00:00Z"
        try:
            return wa.scan_wa_jsonl(watermark, boundary or [], set())
        finally:
            wa.JSONL_PATH = old_path
            if old_end is None:
                os.environ.pop("HERMES_WA_WINDOW_END", None)
            else:
                os.environ["HERMES_WA_WINDOW_END"] = old_end


def case_context_boundary_caps_dedup(wa) -> None:
    print("\n-- bounded WhatsApp context --")
    cutoff = "2026-08-08T12:00:00Z"
    scan = _scan_records(wa, [
        _rec(cutoff, "edge"),
        _rec("2026-08-08T11:59:59.999000Z", "too-old"),
        _rec("2026-08-08T12:00:00.001000Z", "new"),
    ], cutoff, ["edge"])
    context = scan["context"]["5511@c.us"]["context"]
    check("72h boundary is inclusive", [r["msg_id"] for r in context], ["edge"])
    check("untrimmed context reports no truncation", scan["context"]["5511@c.us"]["context_truncated"], False)
    check("1ms before 72h boundary is excluded", [r["msg_id"] for r in scan["new"]], ["new"])
    check("scan exposes exactly three views", set(scan), {"new", "context", "bootstrap"})

    base = datetime(2026, 8, 10, 8, tzinfo=timezone.utc)
    records = [_rec((base + timedelta(minutes=i)).isoformat().replace("+00:00", "Z"), str(i)) for i in range(121)]
    capped = _scan_records(wa, records, "2026-08-11T12:00:00Z")
    kept = capped["context"]["5511@c.us"]["context"]
    check("121 context messages keep 120", len(kept), 120)
    check("message cap drops oldest", kept[0]["msg_id"], "1")
    check("message cap preserves newest", kept[-1]["msg_id"], "120")
    check("message cap reports truncation", capped["context"]["5511@c.us"]["context_truncated"], True)
    exact = _scan_records(wa, records[1:], "2026-08-11T12:00:00Z")["context"]["5511@c.us"]["context"]
    check("120 context messages keep 120", len(exact), 120)

    chars = [_rec(f"2026-08-10T0{i}:00:00Z", str(i), text="a" * 2970) for i in range(3)]
    check("character measurement matches rendered prompt", wa._measure_formatted_size(chars), len(wa.format_messages(chars)))
    trimmed, truncated = wa._trim_context(chars, 120, 6000)
    check("character cap drops oldest first", [r["msg_id"] for r in trimmed], ["1", "2"])
    ok("character cap reports truncation", truncated)
    scanned = _scan_records(wa, chars, "2026-08-11T12:00:00Z")
    scanned_chars = scanned["context"]["5511@c.us"]["context"]
    scanned_truncated = scanned["context"]["5511@c.us"]["context_truncated"]
    check("scan enforces character cap", [r["msg_id"] for r in scanned_chars], ["1", "2"])
    check("character cap metadata reports truncation", scanned_truncated, True)
    banner_bucket = wa.bucket_by_chat(
        [_rec("2026-08-11T11:00:00Z", "fresh")],
        {"5511@c.us": {"context": scanned_chars, "context_truncated": scanned_truncated}},
    )[0]
    ok("truncation banner follows context_truncated", "[...contexto truncado" in wa.format_prompt(banner_bucket))

    enriched = _rec("2026-08-10T09:00:00Z", "media", type="audio", text="legenda", _media_text="transcrição")
    rendered = wa.format_messages([enriched])
    ok("rendered prompt includes timestamp", rendered.startswith("2026-08-10 09:00:00"))
    ok("rendered prompt includes media enrichment", "transcrição legenda" in rendered)
    check("media measurement uses rendered prompt", wa._measure_formatted_size([enriched]), len(rendered))

    duplicate = _scan_records(wa, [
        _rec("2026-08-10T10:00:00Z", "same", text="old"),
        _rec("2026-08-10T11:00:00Z", "same", text="new"),
    ], "2026-08-10T10:30:00Z")
    check("new msg_id removes historical duplicate", duplicate["context"], {})
    no_id = _rec("2026-08-10T10:00:00Z", None, text="stable")
    same = dict(no_id)
    same["_media_text"] = "cached enrichment"
    check("hash fallback is stable across cache mutation", wa._msg_key(no_id), wa._msg_key(same))
    ok("hash fallback has sha1 prefix", wa._msg_key(no_id).startswith("h:"))
    check("msg_id key wins", wa._msg_key(no_id | {"msg_id": "abc"}), "id:abc")
    state: dict = {}
    real_save = wa.save_state
    wa.save_state = lambda value: None
    try:
        wa._advance_watermark(state, [no_id])
    finally:
        wa.save_state = real_save
    check("watermark stores fallback key", state["boundary_msg_ids"], [wa._msg_key(no_id)])
    replay = _scan_records(wa, [no_id], no_id["ts"], state["boundary_msg_ids"])
    check("fallback boundary prevents replay", replay["new"], [])


def case_group_email_prompt_media(wa) -> None:
    print("\n-- group, email, prompt, and media isolation --")
    ok("explicit is_group is detected", wa._is_group_chat(_rec("2026-08-11T10:00:00Z", "1", is_group=True)))
    ok("@g.us suffix is detected", wa._is_group_chat(_rec("2026-08-11T10:00:00Z", "2", chat="123@g.us")))
    ok("@c.us stays direct", not wa._is_group_chat(_rec("2026-08-11T10:00:00Z", "3")))
    ok("suffixless chat stays direct", not wa._is_group_chat(_rec("2026-08-11T10:00:00Z", "4", chat="plain")))
    grouped = wa.bucket_by_chat([_rec("2026-08-11T10:00:00Z", "5", chat="123@g.us")])
    check("bucket applies group detection", grouped[0]["is_group"], True)

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "email.jsonl"
        path.write_text(json.dumps({
            "ts": "2026-08-11T10:00:00Z", "msg_id": "42@mail", "account": "work",
            "sender": "ana@example.com", "subject": "Contrato", "text": "Pode revisar?",
        }) + "\n", encoding="utf-8")
        old_path = wa.EMAIL_JSONL_PATH
        wa.EMAIL_JSONL_PATH = path
        try:
            email_scan = wa.scan_email_jsonl({"work": 41})
        finally:
            wa.EMAIL_JSONL_PATH = old_path
    check("email scan has new-only view", set(email_scan), {"new"})
    email_bucket = wa.bucket_by_account(email_scan["new"])[0]
    check("email is atomic", len(email_bucket["messages"]), 1)
    check("email has no context", email_bucket["context"], [])
    check("email origin label", email_bucket["label"], "email work: ana@example.com/Contrato")

    captured: list[str] = []
    async def fake_call(prompt, timeout_s, **kwargs):
        captured.append(prompt)
        return '{"proposals": {}}'
    real_call = wa._pi_complete
    wa._pi_complete = fake_call
    try:
        _run(wa.classify_bucket(None, {}, grouped[0], "resumo vivo"))
        email_bucket["context"] = [_rec("2026-08-10T10:00:00Z", "old", text="SEGREDO")]
        _run(wa.classify_bucket(None, {}, email_bucket, "RESUMO EMAIL ANTIGO"))
    finally:
        wa._pi_complete = real_call
    ok("prompt separates CONTEXTO", "===== CONTEXTO —" in captured[0])
    ok("prompt separates MENSAGENS NOVAS", "===== MENSAGENS NOVAS —" in captured[0])
    ok("prompt forbids context-only proposals", "NÃO sugira nada que só aparece no CONTEXTO" in captured[0])
    ok("prompt keeps context_messages distinct", "{context_messages}" in wa.HAIKU_PROMPT_TEMPLATE)
    ok("prompt keeps messages distinct", "{messages}" in wa.HAIKU_PROMPT_TEMPLATE)
    ok("group prompt uses JSON boolean", "group=true" in captured[0])
    ok("email prompt excludes old messages", "SEGREDO" not in captured[1])
    ok("email prompt excludes previous summary", "RESUMO EMAIL ANTIGO" not in captured[1])

    historical = _rec("2026-08-10T10:00:00Z", "media", type="audio", text="", media={"path": "/tmp/a"})
    wa._media_memo["/tmp/a"] = "[áudio transcrito] memo"
    ok("historical formatting may reuse memo", "memo" in wa.format_messages([historical]))


def case_scan_and_classify_failures(wa) -> None:
    print("\n-- bounded failures --")
    with tempfile.TemporaryDirectory() as tmp:
        old_path = wa.JSONL_PATH
        wa.JSONL_PATH = Path(tmp)
        try:
            failed = wa.scan_wa_jsonl(None)
        finally:
            wa.JSONL_PATH = old_path
    check("scan I/O failure is bounded", failed, {"new": [], "context": {}, "bootstrap": {}})

    async def failed_call(*args, **kwargs):
        raise wa.PiLaneError("classify failed")
    bucket = wa.bucket_by_chat([_rec("2026-08-11T10:00:00Z", "x")])[0]
    real_call = wa._pi_complete
    wa._pi_complete = failed_call
    try:
        err = _expect_raises(lambda: wa.classify_bucket(None, {}, bucket), wa.PiLaneError)
    finally:
        wa._pi_complete = real_call
    ok("CLASSIFY failure propagates as PiLaneError", isinstance(err, wa.PiLaneError), repr(err))

    fn = _run_whatsapp_ast()
    calls = [n for n in ast.walk(fn) if isinstance(n, ast.Call)]
    check("WhatsApp JSONL scan called once per run", sum(isinstance(n.func, ast.Name) and n.func.id == "scan_wa_jsonl" for n in calls), 1)
    check("email JSONL scan called once per run", sum(isinstance(n.func, ast.Name) and n.func.id == "scan_email_jsonl" for n in calls), 1)
    enrich = [n for n in calls if isinstance(n.func, ast.Name) and n.func.id == "enrich_window_media"]
    ok("media enrichment receives only new records", len(enrich) == 1 and isinstance(enrich[0].args[0], ast.Name) and enrich[0].args[0].id == "records")


def case_classify_failures_no_watermark_leak(wa) -> None:
    print("\n-- CLASSIFY failures do not leak watermark state --")
    records = [
        _rec("2026-08-11T10:00:00Z", "1", chat="chat-1", text="mensagem-1", push_name="Pessoa 1"),
        _rec("2026-08-11T10:01:00Z", "2", chat="chat-2", text="mensagem-2", push_name="Pessoa 2"),
        _rec("2026-08-11T10:02:00Z", "3", chat="chat-3", text="mensagem-3", push_name="Pessoa 3"),
    ]
    state: dict = {
        "last_processed_ts": "2026-08-11T09:59:00Z",
        "boundary_msg_ids": [],
    }
    classified: list[str] = []
    prompts: list[str] = []
    decided_chat_ids: list[str] = []
    fail_chat = True

    class FakeHttp:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

    async def fake_enrich(*args, **kwargs):
        return None

    async def fake_call(prompt, timeout_s, **kwargs):
        prompts.append(prompt)
        for index in range(1, 4):
            chat_id = f"chat-{index}"
            if f'"chat_id": "{chat_id}"' not in prompt:
                continue
            if fail_chat and chat_id == "chat-3":
                raise wa.PiLaneError("classify failed")
            classified.append(chat_id)
            return json.dumps({"proposals": {"facts": [{"content": f"fato-{index}"}]}})
        return None

    async def fake_summaries(*args, **kwargs):
        return "resumos", True

    async def fake_decide(http, headers, kept, brain_context, chat_summaries, tasks_context):
        decided_chat_ids.extend(result["chat_id"] for result in kept)
        return {"blocks": [], "tasks": [], "urgent": [], "people": [], "digest": {}, "task_updates": []}, True

    async def fake_persist(*args, **kwargs):
        return {
            "blocks_created": 0,
            "blocks_appended": 0,
            "blocks_capped": 0,
            "blocks_invalid": 0,
            "dedup_skips": 0,
            "tasks_created": 0,
            "tasks_proposed": 0,
            "tasks_capped": 0,
            "urgent": 0,
            "task_mutations": 0,
        }

    replacements = {
        "load_oauth_token": lambda: "token",
        "load_state": lambda: state,
        "load_chats": lambda: {"chats": {}},
        "scan_wa_jsonl": lambda watermark, boundary, *args: {
            "new": [
                record for record in records
                if record["ts"] > (watermark or "")
                or (
                    record["ts"] == (watermark or "")
                    and record["msg_id"] not in set(boundary or [])
                )
            ],
            "context": {},
            "bootstrap": {},
        },
        "scan_email_jsonl": lambda *args: {"new": []},
        "enrich_window_media": fake_enrich,
        "_pi_complete": fake_call,
        "update_chat_summaries": fake_summaries,
        "render_brain_context": lambda: "cérebro",
        "_recent_tasks_context": lambda: "tarefas",
        "decide": fake_decide,
        "persist": fake_persist,
        "expire_stale_tasks": lambda **kwargs: [],
        "_materialize_if_due": lambda *args: None,
        "save_chats": lambda *args: None,
        "save_state": lambda *args: None,
    }
    originals = {name: getattr(wa, name) for name in replacements}
    had_client = hasattr(wa.httpx, "AsyncClient")
    original_client = getattr(wa.httpx, "AsyncClient", None)
    original_argv = sys.argv
    try:
        for name, value in replacements.items():
            setattr(wa, name, value)
        wa.httpx.AsyncClient = FakeHttp
        sys.argv = [sys.argv[0]]
        check("one failed CLASSIFY does not stop the cycle", _run(wa.run_whatsapp()), 0)
        check("partial failure advances only before the failed chat", state.get("last_processed_ts"), records[1]["ts"])
        check("safe partial boundary belongs to last successful chat", state.get("boundary_msg_ids"), ["2"])
        check("successful chats before failure remain classified", classified, ["chat-1", "chat-2"])
        check("failed chat is excluded from the decision window", decided_chat_ids, ["chat-1", "chat-2"])
        ok("first successful message is in its decision window", any("mensagem-1" in prompt for prompt in prompts))
        ok("second successful message is in its decision window", any("mensagem-2" in prompt for prompt in prompts))

        fail_chat = False
        classified.clear()
        prompts.clear()
        decided_chat_ids.clear()
        check("next cycle retries the failed chat", _run(wa.run_whatsapp()), 0)
        check("retry window contains only the previously failed chat", decided_chat_ids, ["chat-3"])
        check("failed chat is classified successfully on retry", classified, ["chat-3"])
        check("global watermark advances after retry success", state.get("last_processed_ts"), records[-1]["ts"])
        check("watermark boundary belongs only to the newest chat", state.get("boundary_msg_ids"), ["3"])

        wa.scan_wa_jsonl = lambda *args: {"new": [], "context": {}, "bootstrap": {}}
        snapshot = dict(state)
        check("no chats processed returns exit code 0", _run(wa.run_whatsapp()), 0)
        check("empty window does not mutate watermark", state, snapshot)
    finally:
        sys.argv = original_argv
        if had_client:
            wa.httpx.AsyncClient = original_client
        else:
            del wa.httpx.AsyncClient
        for name, value in originals.items():
            setattr(wa, name, value)


def _run_whatsapp_ast() -> ast.FunctionDef:
    tree = ast.parse(SOURCE.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "run_whatsapp":
            return node
    raise AssertionError("run_whatsapp not found")


def case_decide_structural_gates() -> None:
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
        if len(test.values) != 2 or {v.id for v in test.values} != {"advance_ok", "decide_ok"}:
            continue
        gate_node = node
        break
    ok("post-decide gate is `and` over exactly advance_ok/decide_ok (an `or` is data loss)",
       gate_node is not None,
       ast.dump(gate_node.test) if gate_node is not None else "no qualifying `if` found")
    guarded_calls = [] if gate_node is None else [
        c
        for statement in gate_node.body
        for c in ast.walk(statement)
        if isinstance(c, ast.Call) and isinstance(c.func, ast.Name)
        and c.func.id.startswith("_advance_")
    ]
    guarded = [c.func.id for c in guarded_calls]
    ok("post-decide watermark advance is gated on advance_ok and decide_ok",
       set(guarded) == {"_advance_watermark", "_advance_email_watermark"}, str(sorted(guarded)))
    all_advances = [
        n for n in ast.walk(fn)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
        and n.func.id in {"_advance_watermark", "_advance_email_watermark"}
    ]
    empty_gate_calls = [
        n for n in ast.walk(gate)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
        and n.func.id in {"_advance_watermark", "_advance_email_watermark"}
    ]
    check("empty-proposal gate advances both watermarks",
          {n.func.id for n in empty_gate_calls},
          {"_advance_watermark", "_advance_email_watermark"})
    check("all watermark advances are inside a success gate",
          {(n.func.id, n.lineno) for n in all_advances},
          {(n.func.id, n.lineno) for n in guarded_calls + empty_gate_calls})

    if decide_calls:
        line = decide_calls[0].lineno
        wrapped = any(
            isinstance(n, ast.Try) and n.handlers
            and min(c.lineno for c in ast.walk(n) if hasattr(c, "lineno")) <= line
            <= max(c.lineno for c in ast.walk(n) if hasattr(c, "lineno"))
            for n in ast.walk(fn)
        )
        ok("decide is not wrapped in try/except (PiLaneError must propagate)", not wrapped)

    result_assigns = [
        n for n in ast.walk(fn)
        if isinstance(n, ast.Assign)
        and any(isinstance(t, ast.Name) and t.id == "results" for t in n.targets)
    ]
    ok("CLASSIFY gather exists", len(result_assigns) == 1)
    if result_assigns:
        gather_await = result_assigns[0].value
        gather_call = gather_await.value if isinstance(gather_await, ast.Await) else None
        return_exceptions = [
            kw.value for kw in gather_call.keywords
            if kw.arg == "return_exceptions"
        ] if isinstance(gather_call, ast.Call) else []
        ok("CLASSIFY gather isolates exceptions",
           len(return_exceptions) == 1 and isinstance(return_exceptions[0], ast.Constant)
           and return_exceptions[0].value is True)
        line = result_assigns[0].lineno
        wrapped = any(
            isinstance(n, ast.Try) and n.handlers
            and min(c.lineno for c in ast.walk(n) if hasattr(c, "lineno")) <= line
            <= max(c.lineno for c in ast.walk(n) if hasattr(c, "lineno"))
            for n in ast.walk(fn)
        )
        ok("CLASSIFY is not wrapped in try/except (PiLaneError must propagate)", not wrapped)
        check("classified path has both success-gated watermark pairs", sum(n.lineno > line for n in all_advances), 4)

    or_gates = [
        n for n in ast.walk(fn)
        if isinstance(n, ast.BoolOp) and isinstance(n.op, ast.Or)
        and {v.id for v in n.values if isinstance(v, ast.Name)} & {"advance_ok", "decide_ok"}
    ]
    check("watermark flags are never joined by OR", or_gates, [])


def main() -> int:
    print(f"scripts={SCRIPTS_DIR}")
    saved = {k: os.environ.get(k) for k in DECIDE_ENV + CLASSIFY_ENV}
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
        case_classify_pin(wa)
        case_context_boundary_caps_dedup(wa)
        case_group_email_prompt_media(wa)
        case_scan_and_classify_failures(wa)
        case_classify_failures_no_watermark_leak(wa)
        case_decide_structural_gates()
    finally:
        _clear_env()
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v
    print(f"\n{'='*48}\n{len(FAILS)} failing case(s): {FAILS or 'none'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
