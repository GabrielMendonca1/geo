"""
Local pi-spawning dispatcher.

Mirrors AgentWorkspaceManager.spawnPi (Swift) ~L1860-1938 plus
applyPiStreamLine ~L1948. Differences vs the Swift original:

- One semaphore (cap = 8) guards concurrent local spawns. Acquire blocks up to
  30 s, then returns capacity={"status":"capacity"}.
- Stdout tail is a `collections.deque(maxlen=1000)` — old lines drop on the
  floor, so a chatty pi can't blow memory.
- Frontmatter writes go through FrontmatterQueue (500 ms debounce per block_id)
  instead of stamping every line.
- Two session ids tracked side by side, never conflated:
    * hermes_session_id: generated here (UUIDv7-shaped), the dispatch handle.
    * pi_session_id:     captured from pi's first {"type":"session"} JSON line.
"""

import asyncio
import json
import os
import shlex
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from .frontmatter_queue import FrontmatterQueue, FrontmatterUpdate
from .sanitize import sanitize

LOCAL_CONCURRENCY = 8
CAPACITY_WAIT_SECONDS = 30.0
HARD_KILL_SECONDS = 30 * 60
STDOUT_TAIL_LINES = 1000

PI_SYSTEM_PROMPT_TEMPLATE = (
    "You are pi running inside Geo as a background coding agent. "
    "When done, overwrite the Markdown report at:\n{report_path}\n"
    "First section MUST be `## Progress` (a checklist of concrete steps you "
    "took). Then summary, files changed, validation, risks, and `## Next "
    "Recommended State` whose body's first word is one of: Backlog, Todo, "
    "In Progress, Human Review, Rework, Merging, Done, Canceled."
)


def _uuid7() -> str:
    ts_ms = int(time.time() * 1000) & ((1 << 48) - 1)
    rand_a = int.from_bytes(os.urandom(2), "big") & 0x0FFF
    rand_b = int.from_bytes(os.urandom(8), "big") & ((1 << 62) - 1)
    val = (ts_ms << 80) | (0x7 << 76) | (rand_a << 64) | (1 << 63) | rand_b
    hexs = f"{val:032x}"
    return f"{hexs[0:8]}-{hexs[8:12]}-{hexs[12:16]}-{hexs[16:20]}-{hexs[20:32]}"


def _provider_flag(provider: str) -> str:
    if provider == "anthropic":
        return "anthropic"
    if provider == "openai-codex":
        return "openai"
    raise ValueError(f"unknown provider: {provider!r}")


@dataclass
class DispatchRequest:
    block_id: str
    prompt: str
    provider: str
    model: str | None = None
    effort: str | None = None
    resume_pi_session_id: str | None = None


@dataclass
class LiveSession:
    hermes_session_id: str
    block_id: str
    workspace_path: Path
    pi_session_id: str | None = None
    last_event: str | None = None
    stdout_tail: deque[str] = field(
        default_factory=lambda: deque(maxlen=STDOUT_TAIL_LINES)
    )


