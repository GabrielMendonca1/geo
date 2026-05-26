"""
SSH-based remote dispatcher.

Same shape as LocalDispatcher (semaphore-guarded, deque-bounded stdout, debounced
frontmatter, separate hermes/pi session ids) but invokes pi over an SSH channel
to a configured target.

Target config lives in ~/.hermes/dispatch-targets.yaml:

    targets:
      - name: hetzner-01
        host: hetzner-01.tail-scale.ts.net
        user: biel
        key_path: ~/.ssh/id_ed25519
        pi_path: /home/biel/.local/bin/pi
        workspace_root: /home/biel/.symphony/workspaces

A heartbeat task writes "\n" to the channel every 30 s. On EOF or channel
disconnect the dispatch returns status=failed reason=ssh_disconnect.
"""

import asyncio
import json
import shlex
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

import paramiko
import yaml

from .frontmatter_queue import FrontmatterQueue, FrontmatterUpdate
from .local_dispatcher import (
    HARD_KILL_SECONDS,
    PI_SYSTEM_PROMPT_TEMPLATE,
    STDOUT_TAIL_LINES,
    DispatchRequest,
    _provider_flag,
    _uuid7,
)
from .sanitize import sanitize

REMOTE_CONCURRENCY = 3
CAPACITY_WAIT_SECONDS = 30.0
HEARTBEAT_SECONDS = 30.0


@dataclass
class RemoteTarget:
    name: str
    host: str
    user: str
    key_path: str
    pi_path: str
    workspace_root: str


@dataclass
class RemoteSession:
    hermes_session_id: str
    block_id: str
    workspace_path: str
    pi_session_id: str | None = None
    stdout_tail: deque[str] = field(
        default_factory=lambda: deque(maxlen=STDOUT_TAIL_LINES)
    )


def load_targets(path: Path | None = None) -> dict[str, RemoteTarget]:
    p = path or (Path.home() / ".hermes" / "dispatch-targets.yaml")
    if not p.exists():
        return {}
    raw = yaml.safe_load(p.read_text())
    out: dict[str, RemoteTarget] = {}
    for entry in (raw or {}).get("targets", []):
        t = RemoteTarget(**entry)
        out[t.name] = t
    return out


class RemoteDispatcher:
    def __init__(
        self,
        target: RemoteTarget,
        *,
        frontmatter: FrontmatterQueue,
        concurrency: int = REMOTE_CONCURRENCY,
    ) -> None:
        self._target = target
        self._frontmatter = frontmatter
        self._sem = asyncio.Semaphore(concurrency)
        self._sessions: dict[str, RemoteSession] = {}

    def _remote_workspace(self, block_id: str) -> str:
        return f"{self._target.workspace_root.rstrip('/')}/{sanitize(block_id)}"

    def _build_remote_command(self, req: DispatchRequest, workspace: str) -> str:
        report_path = f"{workspace}/.symphony/report.md"
        sys_prompt = PI_SYSTEM_PROMPT_TEMPLATE.format(report_path=report_path)
        parts: list[str] = [
            shlex.quote(self._target.pi_path),
            "-p", shlex.quote(req.prompt),
            "--mode", "json",
            "--provider", shlex.quote(_provider_flag(req.provider)),
            "--append-system-prompt", shlex.quote(sys_prompt),
            "--no-context-files",
        ]
        if req.model:
            parts += ["--model", shlex.quote(req.model)]
        if req.resume_pi_session_id:
            parts += ["--session", shlex.quote(req.resume_pi_session_id)]
        argv = " ".join(parts)
        return f"mkdir -p {shlex.quote(workspace)}/.symphony && cd {shlex.quote(workspace)} && {argv}"

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
        workspace = self._remote_workspace(req.block_id)
        session = RemoteSession(
            hermes_session_id=hermes_id,
            block_id=req.block_id,
            workspace_path=workspace,
        )
        self._sessions[hermes_id] = session

        try:
            pi_session = await asyncio.wait_for(
                asyncio.to_thread(self._run_blocking, req, session, workspace),
                timeout=HARD_KILL_SECONDS,
            )
        except asyncio.TimeoutError:
            self._sem.release()
            self._sessions.pop(hermes_id, None)
            await self._frontmatter.submit(
                FrontmatterUpdate(req.block_id, {"symphony_state": "Failed"})
            )
            return {
                "dispatch_id": hermes_id,
                "pi_session_id": session.pi_session_id or "",
                "status": "failed",
                "workspace_path": workspace,
                "error": "hard_kill_30min",
            }
        except Exception as exc:
            self._sem.release()
            self._sessions.pop(hermes_id, None)
            return {
                "dispatch_id": hermes_id,
                "pi_session_id": session.pi_session_id or "",
                "status": "failed",
                "workspace_path": workspace,
                "error": f"ssh_disconnect: {exc!r}",
            }
        finally:
            pass

        return {
            "dispatch_id": hermes_id,
            "pi_session_id": pi_session or "",
            "status": "running" if pi_session else "failed",
            "workspace_path": workspace,
        }

    def _run_blocking(
        self,
        req: DispatchRequest,
        session: RemoteSession,
        workspace: str,
    ) -> str | None:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            hostname=self._target.host,
            username=self._target.user,
            key_filename=str(Path(self._target.key_path).expanduser()),
            timeout=20,
        )
        try:
            transport = client.get_transport()
            assert transport is not None
            transport.set_keepalive(int(HEARTBEAT_SECONDS))
            chan = transport.open_session()
            chan.exec_command(self._build_remote_command(req, workspace))
            return self._consume_until_session(chan, session)
        finally:
            client.close()
            self._sem_release_threadsafe()

    def _sem_release_threadsafe(self) -> None:
        try:
            self._sem.release()
        except ValueError:
            pass

    def _consume_until_session(
        self,
        chan: "paramiko.Channel",
        session: RemoteSession,
    ) -> str | None:
        buf = b""
        deadline = time.monotonic() + HARD_KILL_SECONDS
        while True:
            if time.monotonic() > deadline:
                chan.close()
                return None
            if chan.exit_status_ready() and not chan.recv_ready():
                return None
            if not chan.recv_ready():
                time.sleep(0.05)
                continue
            chunk = chan.recv(4096)
            if not chunk:
                return None
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode("utf-8", errors="replace")
                session.stdout_tail.append(line)
                pi_id = self._maybe_session_id(line)
                if pi_id:
                    session.pi_session_id = pi_id
                    asyncio.run_coroutine_threadsafe(
                        self._frontmatter.submit(
                            FrontmatterUpdate(
                                session.block_id,
                                {"symphony_session_id": pi_id},
                            )
                        ),
                        asyncio.get_event_loop(),
                    )
                    return pi_id

    @staticmethod
    def _maybe_session_id(line: str) -> str | None:
        trimmed = line.strip()
        if not trimmed:
            return None
        try:
            obj = json.loads(trimmed)
        except json.JSONDecodeError:
            return None
        if not isinstance(obj, dict):
            return None
        if obj.get("type") != "session":
            return None
        pid = obj.get("id")
        return pid if isinstance(pid, str) and pid else None
