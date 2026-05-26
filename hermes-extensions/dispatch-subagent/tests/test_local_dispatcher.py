import asyncio
import json
from collections import deque
from pathlib import Path

import pytest

from dispatch_subagent.frontmatter_queue import FrontmatterQueue, FrontmatterUpdate
from dispatch_subagent.local_dispatcher import (
    LOCAL_CONCURRENCY,
    STDOUT_TAIL_LINES,
    DispatchRequest,
    LocalDispatcher,
)


class _CollectingSink:
    def __init__(self):
        self.calls: list[tuple[str, dict[str, str]]] = []

    async def __call__(self, block_id: str, fields: dict[str, str]) -> None:
        self.calls.append((block_id, dict(fields)))


@pytest.fixture
def fm():
    return FrontmatterQueue(debounce_ms=20, sink=_CollectingSink())


async def test_session_id_captured_from_first_session_event(monkeypatch, fm, tmp_path):
    disp = LocalDispatcher(frontmatter=fm, workspaces_root=tmp_path)

    class FakeStdout:
        def __init__(self, lines):
            self._lines = list(lines)

        async def readline(self):
            if not self._lines:
                return b""
            return (self._lines.pop(0) + "\n").encode()

    class FakeProc:
        def __init__(self, lines):
            self.stdout = FakeStdout(lines)
            self.killed = False

        def kill(self):
            self.killed = True

        async def wait(self):
            return 0

    fake = FakeProc([
        '{"type":"agent_start"}',
        '{"type":"session","id":"pi-uuid-7-aaa"}',
        '{"type":"message_start"}',
    ])

    async def fake_create(*a, **kw):
        return fake

    monkeypatch.setattr("asyncio.create_subprocess_exec", fake_create)

    req = DispatchRequest(
        block_id="GEO-7",
        prompt="do the thing",
        provider="anthropic",
    )
    result = await disp.dispatch(req)
    assert result["pi_session_id"] == "pi-uuid-7-aaa"
    assert result["status"] == "running"
    assert result["dispatch_id"] != result["pi_session_id"]
    assert "geo-7" in result["workspace_path"]


async def test_capacity_rejection_after_wait(monkeypatch, fm, tmp_path):
    disp = LocalDispatcher(frontmatter=fm, workspaces_root=tmp_path, concurrency=1)
    for _ in range(1):
        await disp._sem.acquire()

    monkeypatch.setattr(
        "dispatch_subagent.local_dispatcher.CAPACITY_WAIT_SECONDS",
        0.05,
    )

    req = DispatchRequest(block_id="x", prompt="p", provider="anthropic")
    result = await disp.dispatch(req)
    assert result["status"] == "capacity"


async def test_semaphore_caps_at_default_concurrency(fm, tmp_path):
    disp = LocalDispatcher(frontmatter=fm, workspaces_root=tmp_path)
    acquired = 0
    for _ in range(LOCAL_CONCURRENCY):
        await disp._sem.acquire()
        acquired += 1
    assert acquired == LOCAL_CONCURRENCY
    assert disp._sem.locked()


def test_stdout_deque_caps_at_1000():
    d: deque[str] = deque(maxlen=STDOUT_TAIL_LINES)
    for i in range(STDOUT_TAIL_LINES + 250):
        d.append(f"line {i}")
    assert len(d) == STDOUT_TAIL_LINES
    assert d[0] == "line 250"
    assert d[-1] == f"line {STDOUT_TAIL_LINES + 249}"


async def test_frontmatter_queue_debounces():
    sink = _CollectingSink()
    fm = FrontmatterQueue(debounce_ms=30, sink=sink)
    await fm.submit(FrontmatterUpdate("blk-1", {"symphony_session_id": "a"}))
    await fm.submit(FrontmatterUpdate("blk-1", {"symphony_state": "Todo"}))
    await fm.submit(FrontmatterUpdate("blk-1", {"symphony_state": "In Progress"}))
    await asyncio.sleep(0.1)
    assert len(sink.calls) == 1
    block_id, fields = sink.calls[0]
    assert block_id == "blk-1"
    assert fields == {"symphony_session_id": "a", "symphony_state": "In Progress"}


async def test_frontmatter_queue_separate_blocks_emit_separately():
    sink = _CollectingSink()
    fm = FrontmatterQueue(debounce_ms=20, sink=sink)
    await fm.submit(FrontmatterUpdate("a", {"k": "1"}))
    await fm.submit(FrontmatterUpdate("b", {"k": "2"}))
    await asyncio.sleep(0.1)
    assert len(sink.calls) == 2
    ids = sorted(c[0] for c in sink.calls)
    assert ids == ["a", "b"]


async def test_hard_kill_at_30min_simulated(monkeypatch, fm, tmp_path):
    monkeypatch.setattr(
        "dispatch_subagent.local_dispatcher.HARD_KILL_SECONDS",
        0.05,
    )
    disp = LocalDispatcher(frontmatter=fm, workspaces_root=tmp_path)

    class StallStdout:
        async def readline(self):
            await asyncio.sleep(10)
            return b""

    class StallProc:
        def __init__(self):
            self.stdout = StallStdout()
            self.killed = False

        def kill(self):
            self.killed = True

        async def wait(self):
            return -9

    fake = StallProc()

    async def fake_create(*a, **kw):
        return fake

    monkeypatch.setattr("asyncio.create_subprocess_exec", fake_create)

    req = DispatchRequest(block_id="z", prompt="p", provider="anthropic")
    result = await disp.dispatch(req)
    assert result["status"] == "failed"
    assert result.get("error") == "hard_kill_30min"
    assert fake.killed is True


def test_dispatch_request_provider_flag_mapping():
    from dispatch_subagent.local_dispatcher import _provider_flag

    assert _provider_flag("anthropic") == "anthropic"
    assert _provider_flag("openai-codex") == "openai"
    with pytest.raises(ValueError):
        _provider_flag("bogus")


def test_uuid7_format():
    from dispatch_subagent.local_dispatcher import _uuid7

    val = _uuid7()
    parts = val.split("-")
    assert len(parts) == 5
    assert [len(p) for p in parts] == [8, 4, 4, 4, 12]
    assert parts[2][0] == "7"


def test_separate_session_id_fields(monkeypatch, tmp_path):
    from dispatch_subagent.local_dispatcher import LiveSession, _uuid7

    s = LiveSession(
        hermes_session_id=_uuid7(),
        block_id="x",
        workspace_path=Path(tmp_path),
    )
    assert s.pi_session_id is None
    s.pi_session_id = "pi-id"
    assert s.hermes_session_id != s.pi_session_id