class LocalDispatcher:
    def __init__(
        self,
        *,
        frontmatter: FrontmatterQueue,
        pi_binary: str = "pi",
        workspaces_root: Path | None = None,
        concurrency: int = LOCAL_CONCURRENCY,
    ) -> None:
        self._frontmatter = frontmatter
        self._pi = pi_binary
        self._root = workspaces_root or (Path.home() / ".symphony" / "workspaces")
        self._sem = asyncio.Semaphore(concurrency)
        self._sessions: dict[str, LiveSession] = {}

    def workspace_for(self, block_id: str) -> Path:
        return self._root / sanitize(block_id)

    def _build_command(
        self,
        req: DispatchRequest,
        workspace: Path,
    ) -> list[str]:
        report_path = str(workspace / ".symphony" / "report.md")
        system_prompt = PI_SYSTEM_PROMPT_TEMPLATE.format(report_path=report_path)
        parts: list[str] = [
            shlex.quote(self._pi),
            "-p", shlex.quote(req.prompt),
            "--mode", "json",
            "--provider", shlex.quote(_provider_flag(req.provider)),
            "--append-system-prompt", shlex.quote(system_prompt),
            "--no-context-files",
        ]
        if req.model:
            parts += ["--model", shlex.quote(req.model)]
        if req.resume_pi_session_id:
            parts += ["--session", shlex.quote(req.resume_pi_session_id)]
        return parts

    async def dispatch(self, req: DispatchRequest) -> dict[str, str]:
        try:
            await asyncio.wait_for(self._sem.acquire(), timeout=CAPACITY_WAIT_SECONDS)
        except asyncio.TimeoutError:
            return {
                "dispatch_id": "",
                "pi_session_id": "",
                "status": "capacity",
                "workspace_path": "",
            }

        hermes_id = _uuid7()
        workspace = self.workspace_for(req.block_id)
        workspace.mkdir(parents=True, exist_ok=True)
        (workspace / ".symphony").mkdir(parents=True, exist_ok=True)
        session = LiveSession(
            hermes_session_id=hermes_id,
            block_id=req.block_id,
            workspace_path=workspace,
        )
        self._sessions[hermes_id] = session

        cmd_line = " ".join(self._build_command(req, workspace))
        try:
            proc = await asyncio.create_subprocess_exec(
                "/bin/zsh", "-lc", cmd_line,
                cwd=str(workspace),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                stdin=asyncio.subprocess.DEVNULL,
            )
        except Exception as exc:
            self._sem.release()
            self._sessions.pop(hermes_id, None)
            return {
                "dispatch_id": hermes_id,
                "pi_session_id": "",
                "status": "failed",
                "workspace_path": str(workspace),
                "error": repr(exc),
            }

        try:
            session_event = await asyncio.wait_for(
                self._read_until_session(proc, session, req.block_id),
                timeout=HARD_KILL_SECONDS,
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            self._sem.release()
            await self._frontmatter.submit(
                FrontmatterUpdate(req.block_id, {"symphony_state": "Failed"})
            )
            return {
                "dispatch_id": hermes_id,
                "pi_session_id": session.pi_session_id or "",
                "status": "failed",
                "workspace_path": str(workspace),
                "error": "hard_kill_30min",
            }

        asyncio.create_task(self._drain_rest(proc, session, req.block_id))

        return {
            "dispatch_id": hermes_id,
            "pi_session_id": session_event or "",
            "status": "running",
            "workspace_path": str(workspace),
        }

    async def _read_until_session(
        self,
        proc: asyncio.subprocess.Process,
        session: LiveSession,
        block_id: str,
    ) -> str | None:
        assert proc.stdout is not None
        while True:
            raw = await proc.stdout.readline()
            if not raw:
                return None
            line = raw.decode("utf-8", errors="replace").rstrip("\n")
            session.stdout_tail.append(line)
            event = self._parse_event(line)
            if event is None:
                continue
            kind = event.get("type")
            if kind == "session":
                pid = event.get("id")
                if isinstance(pid, str) and pid:
                    session.pi_session_id = pid
                    await self._frontmatter.submit(
                        FrontmatterUpdate(block_id, {"symphony_session_id": pid})
                    )
                    return pid

    async def _drain_rest(
        self,
        proc: asyncio.subprocess.Process,
        session: LiveSession,
        block_id: str,
    ) -> None:
        assert proc.stdout is not None
        try:
            deadline = time.monotonic() + HARD_KILL_SECONDS
            last_state: str | None = None
            while True:
                if time.monotonic() > deadline:
                    proc.kill()
                    break
                raw = await proc.stdout.readline()
                if not raw:
                    break
                line = raw.decode("utf-8", errors="replace").rstrip("\n")
                session.stdout_tail.append(line)
                event = self._parse_event(line)
                if event is None:
                    continue
                kind = event.get("type")
                if kind in {"agent_end", "complete"}:
                    await self._frontmatter.submit(
                        FrontmatterUpdate(block_id, {"symphony_state": "Human Review"})
                    )
                    last_state = "complete"
                elif kind in {"error", "failed"}:
                    await self._frontmatter.submit(
                        FrontmatterUpdate(block_id, {"symphony_state": "Failed"})
                    )
                    last_state = "failed"
                elif kind == "state_changed":
                    new = event.get("state")
                    if isinstance(new, str) and new and new != last_state:
                        await self._frontmatter.submit(
                            FrontmatterUpdate(block_id, {"symphony_state": new})
                        )
                        last_state = new
            await proc.wait()
        finally:
            self._sem.release()
            self._sessions.pop(session.hermes_session_id, None)

    @staticmethod
    def _parse_event(line: str) -> dict | None:
        trimmed = line.strip()
        if not trimmed:
            return None
        try:
            obj = json.loads(trimmed)
        except json.JSONDecodeError:
            return None
        return obj if isinstance(obj, dict) else None
