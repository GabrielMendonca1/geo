#!/usr/bin/env python3
import base64
import ctypes
import ctypes.util
import fcntl
import hashlib
import hmac
import http.client
import json
import os
import pty
import queue
import re
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TASKS_DIR = os.path.expanduser(os.environ.get("GEO_TASKS_DIR", "~/Vault/Tasks"))
HEALTH_DIR = os.path.expanduser(os.environ.get("GEO_HEALTH_DIR", "~/Vault/Health"))
DISPATCHES_DIR = os.path.expanduser(os.environ.get("GEO_DISPATCHES_DIR", "~/.hermes/dispatches"))
BIND = os.environ.get("GEO_BRIDGE_BIND", "100.123.44.9")
PORT = int(os.environ.get("GEO_BRIDGE_PORT", "8643"))
TOKEN_FILE = os.path.expanduser(os.environ.get("GEO_BRIDGE_TOKEN_FILE", "~/.hermes/geobridge.token"))
HERMES_URL = os.environ.get("HERMES_URL", "http://127.0.0.1:8642")
HERMES_KEY_FILE = os.path.expanduser(os.environ.get("HERMES_KEY_FILE", "~/.hermes/api_server.key"))
LOG_PATH = os.path.expanduser("~/Library/Logs/geobridge.log")

TERM_ENABLED = os.environ.get("GEO_TERM_ENABLED", "0") == "1"
TERM_TMUX = os.environ.get("GEO_TERM_TMUX", "/opt/homebrew/bin/tmux")
GEO_TERM_PROFILE_MAC = os.environ.get("GEO_TERM_PROFILE_MAC", "")
TERM_SHELL = os.environ.get("GEO_TERM_SHELL", "")
TERM_SESSION = os.environ.get("GEO_TERM_SESSION", "mobile")
TERM_SESSION_RE = re.compile(r"\A[A-Za-z0-9_-]{1,32}\Z")
AGENT_SESSION = os.environ.get("GEO_AGENT_SESSION", "garime-agent")
if not TERM_SESSION_RE.match(AGENT_SESSION):
    AGENT_SESSION = "garime-agent"
TERM_TOKEN_FILE = os.path.expanduser(os.environ.get("GEO_BRIDGE_TERM_TOKEN_FILE", "~/.hermes/geobridge.term.token"))
TERM_IDLE_SECONDS = 600
TERM_REPLAY_BYTES = int(os.environ.get("GEO_TERM_REPLAY_BYTES", "262144"))
TERM_UPLOAD_DIR = os.path.expanduser(os.environ.get("GEO_TERM_UPLOAD_DIR", "~/garime-uploads"))
TERM_UPLOAD_MAX = 32 * 1024 * 1024
TERM_UPLOAD_NAME_RE = re.compile(r"\A[A-Za-z0-9._-]{1,80}\Z")
TERM_ATTACH_PROJECT_RE = re.compile(r"\A[A-Za-z0-9_-]{1,24}\Z")
TERM_ATTACH_PANE_RE = re.compile(r"\Aw[0-9]{1,3}:p[0-9]{1,3}\Z")
TERM_ATTACH_AGENT_PREFIX = "ag-"
TERM_ATTACH_HERDR_PREFIX = "hd-"
TERM_ATTACH_SSH_TIMEOUT = os.environ.get("GEO_TERM_ATTACH_SSH_TIMEOUT", "4")
TERM_PREVIEW_LINES = 12
TERM_PREVIEW_MAX_LINES = 40
STATUS_UNITS = [u for u in os.environ.get("GEO_STATUS_UNITS", "garime-wa syncthing-garime").split() if u]
STATUS_MAC_ADDR = (os.environ.get("GEO_STATUS_MAC_HOST", "100.123.44.9"), 22)
STATUS_MAC_USER = os.environ.get("GEO_STATUS_MAC_USER", "biel")
STATUS_HERDR = os.environ.get("GEO_STATUS_HERDR", "/opt/homebrew/bin/herdr")
STATUS_SSH = os.environ.get("GEO_STATUS_SSH", "ssh")
SSH_CONTROL_DIR = os.path.expanduser("~/.garime/ssh")
SSH_CONTROL_PATH = os.path.join(SSH_CONTROL_DIR, "%r@%h:%p")
try:
    os.makedirs(SSH_CONTROL_DIR, mode=0o700, exist_ok=True)
except OSError:
    pass
STATUS_AGENTS_TTL = float(os.environ.get("GEO_STATUS_AGENTS_TTL", "10"))
STATUS_AGENTS_TIMEOUT = float(os.environ.get("GEO_STATUS_AGENTS_TIMEOUT", "12"))
STATUS_VM_AGENTS = ("pi", "prime-agent", "claude", "codex", "kimi", "opencode")
STATUS_SESSION_MARK = "##session "
AGENT_CHAT_LIMIT = int(os.environ.get("GEO_AGENT_CHAT_LIMIT", "40"))
AGENT_CHAT_MAX_LIMIT = int(os.environ.get("GEO_AGENT_CHAT_MAX_LIMIT", "200"))
AGENT_CHAT_TEXT_MAX = int(os.environ.get("GEO_AGENT_CHAT_TEXT_MAX", "2000"))
AGENT_CHAT_TAIL_BYTES = int(os.environ.get("GEO_AGENT_CHAT_TAIL_BYTES", "131072"))
AGENT_CHAT_TIMEOUT = float(os.environ.get("GEO_AGENT_CHAT_TIMEOUT", "12"))
AGENT_STREAM_TICK_S = float(os.environ.get("GEO_AGENT_STREAM_TICK_S", "0.5"))
AGENT_STREAM_MAX_S = float(os.environ.get("GEO_AGENT_STREAM_MAX_S", "300"))
AGENT_PROMPT_MAX = 8192
AGENT_PROMPT_TIMEOUT = float(os.environ.get("GEO_AGENT_PROMPT_TIMEOUT", "15"))
AGENT_COMMANDS_TTL = float(os.environ.get("GEO_AGENT_COMMANDS_TTL", "120"))
AGENT_COMMANDS_TIMEOUT = float(os.environ.get("GEO_AGENT_COMMANDS_TIMEOUT", "15"))
AGENT_COMMANDS_HEAD_LINES = int(os.environ.get("GEO_AGENT_COMMANDS_HEAD_LINES", "12"))
AGENT_COMMANDS_DESC_MAX = 160
AGENT_COMMANDS_WIRE_MAX = 400
AGENT_COMMANDS_CACHE_MAX = int(os.environ.get("GEO_AGENT_COMMANDS_CACHE_MAX", "64"))
AGENT_COMMANDS_END = "Z"
AGENT_COMMAND_NAME_RE = re.compile(r"\A[A-Za-z0-9._-]{1,64}\Z")
AGENT_WORK_TTL = float(os.environ.get("GEO_AGENT_WORK_TTL", "5"))
AGENT_WORK_TIMEOUT = float(os.environ.get("GEO_AGENT_WORK_TIMEOUT", "12"))
AGENT_WORK_RUNNING_WINDOW = float(os.environ.get("GEO_AGENT_WORK_RUNNING_WINDOW", "120"))
AGENT_WORK_STALE_AFTER = float(os.environ.get("GEO_AGENT_WORK_STALE_AFTER", "3600"))
AGENT_WORK_WORKFLOWS_MAX = int(os.environ.get("GEO_AGENT_WORK_WORKFLOWS_MAX", "10"))
AGENT_WORK_SUBAGENTS_MAX = int(os.environ.get("GEO_AGENT_WORK_SUBAGENTS_MAX", "20"))
AGENT_WORK_SCAN_MAX = int(os.environ.get("GEO_AGENT_WORK_SCAN_MAX", "200"))
AGENT_WORK_CACHE_MAX = int(os.environ.get("GEO_AGENT_WORK_CACHE_MAX", "64"))
AGENT_WORK_LINE_SCAN = 400
AGENT_WORK_END = "Z"
AGENT_WORK_ID_RE = re.compile(r"\A[A-Za-z0-9._-]{1,80}\Z")
AGENT_WORK_TYPE_RE = re.compile(r"\A[A-Za-z0-9._:-]{1,64}\Z")
AGENT_UPLOAD_DIR = os.environ.get("GEO_AGENT_UPLOAD_DIR", "garime-uploads")
AGENT_UPLOAD_MAX = 32 * 1024 * 1024
AGENT_UPLOAD_TIMEOUT = float(os.environ.get("GEO_AGENT_UPLOAD_TIMEOUT", "120"))
AGENT_UPLOAD_PATH_RE = re.compile(r"\A/[^\x00-\x1f]{1,500}\Z")
AGENT_SESSION_ID_RE = re.compile(r"\A[A-Za-z0-9._-]{1,80}\Z")
AGENT_SESSION_PATH_RE = re.compile(r"\A/[^\x00-\x1f]{1,500}\.jsonl\Z")
AGENT_CHAT_DROP_TYPES = ("attachment", "custom-title", "mode", "last-prompt", "summary", "system")
AGENT_RESOLVED_MARK = "R\t"
AGENT_RESOLVED_KINDS = ("reported", "fallback")
AGENT_WORK_LIVE_KINDS = ("alive", "unknown", "dead")
AGENT_PROJECT_DIR_RE = re.compile(r"[^A-Za-z0-9-]")
AGENT_PI_SESSIONS_DIR = os.environ.get("GEO_AGENT_PI_SESSIONS_DIR", "/mnt/garime/pi/agent/sessions")
AGENT_PRIME_SESSIONS_DIR = os.environ.get("GEO_AGENT_PRIME_SESSIONS_DIR", "")
AGENT_PRIME_SCAN_MAX = int(os.environ.get("GEO_AGENT_PRIME_SCAN_MAX", "50"))
AGENT_PI_SKILLS_DIR = os.environ.get("GEO_AGENT_PI_SKILLS_DIR", "/mnt/garime/pi/skills")
AGENT_VM_DEPTH = int(os.environ.get("GEO_AGENT_VM_DEPTH", "3"))
AGENT_PROMPT_CONTROL_RE = re.compile(r"[\x00-\x09\x0b-\x1f\x7f]")
AGENT_ASK_SCAN_LINES = int(os.environ.get("GEO_AGENT_ASK_SCAN_LINES", "60"))
AGENT_ASK_TIMEOUT = float(os.environ.get("GEO_AGENT_ASK_TIMEOUT", "5"))
AGENT_ASK_OPTION_RE = re.compile("\\A(?P<cursor>[\u276f\u25b6\u00bb\u203a]\\s+)?(?P<index>[0-9]{1,2})\\.\\s+(?P<label>\\S.*)\\Z")
AGENT_ASK_OPTION_GAP = int(os.environ.get("GEO_AGENT_ASK_OPTION_GAP", "6"))
AGENT_ASK_BORDER = "\u2502|"
AGENT_ASK_CHROME_RE = re.compile("\\A[\u2500-\u257f\\s]+\\Z")
AGENT_ASK_AFFORD_RE = re.compile(
    "(?i)(?:\\A|[\\s·|(])(?:press\\s+)?(?:esc(?:ape)?|enter|return)\\s+to\\s+(?!interrupt\\b)\\S"
)
AGENT_ASK_HINT_RE = re.compile(
    "(?i)(?:\\A|[\\s·|(])"
    "(?:[←-⇿/]+|(?:ctrl|alt|opt|option|shift|cmd|meta)\\+\\S+"
    "|esc(?:ape)?|enter|return|tab|space|arrows?|[a-z0-9])"
    "\\s+to\\s+\\S"
)
AGENT_ASK_TAIL_BODY = int(os.environ.get("GEO_AGENT_ASK_TAIL_BODY", "4"))
AGENT_ASK_TRANSCRIPT_RE = re.compile(
    "\\A[\u276f\u25b6\u00bb\u203a\u273b\u23bf\u23f8\u2022\u258e>$#%]|\\A[0-9]{1,2}\\.\\s"
)
AGENT_ASK_QUESTION_LOOKBACK = 5
AGENT_ASK_QUESTION_MAX = 240
AGENT_ASK_LABEL_MAX = 120
AGENT_ASK_HINT_MAX = 1200
AGENT_ASK_MAX_OPTIONS = 9
AGENT_ASK_PERMISSION_RE = re.compile(r"(?i)proceed|permission|allow|trust|do you want|prosseguir|permit")
AGENT_ANSWER_BODY_MAX = 1024
AGENT_INTERRUPT_KEY = os.environ.get("GEO_AGENT_INTERRUPT_KEY", "Escape")
AGENT_INTERRUPT_KEY_MAC = os.environ.get("GEO_AGENT_INTERRUPT_KEY_MAC", "esc")
AGENT_ASK_MAC_TIMEOUT = float(os.environ.get("GEO_AGENT_ASK_MAC_TIMEOUT", "12"))
AGENT_ASK_MAC_READ = (("read", ("--source", "visible", "--format", "text")),)
AGENT_WATCH_ENABLED = os.environ.get("GEO_AGENT_WATCH", "0") == "1"
AGENT_WATCH_INTERVAL = max(5.0, float(os.environ.get("GEO_AGENT_WATCH_INTERVAL", "30")))
AGENT_WATCH_COOLDOWN = float(os.environ.get("GEO_AGENT_WATCH_COOLDOWN", "300"))
AGENT_WATCH_MAX_HOUR = int(os.environ.get("GEO_AGENT_WATCH_MAX_HOUR", "12"))
AGENT_WATCH_HOUR_WINDOW = 3600.0
AGENT_WATCH_SEEN_TTL = float(os.environ.get("GEO_AGENT_WATCH_SEEN_TTL", "86400"))
AGENT_WATCH_MIN_COLS = int(os.environ.get("GEO_AGENT_WATCH_MIN_COLS", "40"))
AGENT_WATCH_LABEL_MAX = 80
AGENT_WATCH_SPACE_RE = re.compile(r"\s+")
AGENT_WATCH_PATH_RE = re.compile(r"\S*/\S*")
AGENT_WATCH_STATE_PATH = os.path.expanduser(
    os.environ.get("GEO_AGENT_WATCH_STATE", "~/.garime/agent-watch.json")
)
WA_OUTBOX_DIR = os.environ.get("GEO_WA_OUTBOX", "/mnt/garime/pi/wa-outbox")
AGENT_START_COMMANDS = {"claude": "~/.local/bin/claude", "pi": "/usr/bin/pi", "codex": "codex"}
AGENT_COMMANDS_BUILTIN = {
    "claude": (
        ("clear", "limpa o contexto da conversa"),
        ("compact", "compacta o contexto da conversa"),
    ),
}
AGENT_PUBLIC_KEYS = ("host", "agent", "status", "title", "project", "pane", "cwd")
PANE_PUBLIC_KEYS = ("pane", "agent", "status", "title", "cwd", "tab")

ID_RE = re.compile(r"\A[A-Za-z0-9._-]+\Z")
DATE_RE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")
TASK_ROUTE = re.compile(r"^/tasks/([^/]+)/(complete|reopen)$")
TASK_DELETE_ROUTE = re.compile(r"^/tasks/([^/]+)$")
DISPATCH_STREAM_ROUTE = re.compile(r"^/dispatches/([^/]+)/stream$")

TOKEN = ""
TERM_TOKEN = ""
LOG_LOCK = threading.Lock()
TERM_REGISTRY = {}
TERM_REGISTRY_LOCK = threading.Lock()
AGENTS_CACHE = {"at": 0.0, "value": [], "panes": [], "mac_ok": False}
AGENTS_CACHE_LOCK = threading.Lock()
AGENTS_REFRESH_LOCK = threading.Lock()
COMMANDS_CACHE = {}
COMMANDS_CACHE_LOCK = threading.Lock()
COMMANDS_REFRESH_LOCKS = {}
WORK_CACHE = {}
WORK_CACHE_LOCK = threading.Lock()
WORK_REFRESH_LOCKS = {}
WATCH_SEEN = {}
WATCH_SENT_AT = {}
WATCH_HOUR = []
WATCH_LOADED = [False]


class TermSubscriber:
    def __init__(self):
        self.q = queue.Queue(maxsize=256)
        self.dropped = False


class TermSession:
    def __init__(self, master_fd, pid, session, tty=None):
        self.master_fd = master_fd
        self.pid = pid
        self.session = session
        self.tty = tty
        self.write_lock = threading.Lock()
        self.buffer = bytearray()
        self.buffer_lock = threading.Lock()
        self.subscribers = []
        self.subscribers_lock = threading.Lock()
        self.last_subscriber_gone = time.monotonic()
        self.alive = True
        self.teardown_lock = threading.Lock()

    def start(self):
        threading.Thread(target=self._read_loop, daemon=True).start()

    def subscribe(self, sub):
        with self.buffer_lock:
            with self.subscribers_lock:
                self.subscribers.append(sub)
            if not self.alive:
                try:
                    sub.q.put_nowait(None)
                except queue.Full:
                    sub.dropped = True
            return bytes(self.buffer)

    def unsubscribe(self, sub):
        with self.subscribers_lock:
            if sub in self.subscribers:
                self.subscribers.remove(sub)
            empty = not self.subscribers
        if empty:
            self.last_subscriber_gone = time.monotonic()

    def _broadcast(self, item):
        with self.subscribers_lock:
            dead = []
            for sub in list(self.subscribers):
                try:
                    sub.q.put_nowait(item)
                except queue.Full:
                    sub.dropped = True
                    dead.append(sub)
            for sub in dead:
                self.subscribers.remove(sub)
            empty = not self.subscribers
        if dead and empty:
            self.last_subscriber_gone = time.monotonic()

    def write(self, data):
        with self.write_lock:
            if self.master_fd < 0:
                raise OSError("closed")
            os.write(self.master_fd, data)

    def set_winsize(self, rows, cols):
        with self.write_lock:
            if self.master_fd < 0:
                raise OSError("closed")
            fcntl.ioctl(self.master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def teardown(self):
        with self.teardown_lock:
            if not self.alive:
                return
            self.alive = False
        with TERM_REGISTRY_LOCK:
            if TERM_REGISTRY.get(self.session) is self:
                del TERM_REGISTRY[self.session]
        with self.buffer_lock:
            self._broadcast(None)
        try:
            os.kill(self.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass

    def _read_loop(self):
        try:
            while self.alive:
                try:
                    r, _, _ = select.select([self.master_fd], [], [], 0.5)
                except OSError:
                    return
                if r:
                    try:
                        data = os.read(self.master_fd, 65536)
                    except OSError:
                        data = b""
                    if not data:
                        return
                    with self.buffer_lock:
                        self.buffer += data
                        excess = len(self.buffer) - TERM_REPLAY_BYTES
                        if excess > 0:
                            del self.buffer[:excess]
                        self._broadcast(data)
                with self.subscribers_lock:
                    idle = not self.subscribers
                if idle and time.monotonic() - self.last_subscriber_gone > TERM_IDLE_SECONDS:
                    return
        finally:
            self.teardown()
            with self.write_lock:
                fd = self.master_fd
                self.master_fd = -1
                try:
                    os.close(fd)
                except OSError:
                    pass


def term_child_tty(pid, master_fd):
    try:
        return os.readlink("/proc/%d/fd/0" % pid)
    except OSError:
        pass
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        libc.ptsname.restype = ctypes.c_char_p
        name = libc.ptsname(ctypes.c_int(master_fd))
        return name.decode() if name else None
    except Exception:
        return None


def term_target(name):
    return "=" + name


def term_pane_target(name):
    return "=" + name + ":"


def term_registry_ttys():
    with TERM_REGISTRY_LOCK:
        return {sess.tty for sess in TERM_REGISTRY.values() if sess.tty}


def term_attach_name(prefix, project, pane=""):
    suffix = ("-" + pane.replace(":", "")) if pane else ""
    budget = 32 - len(prefix) - len(suffix)
    if len(project) <= budget:
        return prefix + project + suffix
    digest = hashlib.sha1(project.encode()).hexdigest()[:4]
    return prefix + project[:budget - 5] + "-" + digest + suffix


def herdr_attach_script(project, pane=""):
    parts = [
        "export PATH=%s:$PATH;" % shlex.quote(os.path.dirname(STATUS_HERDR) or "/usr/bin"),
        shlex.quote(STATUS_HERDR), "--session", shlex.quote(project),
    ]
    if pane:
        parts += ["agent", "attach", shlex.quote(pane)]
    return " ".join(parts)


def herdr_attach_command(project, pane=""):
    return [
        STATUS_SSH, "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=" + TERM_ATTACH_SSH_TIMEOUT,
        "%s@%s" % (STATUS_MAC_USER, STATUS_MAC_ADDR[0]),
        herdr_attach_script(project, pane),
    ]


def term_spawn(session, ignore_size=False, command=None):
    executable = TERM_TMUX
    if command is None and session == "mac" and GEO_TERM_PROFILE_MAC:
        command = [os.path.expanduser(GEO_TERM_PROFILE_MAC)]
    args = [TERM_TMUX, "-u", "new-session", "-A", "-s", session] + list(command or []) + [
        ";", "set-option", "mouse", "on",
        ";", "set-option", "-g", "history-limit", "100000",
        ";", "set-option", "-g", "status-style", "bg=colour233,fg=colour250",
        ";", "set-option", "-g", "status-right", " #S ",
        ";", "set-option", "-g", "status-left", " #I:#W ",
        ";", "bind-key", "-n", "PageUp", "copy-mode", "-u",
    ]
    if ignore_size:
        args += [";", "refresh-client", "-f", "ignore-size"]
    child_env = dict(os.environ)
    child_env.setdefault("TERM", "xterm-256color")
    if TERM_SHELL:
        child_env["SHELL"] = TERM_SHELL
    pid, master_fd = pty.fork()
    if pid == 0:
        try:
            os.execve(executable, args, child_env)
        except BaseException:
            os._exit(127)
    return TermSession(master_fd, pid, session, term_child_tty(pid, master_fd))


def term_get_or_spawn(session, ignore_size=False, command=None):
    with TERM_REGISTRY_LOCK:
        sess = TERM_REGISTRY.get(session)
        if sess is not None and sess.alive:
            return sess
        sess = term_spawn(session, ignore_size, command)
        TERM_REGISTRY[session] = sess
    sess.start()
    return sess


def status_mac_online():
    try:
        with socket.create_connection(STATUS_MAC_ADDR, timeout=1):
            return True
    except Exception:
        return False


def herdr_remote_script():
    return (
        "export PATH=%s:$PATH; "
        "for s in $(%s session list | awk 'NR>1 && $2==\"running\" {print $1}'); do "
        "echo \"%s$s\"; %s --session \"$s\" agent list; %s --session \"$s\" pane list; done"
    ) % (
        os.path.dirname(STATUS_HERDR) or "/usr/bin", STATUS_HERDR,
        STATUS_SESSION_MARK, STATUS_HERDR, STATUS_HERDR,
    )


def parse_herdr_scan(text):
    agents = []
    panes = []
    project = ""
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith(STATUS_SESSION_MARK):
            project = line[len(STATUS_SESSION_MARK):].strip()
            continue
        try:
            payload = json.loads(line)
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        result = payload.get("result")
        if not isinstance(result, dict):
            continue
        entries = result.get("agents")
        if isinstance(entries, list):
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                name = entry.get("agent")
                if not isinstance(name, str) or not name:
                    continue
                title = entry.get("terminal_title_stripped") or entry.get("terminal_title") or ""
                status = entry.get("agent_status") or "unknown"
                pane = entry.get("pane_id")
                session = entry.get("agent_session")
                agents.append({
                    "host": "mac",
                    "agent": name,
                    "status": status if isinstance(status, str) else "unknown",
                    "title": title if isinstance(title, str) else "",
                    "project": project,
                    "pane": pane if isinstance(pane, str) else "",
                    "cwd": entry.get("cwd") if isinstance(entry.get("cwd"), str) else "",
                    "session": session if isinstance(session, dict) else None,
                })
            continue
        entries = result.get("panes")
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            pane = entry.get("pane_id")
            if not isinstance(pane, str) or not pane:
                continue
            name = entry.get("agent")
            title = entry.get("terminal_title_stripped") or entry.get("terminal_title") or ""
            status = entry.get("agent_status") or "unknown"
            panes.append({
                "project": project,
                "pane": pane,
                "agent": name if isinstance(name, str) else "",
                "status": status if isinstance(status, str) else "unknown",
                "title": title if isinstance(title, str) else "",
                "cwd": entry.get("cwd") if isinstance(entry.get("cwd"), str) else "",
                "tab": entry.get("tab_id") if isinstance(entry.get("tab_id"), str) else "",
            })
    return agents, panes


def status_mac_scan():
    try:
        proc = subprocess.run(
            [
                STATUS_SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                "-o", "ControlMaster=auto", "-o", "ControlPath=" + SSH_CONTROL_PATH, "-o", "ControlPersist=120",
                "%s@%s" % (STATUS_MAC_USER, STATUS_MAC_ADDR[0]),
                herdr_remote_script(),
            ],
            capture_output=True, timeout=STATUS_AGENTS_TIMEOUT,
        )
    except Exception:
        return False, [], []
    agents, panes = parse_herdr_scan(proc.stdout.decode("utf-8", "replace"))
    return proc.returncode == 0 or bool(agents) or bool(panes), agents, panes


def vm_process_tree():
    out = subprocess.run(
        ["ps", "-eo", "pid=", "-o", "ppid=", "-o", "comm="], capture_output=True, timeout=5
    ).stdout.decode("utf-8", "replace")
    names = {}
    children = {}
    for line in out.split("\n"):
        fields = line.split(None, 2)
        if len(fields) < 3:
            continue
        try:
            pid = int(fields[0])
            ppid = int(fields[1])
        except ValueError:
            continue
        names[pid] = os.path.basename(fields[2].strip().split()[0])
        children.setdefault(ppid, []).append(pid)
    return names, children


def vm_descendants(pid, children, depth=AGENT_VM_DEPTH):
    seen = set()
    level = [pid]
    for _ in range(depth):
        nxt = []
        for parent in level:
            for child in children.get(parent, []):
                if child in seen or child == parent:
                    continue
                seen.add(child)
                nxt.append(child)
        if not nxt:
            break
        level = nxt
    return seen


def vm_pane_agent(pid, command, names, children):
    if os.path.basename(command) in STATUS_VM_AGENTS:
        return os.path.basename(command)
    for child in sorted(vm_descendants(pid, children)):
        name = names.get(child, "")
        if name in STATUS_VM_AGENTS:
            return name
    return ""


def vm_panes(args):
    proc = subprocess.run(
        [TERM_TMUX, "list-panes"] + args + [
            "-F", "#{session_name}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}"
                  "\t#{pane_active}\t#{window_active}",
        ],
        capture_output=True, timeout=5,
    )
    if proc.returncode != 0:
        return None
    panes = []
    for line in proc.stdout.decode("utf-8", "replace").split("\n"):
        fields = line.split("\t")
        if len(fields) != 6:
            continue
        try:
            pid = int(fields[1])
        except ValueError:
            continue
        panes.append((fields[0], pid, fields[2], fields[3], fields[4], fields[5]))
    return panes


def vm_session_agent(session):
    panes = vm_panes(["-t", term_pane_target(session)])
    if panes is None:
        return None
    names, children = vm_process_tree()
    for _, pid, command, path, active, _win in panes:
        if active != "1":
            continue
        agent = vm_pane_agent(pid, command, names, children)
        if agent:
            return agent, path
    return "", ""


def vm_pid_sessions(children):
    try:
        panes = vm_panes(["-a"])
    except Exception:
        return {}
    if not panes:
        return {}
    sessions = {}
    for name, pid, _, _, active, window in panes:
        if active != "1" or window != "1":
            continue
        sessions.setdefault(pid, name)
        for child in vm_descendants(pid, children):
            sessions.setdefault(child, name)
    return sessions


def status_vm_agents():
    try:
        names, children = vm_process_tree()
    except Exception:
        return []
    sessions = vm_pid_sessions(children)
    parents = {}
    for parent, kids in children.items():
        for child in kids:
            parents[child] = parent
    agents = []
    for pid in sorted(names):
        name = names[pid]
        if name not in STATUS_VM_AGENTS:
            continue
        if names.get(parents.get(pid)) == name:
            continue
        agents.append({
            "host": "vm",
            "agent": name,
            "status": "running",
            "title": "",
            "project": "",
            "pane": "",
            "cwd": "",
            "session": sessions.get(pid, ""),
        })
    return agents


def agent_chat_status(cwd, fresh_seconds=25):
    """Status real do agente: 'working' se o transcript foi escrito há pouco, 'idle' caso contrário."""
    try:
        name = agent_pi_dir(cwd)
        if not name:
            return "unknown"
        candidates = (
            os.path.join(AGENT_PI_SESSIONS_DIR, name),
            os.path.expanduser("~/.pi/agent/sessions/" + name),
        )
        for d in candidates:
            try:
                names = [n for n in os.listdir(d) if n.endswith(".jsonl")]
            except OSError:
                continue
            if not names:
                continue
            newest = max(os.path.getmtime(os.path.join(d, n)) for n in names)
            return "working" if time.time() - newest <= fresh_seconds else "idle"
    except Exception:
        pass
    return "unknown"


def agent_session_state():
    try:
        found = vm_session_agent(AGENT_SESSION)
    except Exception:
        found = None
    agent = found[0] if found else ""
    state = {"session": AGENT_SESSION, "running": bool(agent), "agent": agent}
    if agent and found[1]:
        state["busy"] = agent_chat_status(found[1]) == "working"
    return state


def status_scan_full():
    now = time.monotonic()
    with AGENTS_CACHE_LOCK:
        if AGENTS_CACHE["at"] and now - AGENTS_CACHE["at"] < STATUS_AGENTS_TTL:
            return AGENTS_CACHE["mac_ok"], list(AGENTS_CACHE["value"]), list(AGENTS_CACHE["panes"])
    with AGENTS_REFRESH_LOCK:
        with AGENTS_CACHE_LOCK:
            if AGENTS_CACHE["at"] and time.monotonic() - AGENTS_CACHE["at"] < STATUS_AGENTS_TTL:
                return AGENTS_CACHE["mac_ok"], list(AGENTS_CACHE["value"]), list(AGENTS_CACHE["panes"])
        mac_ok, mac, panes = status_mac_scan()
        agents = mac + status_vm_agents()
        with AGENTS_CACHE_LOCK:
            AGENTS_CACHE["at"] = time.monotonic()
            AGENTS_CACHE["value"] = agents
            AGENTS_CACHE["panes"] = panes
            AGENTS_CACHE["mac_ok"] = mac_ok
        return mac_ok, list(agents), list(panes)


def status_agents():
    return status_scan_full()[1]


def agent_public(entry):
    body = {key: entry.get(key, "") for key in AGENT_PUBLIC_KEYS}
    if entry.get("host") == "vm":
        session = entry.get("session")
        body["session"] = session if isinstance(session, str) else ""
    return body


def agent_find(agents, project, pane):
    for entry in agents:
        if entry.get("host") == "mac" and entry.get("project") == project and entry.get("pane") == pane:
            return entry
    return None


def pane_public(entry):
    return {key: entry.get(key, "") for key in PANE_PUBLIC_KEYS}


def pane_find(panes, project, pane):
    for entry in panes:
        if entry.get("project") == project and entry.get("pane") == pane:
            return entry
    return None


def agent_project_dir(cwd):
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        return ""
    return AGENT_PROJECT_DIR_RE.sub("-", cwd)


def agent_pi_dir(cwd):
    project = agent_project_dir(cwd)
    # convenção do pi: /mnt/garime/Vault → --mnt-garime-Vault-- (traço duplo nas duas pontas)
    return ("-" + project + "--") if project else ""


def vm_agent_session(agent):
    if agent == "claude":
        return {"kind": "cwd", "value": ""}
    if agent == "pi":
        return {"kind": "pi", "value": ""}
    if agent == "prime-agent":
        return {"kind": "prime", "value": ""}
    return None


def agent_transcript_script(session, cwd=""):
    if not isinstance(session, dict):
        return ""
    kind = session.get("kind")
    value = session.get("value")
    if kind == "cwd":
        project = agent_project_dir(cwd)
        if not project:
            return ""
        inner = (
            'd="$HOME"/.claude/projects/%s; '
            'c=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -n 1); '
            'if [ -f "$c" ]; then printf "R\\tfallback\\n"; tail -c %d "$c"; fi; exit 0'
        ) % (shlex.quote(project), AGENT_CHAT_TAIL_BYTES)
        return "/bin/sh -c " + shlex.quote(inner)
    if kind == "pi":
        name = agent_pi_dir(cwd)
        if not name:
            return ""
        inner = (
            'd=%s/%s; [ -d "$d" ] || d="$HOME"/.pi/agent/sessions/%s; '
            'c=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -n 1); '
            'if [ -f "$c" ]; then printf "R\\tfallback\\n"; tail -c %d "$c"; fi; exit 0'
        ) % (
            shlex.quote(AGENT_PI_SESSIONS_DIR), shlex.quote(name),
            shlex.quote(name), AGENT_CHAT_TAIL_BYTES,
        )
        return "/bin/sh -c " + shlex.quote(inner)
    if kind == "prime":
        if not isinstance(cwd, str) or not cwd.startswith("/"):
            return ""
        needles = ['"cwd":"' + cwd + '"']
        escaped = '"cwd":' + json.dumps(cwd)
        if escaped not in needles:
            needles.append(escaped)
        match = " ".join(["-e " + shlex.quote(n) for n in needles])
        parts = [
            "d=%s" % shlex.quote(AGENT_PRIME_SESSIONS_DIR),
            '[ -d "$d" ] || d="$HOME"/.prime/agent/sessions',
            'l=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -n %d)' % AGENT_PRIME_SCAN_MAX,
            'f=$(printf "%%s\\n" "$l" | while IFS= read -r c; do '
            '[ -f "$c" ] || continue; '
            'if head -n 1 "$c" | grep -qF %s; then printf "%%s\\n" "$c"; break; fi; done)'
            % match,
            'if [ -f "$f" ]; then printf "R\\tfallback\\n"; tail -c %d "$f"; fi'
            % AGENT_CHAT_TAIL_BYTES,
            "exit 0",
        ]
        return "/bin/sh -c " + shlex.quote("; ".join(parts))
    if not isinstance(value, str):
        return ""
    if kind == "id" and AGENT_SESSION_ID_RE.match(value):
        parts = [
            'f=""',
            "r=reported",
            'for c in "$HOME"/.claude/projects/*/%s.jsonl; do '
            'if [ -f "$c" ]; then f="$c"; break; fi; done' % shlex.quote(value),
        ]
        project = agent_project_dir(cwd)
        if project:
            parts.append(
                'if [ -z "$f" ]; then d="$HOME"/.claude/projects/%s; '
                'c=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -n 1); '
                'if [ -f "$c" ]; then f="$c"; r=fallback; fi; fi' % shlex.quote(project)
            )
        parts.append(
            'if [ -n "$f" ]; then printf "R\\t%%s\\n" "$r"; tail -c %d "$f"; fi'
            % AGENT_CHAT_TAIL_BYTES
        )
        parts.append("exit 0")
        return "/bin/sh -c " + shlex.quote("; ".join(parts))
    if kind == "path" and AGENT_SESSION_PATH_RE.match(value):
        inner = (
            'f=%s; r=reported; '
            'if [ ! -f "$f" ]; then d=${f%%/*}; [ -n "$d" ] || d=/; '
            'c=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -n 1); '
            'if [ -f "$c" ]; then f="$c"; r=fallback; fi; fi; '
            'if [ -f "$f" ]; then printf "R\\t%%s\\n" "$r"; tail -c %d "$f"; fi; exit 0'
        ) % (shlex.quote(value), AGENT_CHAT_TAIL_BYTES)
        return "/bin/sh -c " + shlex.quote(inner)
    return ""


def agent_chat_resolved(text):
    head, sep, rest = text.partition("\n")
    if sep and head.startswith(AGENT_RESOLVED_MARK):
        tag = head[len(AGENT_RESOLVED_MARK):].strip()
        if tag in AGENT_RESOLVED_KINDS:
            return tag, rest
    return "", text


def agent_prompt_script(project, pane, text):
    return "export PATH=%s:$PATH; %s --session %s agent prompt %s %s" % (
        shlex.quote(os.path.dirname(STATUS_HERDR) or "/usr/bin"),
        shlex.quote(STATUS_HERDR),
        shlex.quote(project),
        shlex.quote(pane),
        shlex.quote(text),
    )


def herdr_pane_script(project, pane, commands):
    parts = []
    for verb, args in commands:
        parts.append(" ".join([
            shlex.quote(STATUS_HERDR), "--session", shlex.quote(project),
            "pane", verb, shlex.quote(pane),
        ] + [shlex.quote(arg) for arg in args]))
    return "export PATH=%s:$PATH; %s" % (
        shlex.quote(os.path.dirname(STATUS_HERDR) or "/usr/bin"),
        " && ".join(parts),
    )


def agent_ssh(script, timeout, data=None):
    return subprocess.run(
        [
            STATUS_SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=" + TERM_ATTACH_SSH_TIMEOUT,
            "-o", "ControlMaster=auto", "-o", "ControlPath=" + SSH_CONTROL_PATH, "-o", "ControlPersist=120",
            "%s@%s" % (STATUS_MAC_USER, STATUS_MAC_ADDR[0]),
            script,
        ],
        input=data, capture_output=True, timeout=timeout,
    )


def agent_local(script, timeout, data=None):
    return subprocess.run(
        ["/bin/sh", "-c", script], input=data, capture_output=True, timeout=timeout,
    )


def agent_commands_awk():
    return (
        'FNR==1 { d=0 } '
        'd { next } '
        'FNR>%d { d=1; next } '
        '/^description:/ { s=$0; sub(/^description:[ \\t\\r]*/, "", s); gsub(/[\\t\\r]/, " ", s); '
        'printf "D\\t%%s\\t%%s\\n", FILENAME, substr(s, 1, %d); d=1 }'
    ) % (AGENT_COMMANDS_HEAD_LINES, AGENT_COMMANDS_WIRE_MAX)


def agent_commands_script(agent, cwd):
    globs = []
    if agent == "claude":
        globs.append(("user", '"$HOME"/.claude/skills', "*/SKILL.md"))
        if cwd.startswith("/"):
            root = shlex.quote(cwd)
            globs.append(("project", root + "/.claude/skills", "*/SKILL.md"))
            globs.append(("project", root + "/.claude/commands", "*.md"))
    elif agent == "pi":
        globs.append(("user", '"$HOME"/.pi/agent/skills', "*/SKILL.md"))
        globs.append(("user", '"$HOME"/.pi/agent/skills', "*.md"))
        globs.append(("user", shlex.quote(AGENT_PI_SKILLS_DIR), "*/SKILL.md"))
        globs.append(("user", shlex.quote(AGENT_PI_SKILLS_DIR), "*.md"))
    else:
        return ""
    parts = ['[ -n "$HOME" ] || exit 6', "set --"]
    for scope, base, pattern in globs:
        parts.append(
            'if [ -d %s ]; then [ -r %s ] && [ -x %s ] || exit 7; '
            'for f in %s/%s; do [ -f "$f" ] || continue; printf %s "$f"; set -- "$@" "$f"; done; fi'
            % (base, base, base, base, pattern, shlex.quote("F\\t" + scope + "\\t%s\\n"))
        )
    parts.append('if [ "$#" -gt 0 ]; then awk %s "$@" || exit 8; fi' % shlex.quote(agent_commands_awk()))
    parts.append("printf %s" % shlex.quote(AGENT_COMMANDS_END + "\\n"))
    return "/bin/sh -c " + shlex.quote("; ".join(parts))


def agent_command_name(path):
    base = os.path.basename(path)
    if base == "SKILL.md":
        name = os.path.basename(os.path.dirname(path))
    elif base.endswith(".md"):
        name = base[:-3]
    else:
        name = base
    if name in (".", "..") or not AGENT_COMMAND_NAME_RE.match(name):
        return ""
    return name


def agent_commands_parse(text):
    files = []
    descriptions = {}
    for line in text.split("\n"):
        kind, _, rest = line.partition("\t")
        if kind == "F":
            scope, _, path = rest.partition("\t")
            if path:
                files.append((scope, path))
        elif kind == "D":
            path, _, desc = rest.partition("\t")
            if path:
                descriptions[path] = desc.strip()[:AGENT_COMMANDS_DESC_MAX]
    found = {}
    for scope, path in files:
        name = agent_command_name(path)
        if not name:
            continue
        current = found.get(name)
        if current is not None and current["scope"] == "project":
            continue
        found[name] = {"name": name, "description": descriptions.get(path, ""), "scope": scope}
    return [found[name] for name in sorted(found)]


def agent_commands_complete(text):
    lines = text.rstrip("\n").split("\n")
    return lines[-1] == AGENT_COMMANDS_END


def agent_commands_lock(key):
    with COMMANDS_CACHE_LOCK:
        lock = COMMANDS_REFRESH_LOCKS.get(key)
        if lock is None:
            if len(COMMANDS_REFRESH_LOCKS) >= AGENT_COMMANDS_CACHE_MAX:
                for stale in [k for k in COMMANDS_REFRESH_LOCKS if k not in COMMANDS_CACHE]:
                    del COMMANDS_REFRESH_LOCKS[stale]
            lock = threading.Lock()
            COMMANDS_REFRESH_LOCKS[key] = lock
        return lock


def agent_commands_store(key, commands):
    with COMMANDS_CACHE_LOCK:
        COMMANDS_CACHE[key] = {"at": time.monotonic(), "value": commands}
        while len(COMMANDS_CACHE) > AGENT_COMMANDS_CACHE_MAX:
            oldest = min(COMMANDS_CACHE, key=lambda k: COMMANDS_CACHE[k]["at"])
            del COMMANDS_CACHE[oldest]


def agent_commands_fetch(key, script, runner=agent_ssh):
    now = time.monotonic()
    with COMMANDS_CACHE_LOCK:
        hit = COMMANDS_CACHE.get(key)
        if hit is not None and now - hit["at"] < AGENT_COMMANDS_TTL:
            return list(hit["value"])
    with agent_commands_lock(key):
        with COMMANDS_CACHE_LOCK:
            hit = COMMANDS_CACHE.get(key)
            if hit is not None and time.monotonic() - hit["at"] < AGENT_COMMANDS_TTL:
                return list(hit["value"])
        proc = runner(script, AGENT_COMMANDS_TIMEOUT)
        if proc.returncode != 0:
            return None
        out = proc.stdout.decode("utf-8", "replace")
        if not agent_commands_complete(out):
            return None
        commands = agent_commands_parse(out)
        agent_commands_store(key, commands)
        return list(commands)


def agent_upload_script(name):
    stem, ext = os.path.splitext(name)
    return (
        'umask 077; d="$HOME"/%s; mkdir -p "$d" || exit 3; p="$d"/%s; i=0; '
        'while [ -e "$p" ] || [ -L "$p" ]; do i=$((i+1)); '
        'if [ "$i" -gt 1000 ]; then exit 4; fi; p="$d"/%s-"$i"%s; done; '
        'set -C; cat > "$p" || exit 5; printf %%s"\\n" "$p"'
    ) % (shlex.quote(AGENT_UPLOAD_DIR), shlex.quote(name), shlex.quote(stem), shlex.quote(ext))


def agent_work_session_id(session):
    if not isinstance(session, dict) or session.get("kind") != "id":
        return ""
    value = session.get("value")
    if not isinstance(value, str) or not AGENT_SESSION_ID_RE.match(value):
        return ""
    return value


def agent_work_journal_awk():
    return (
        '{ s = substr($0, 1, %d); gsub(/[ \\t]*:[ \\t]*/, ":", s); '
        'if (!match(s, /"type":"[a-z_]+"/)) next; '
        't = substr(s, RSTART + 8, RLENGTH - 9); '
        'if (!match(s, /"agentId":"[A-Za-z0-9._-]+"/)) next; '
        'a = substr(s, RSTART + 11, RLENGTH - 12); '
        'if (t == "started") st[a] = 1; else if (t == "result") rs[a] = 1 } '
        'END { r = 0; d = 0; for (a in st) { if (a in rs) d++; else r++ } printf "%%d\\t%%d", r, d }'
    ) % AGENT_WORK_LINE_SCAN


def agent_work_meta_awk():
    return (
        '{ s = $0; gsub(/[ \\t]*:[ \\t]*/, ":", s); '
        'if (match(s, /"agentType":"[A-Za-z0-9._:-]+"/)) '
        '{ print substr(s, RSTART + 13, RLENGTH - 14); exit } }'
    )


def agent_work_ps_awk():
    return (
        '$1 == me || $2 == me || $1 == pa || $2 == pa { next } '
        'index($0, "subagents") { next } '
        'index($0, "claude") { a = 1 } '
        'END { if (a) print "alive"; else if (NR == 0) print "unknown"; else print "dead" }'
    )


def agent_work_script(session, cwd=""):
    project = agent_project_dir(cwd)
    if isinstance(session, dict) and session.get("kind") == "cwd":
        if not project:
            return ""
        parts = [
            '[ -n "$HOME" ] || exit 6',
            "r=fallback",
            'b=""',
            'd="$HOME"/.claude/projects/%s; '
            'c=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -n 1); '
            'if [ -f "$c" ]; then n=${c##*/}; n=${n%%.jsonl}; '
            'if [ -d "$d/$n" ]; then b="$d/$n"; fi; fi' % shlex.quote(project),
        ]
    else:
        value = agent_work_session_id(session)
        if not value:
            return ""
        parts = ['[ -n "$HOME" ] || exit 6', "r=reported", 'b=""']
        if project:
            parts.append(
                'd="$HOME"/.claude/projects/%s/%s; if [ -d "$d" ]; then b="$d"; fi'
                % (shlex.quote(project), shlex.quote(value))
            )
        parts.append(
            'if [ -z "$b" ]; then '
            'b=$(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type d -name %s 2>/dev/null '
            '| while IFS= read -r c; do if [ -d "$c/subagents" ]; then printf %%s "$c"; break; fi; done); fi'
            % shlex.quote(value)
        )
        parts.append(
            'if [ -z "$b" ]; then '
            'k=$(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type f -name %s 2>/dev/null '
            '| head -n 1); [ -n "$k" ] || exit 9; fi' % shlex.quote(value + ".jsonl")
        )
    inner = "; ".join(parts) + "; " + (
        's="$b/subagents"; '
        'if [ -n "$b" ] && [ -d "$s" ]; then '
        '[ -r "$s" ] && [ -x "$s" ] || exit 7; '
        'printf "R\\t%%s\\n" "$r"; '
        'printf "N\\t%%s\\n" "$(date -u +%%s)"; '
        'l=$(ps -Ao pid=,ppid=,args= 2>/dev/null '
        '| LC_ALL=C awk -v me="$$" -v pa="$PPID" %s 2>/dev/null); '
        '[ -n "$l" ] || l=unknown; printf "L\\t%%s\\n" "$l"; '
        'if [ -d "$s/workflows" ]; then [ -r "$s/workflows" ] && [ -x "$s/workflows" ] || exit 7; fi; '
        'find "$s/workflows" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n %d '
        '| while IFS= read -r w; do '
        'j="$w/journal.jsonl"; '
        'if [ ! -f "$j" ]; then [ -r "$w" ] && [ -x "$w" ] || exit 7; continue; fi; '
        'm=$(stat -f %%m "$j" 2>/dev/null) || m=$(stat -c %%Y "$j" 2>/dev/null) || exit 7; '
        'q=$(ls -1t "$w"/agent-*.jsonl 2>/dev/null | head -n 1); '
        'if [ -f "$q" ]; then '
        'k=$(stat -f %%m "$q" 2>/dev/null) || k=$(stat -c %%Y "$q" 2>/dev/null); '
        'case "$k" in ""|*[!0-9]*) ;; *) [ "$k" -gt "$m" ] && m=$k ;; esac; fi; '
        'c=$(LC_ALL=C awk %s "$j" 2>/dev/null) || exit 8; '
        '[ -n "$c" ] || exit 8; '
        'n=${w##*/}; printf "W\\t%%s\\t%%s\\t%%s\\n" "$n" "$m" "$c"; done || exit $?; '
        'find "$s" -mindepth 1 -maxdepth 1 -name "agent-*.meta.json" 2>/dev/null | head -n %d '
        '| while IFS= read -r f; do '
        'n=${f##*/}; n=${n#agent-}; n=${n%%.meta.json}; '
        'p=${f%%.meta.json}.jsonl; [ -f "$p" ] || p="$f"; '
        'm=$(stat -f %%m "$p" 2>/dev/null) || m=$(stat -c %%Y "$p" 2>/dev/null) || exit 7; '
        't=$(LC_ALL=C awk %s "$f" 2>/dev/null); '
        'printf "A\\t%%s\\t%%s\\t%%s\\n" "$n" "$m" "$t"; done || exit $?; '
        'fi; printf "%s\\n"'
    ) % (
        shlex.quote(agent_work_ps_awk()),
        AGENT_WORK_SCAN_MAX, shlex.quote(agent_work_journal_awk()),
        AGENT_WORK_SCAN_MAX, shlex.quote(agent_work_meta_awk()), AGENT_WORK_END,
    )
    return "/bin/sh -c " + shlex.quote(inner)


def agent_work_epoch(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def agent_work_iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def agent_work_stale(item, now):
    return item["running"] > 0 and now - item["at"] > AGENT_WORK_STALE_AFTER


def agent_work_parse(text):
    lines = [line for line in text.replace("\r", "").split("\n") if line != ""]
    if not lines or lines[-1] != AGENT_WORK_END:
        return None
    now = None
    resolved = ""
    live = "unknown"
    workflows = []
    subagents = []
    for line in lines[:-1]:
        fields = line.split("\t")
        kind = fields[0]
        if kind == "R" and len(fields) == 2 and fields[1] in AGENT_RESOLVED_KINDS:
            resolved = fields[1]
        elif kind == "L" and len(fields) == 2 and fields[1] in AGENT_WORK_LIVE_KINDS:
            live = fields[1]
        elif kind == "N" and len(fields) == 2:
            now = agent_work_epoch(fields[1])
        elif kind == "W" and len(fields) == 5:
            at = agent_work_epoch(fields[2])
            running = agent_work_epoch(fields[3])
            done = agent_work_epoch(fields[4])
            if at is None or running is None or done is None:
                continue
            if not AGENT_WORK_ID_RE.match(fields[1]):
                continue
            workflows.append({"id": fields[1], "at": at, "running": running, "done": done})
        elif kind == "A" and len(fields) == 4:
            at = agent_work_epoch(fields[2])
            if at is None or not AGENT_WORK_ID_RE.match(fields[1]):
                continue
            kind_name = fields[3] if AGENT_WORK_TYPE_RE.match(fields[3]) else "unknown"
            subagents.append({"id": fields[1], "at": at, "type": kind_name})
    if now is None:
        now = int(time.time())
    workflows.sort(key=lambda item: item["at"], reverse=True)
    subagents.sort(key=lambda item: item["at"], reverse=True)
    truncated = (
        len(workflows) > AGENT_WORK_WORKFLOWS_MAX
        or len(subagents) > AGENT_WORK_SUBAGENTS_MAX
    )
    body = {
        "resolved": resolved,
        "workflows": [
            {
                "id": item["id"],
                "running": 0 if agent_work_stale(item, now) else item["running"],
                "done": item["done"],
                "since": agent_work_iso(item["at"]),
                "stale": agent_work_stale(item, now),
            }
            for item in workflows[:AGENT_WORK_WORKFLOWS_MAX]
        ],
        "subagents": [
            {
                "id": item["id"],
                "type": item["type"],
                "running": live != "dead" and now - item["at"] <= AGENT_WORK_RUNNING_WINDOW,
                "since": agent_work_iso(item["at"]),
            }
            for item in subagents[:AGENT_WORK_SUBAGENTS_MAX]
        ],
        "truncated": truncated,
    }
    return body


def agent_work_lock(key):
    with WORK_CACHE_LOCK:
        lock = WORK_REFRESH_LOCKS.get(key)
        if lock is None:
            if len(WORK_REFRESH_LOCKS) >= AGENT_WORK_CACHE_MAX:
                for stale in [k for k in WORK_REFRESH_LOCKS if k not in WORK_CACHE]:
                    del WORK_REFRESH_LOCKS[stale]
            lock = threading.Lock()
            WORK_REFRESH_LOCKS[key] = lock
        return lock


def agent_work_store(key, value):
    with WORK_CACHE_LOCK:
        WORK_CACHE[key] = {"at": time.monotonic(), "value": value}
        while len(WORK_CACHE) > AGENT_WORK_CACHE_MAX:
            oldest = min(WORK_CACHE, key=lambda k: WORK_CACHE[k]["at"])
            del WORK_CACHE[oldest]


def agent_work_fetch(key, script, runner=None):
    runner = runner or agent_ssh
    now = time.monotonic()
    with WORK_CACHE_LOCK:
        hit = WORK_CACHE.get(key)
        if hit is not None and now - hit["at"] < AGENT_WORK_TTL:
            return json.loads(hit["value"])
    with agent_work_lock(key):
        with WORK_CACHE_LOCK:
            hit = WORK_CACHE.get(key)
            if hit is not None and time.monotonic() - hit["at"] < AGENT_WORK_TTL:
                return json.loads(hit["value"])
        proc = runner(script, AGENT_WORK_TIMEOUT)
        if proc.returncode != 0:
            return None
        body = agent_work_parse(proc.stdout.decode("utf-8", "replace"))
        if body is None:
            return None
        agent_work_store(key, json.dumps(body))
        return body


def agent_prompt_line(text):
    if AGENT_PROMPT_CONTROL_RE.search(text):
        return ""
    return " ".join(part.strip() for part in text.split("\n") if part.strip())


def agent_ask_empty():
    return {"asking": False, "kind": "", "question": "", "options": [], "raw_hint": ""}


def agent_ask_line(line):
    return line.strip().strip(AGENT_ASK_BORDER).strip()


def agent_ask_signal(lines, end):
    found = False
    body = 0
    for probe in range(end + 1, len(lines)):
        candidate = agent_ask_line(lines[probe])
        if not candidate or AGENT_ASK_CHROME_RE.match(candidate):
            continue
        if AGENT_ASK_TRANSCRIPT_RE.match(candidate):
            return False
        if AGENT_ASK_AFFORD_RE.search(candidate):
            found = True
            continue
        if AGENT_ASK_HINT_RE.search(candidate):
            continue
        if found:
            return False
        body += 1
        if body > AGENT_ASK_TAIL_BODY:
            return False
    return found


def agent_ask_capture(session):
    proc = subprocess.run(
        [TERM_TMUX, "capture-pane", "-p", "-t", term_pane_target(session)],
        capture_output=True, timeout=AGENT_ASK_TIMEOUT,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace")


def agent_ask_block(lines):
    floor = max(0, len(lines) - AGENT_ASK_SCAN_LINES)
    hits = []
    for index in range(floor, len(lines)):
        m = AGENT_ASK_OPTION_RE.match(agent_ask_line(lines[index]))
        if m is not None:
            hits.append((index, m))
    if not hits:
        return []
    matches = [hits[-1]]
    for index, m in reversed(hits[:-1]):
        head_index, head_m = matches[-1]
        if head_index - index > AGENT_ASK_OPTION_GAP:
            break
        if int(m.group("index")) != int(head_m.group("index")) - 1:
            break
        matches.append((index, m))
    matches.reverse()
    return matches


def agent_ask_parse(text):
    body = agent_ask_empty()
    lines = [line.rstrip() for line in text.split("\n")]
    matches = agent_ask_block(lines)
    if len(matches) < 2 or sum(1 for _, m in matches if m.group("cursor")) != 1:
        return body
    if not agent_ask_signal(lines, matches[-1][0]):
        return body
    options = []
    for position, (_, m) in enumerate(matches, 1):
        if int(m.group("index")) != position:
            return body
        options.append({
            "index": position,
            "label": m.group("label").strip()[:AGENT_ASK_LABEL_MAX],
            "selected": bool(m.group("cursor")),
        })
    start = matches[0][0]
    question = ""
    probe = start - 1
    while probe >= 0 and start - probe <= AGENT_ASK_QUESTION_LOOKBACK:
        candidate = agent_ask_line(lines[probe])
        if candidate:
            if candidate.endswith("?"):
                question = candidate[:AGENT_ASK_QUESTION_MAX]
                start = probe
            break
        probe -= 1
    labels = " ".join(option["label"] for option in options)
    body["asking"] = True
    body["kind"] = "permission" if AGENT_ASK_PERMISSION_RE.search(question + " " + labels) else "choice"
    body["question"] = question
    body["options"] = options
    body["raw_hint"] = "\n".join(
        agent_ask_line(line) for line in lines[start:matches[-1][0] + 1]
    )[:AGENT_ASK_HINT_MAX]
    return body


def agent_ask_choice(options, choice):
    kind, value = choice
    for option in options:
        if option["index"] > AGENT_ASK_MAX_OPTIONS:
            continue
        if kind == "index" and option["index"] == value:
            return option["index"]
        if kind == "option" and option["label"].strip().lower() == value.lower():
            return option["index"]
    return None


def watch_log(message):
    line = "%s watch %s\n" % (now_iso(), message)
    try:
        with LOG_LOCK:
            with open(LOG_PATH, "a") as f:
                f.write(line)
    except OSError:
        pass


def wa_outbox_write(name, text):
    path = os.path.join(WA_OUTBOX_DIR, name)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return path


def watch_state_load():
    if WATCH_LOADED[0]:
        return
    WATCH_LOADED[0] = True
    try:
        with open(AGENT_WATCH_STATE_PATH) as f:
            data = json.load(f)
        seen = data.get("seen") if isinstance(data, dict) else None
        sent = data.get("sent") if isinstance(data, dict) else None
        hour = data.get("hour") if isinstance(data, dict) else None
        if isinstance(seen, dict):
            for session, entry in seen.items():
                fp = entry.get("fp") if isinstance(entry, dict) else None
                if not isinstance(fp, dict):
                    continue
                question = fp.get("question")
                labels = fp.get("labels")
                if not isinstance(question, str) or not isinstance(labels, list):
                    continue
                if not all(isinstance(label, str) for label in labels):
                    continue
                WATCH_SEEN[session] = {
                    "fp": {"question": question, "labels": labels},
                    "at": float(entry.get("at") or 0),
                }
        if isinstance(sent, dict):
            for session, at in sent.items():
                WATCH_SENT_AT[session] = float(at)
        if isinstance(hour, list):
            WATCH_HOUR[:] = [float(at) for at in hour]
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        watch_log("state load failed %r" % (exc,))


def watch_state_save():
    tmp = AGENT_WATCH_STATE_PATH + ".tmp"
    try:
        os.makedirs(os.path.dirname(AGENT_WATCH_STATE_PATH), mode=0o700, exist_ok=True)
        with open(tmp, "w") as f:
            json.dump({"seen": WATCH_SEEN, "sent": WATCH_SENT_AT, "hour": WATCH_HOUR}, f)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, AGENT_WATCH_STATE_PATH)
    except (OSError, ValueError) as exc:
        watch_log("state save failed %r" % (exc,))


def agent_watch_norm(text):
    return AGENT_WATCH_SPACE_RE.sub(" ", text.strip()).lower()


def agent_watch_fingerprint(ask):
    return {
        "question": agent_watch_norm(ask["question"]),
        "labels": [agent_watch_norm(option["label"]) for option in ask["options"]],
    }


def agent_watch_same(old, new):
    if not old or not new:
        return False
    if len(old["labels"]) != len(new["labels"]):
        return False
    for left, right in zip(old["labels"], new["labels"]):
        if not left.startswith(right) and not right.startswith(left):
            return False
    left, right = old["question"], new["question"]
    return left.endswith(right) or right.endswith(left)


def agent_watch_merge(old, new):
    return {
        "question": max(old["question"], new["question"], key=len),
        "labels": [max(left, right, key=len) for left, right in zip(old["labels"], new["labels"])],
    }


def agent_watch_tag(fp):
    raw = "\n".join([fp["question"]] + fp["labels"])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def agent_watch_scrub(text):
    return AGENT_WATCH_PATH_RE.sub("…", text).strip()


def agent_watch_message(agent, session, ask):
    lines = ["\U0001f916 %s (%s) precisa de você:" % (agent, session), ""]
    question = agent_watch_scrub(ask["question"])
    if question:
        lines.append('"%s"' % question)
    for option in ask["options"][:AGENT_ASK_MAX_OPTIONS]:
        lines.append("%d. %s" % (option["index"], agent_watch_scrub(option["label"])[:AGENT_WATCH_LABEL_MAX]))
    lines += ["", "Responda pelo app garime."]
    return "\n".join(lines)


def agent_watch_width(session):
    proc = subprocess.run(
        [TERM_TMUX, "display-message", "-p", "-t", term_pane_target(session), "#{pane_width}"],
        capture_output=True, timeout=AGENT_ASK_TIMEOUT,
    )
    if proc.returncode != 0:
        return None
    raw = proc.stdout.decode("utf-8", "replace").strip()
    return int(raw) if raw.isdigit() else None


def agent_watch_notify(session, agent, ask, key, now):
    last = WATCH_SENT_AT.get(session)
    if last is not None and 0 <= now - last < AGENT_WATCH_COOLDOWN:
        watch_log("%s dropped cooldown" % session)
        return "dropped"
    WATCH_HOUR[:] = [at for at in WATCH_HOUR if 0 <= now - at < AGENT_WATCH_HOUR_WINDOW]
    if len(WATCH_HOUR) >= AGENT_WATCH_MAX_HOUR:
        watch_log("%s dropped hourly cap %d" % (session, AGENT_WATCH_MAX_HOUR))
        return "dropped"
    name = "agent-ask-%d-%s-%s.txt" % (int(now), session, key)
    try:
        wa_outbox_write(name, agent_watch_message(agent, session, ask))
    except OSError as exc:
        watch_log("%s outbox failed %r" % (session, exc))
        return "failed"
    WATCH_SENT_AT[session] = now
    WATCH_HOUR.append(now)
    watch_log("%s notified %s" % (session, name))
    return "sent"


def agent_watch_sessions():
    names = set()
    for entry in status_vm_agents():
        session = entry.get("session")
        if isinstance(session, str) and TERM_SESSION_RE.match(session):
            names.add(session)
    return sorted(names)


def agent_watch_tick():
    watch_state_load()
    now = time.time()
    dirty = False
    for session in agent_watch_sessions():
        try:
            found = vm_session_agent(session)
            if not found or not found[0]:
                continue
            width = agent_watch_width(session)
            if width is None or width < AGENT_WATCH_MIN_COLS:
                watch_log("%s skipped narrow pane %s" % (session, width))
                continue
            text = agent_ask_capture(session)
        except Exception as exc:
            watch_log("%s capture failed %r" % (session, exc))
            continue
        if text is None:
            continue
        ask = agent_ask_parse(text)
        if not ask["asking"]:
            if WATCH_SEEN.pop(session, None) is not None:
                dirty = True
            continue
        fp = agent_watch_fingerprint(ask)
        entry = WATCH_SEEN.get(session)
        seen = entry.get("fp") if entry else None
        if agent_watch_same(seen, fp):
            merged = agent_watch_merge(seen, fp)
            if merged != seen or now - entry.get("at", 0) >= AGENT_WATCH_HOUR_WINDOW:
                dirty = True
            entry["fp"] = merged
            entry["at"] = now
            continue
        if agent_watch_notify(session, found[0], ask, agent_watch_tag(fp), now) != "failed":
            WATCH_SEEN[session] = {"fp": fp, "at": now}
            dirty = True
    for stale in [s for s, e in WATCH_SEEN.items() if now - e.get("at", 0) >= AGENT_WATCH_SEEN_TTL]:
        WATCH_SEEN.pop(stale, None)
        dirty = True
    for stale in [s for s, at in WATCH_SENT_AT.items() if now - at >= AGENT_WATCH_COOLDOWN]:
        WATCH_SENT_AT.pop(stale, None)
        dirty = True
    if dirty:
        watch_state_save()


def agent_watch_loop():
    while True:
        try:
            agent_watch_tick()
        except Exception as exc:
            watch_log("tick failed %r" % (exc,))
        time.sleep(AGENT_WATCH_INTERVAL)


def agent_watch_start():
    if not AGENT_WATCH_ENABLED:
        return
    if not os.path.isdir(WA_OUTBOX_DIR):
        watch_log("outbox missing %s" % WA_OUTBOX_DIR)
    watch_state_load()
    watch_log("started interval=%gs outbox=%s state=%s" % (
        AGENT_WATCH_INTERVAL, WA_OUTBOX_DIR, AGENT_WATCH_STATE_PATH))
    threading.Thread(target=agent_watch_loop, daemon=True).start()


def term_has_session(session):
    proc = subprocess.run(
        [TERM_TMUX, "has-session", "-t", term_target(session)],
        capture_output=True, timeout=5,
    )
    return proc.returncode == 0


def term_send_key(session, key):
    proc = subprocess.run(
        [TERM_TMUX, "send-keys", "-t", term_pane_target(session), key],
        capture_output=True, timeout=5,
    )
    return proc.returncode == 0


def agent_commands_with_builtins(agent, commands):
    builtins = AGENT_COMMANDS_BUILTIN.get(agent, ())
    if not builtins:
        return list(commands)
    names = {name for name, _ in builtins}
    merged = [entry for entry in commands if entry.get("name") not in names]
    merged += [
        {"name": name, "description": description, "scope": "builtin", "builtin": True}
        for name, description in builtins
    ]
    return sorted(merged, key=lambda entry: entry.get("name", ""))


def agent_chat_parts(content):
    parts = []
    if isinstance(content, str):
        return [("text", content)]
    if not isinstance(content, list):
        return parts
    for block in content:
        if isinstance(block, str):
            parts.append(("text", block))
            continue
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "text":
            value = block.get("text")
            if isinstance(value, str):
                parts.append(("text", value))
        elif kind in ("tool_use", "toolCall"):
            name = block.get("name")
            parts.append(("tool", name if isinstance(name, str) and name else "tool"))
        elif kind is None:
            value = block.get("text")
            if isinstance(value, str):
                parts.append(("text", value))
    return parts


def agent_chat_text_message(role, buf, ts):
    text = "\n".join(buf).strip()
    message = {"role": role, "text": text[:AGENT_CHAT_TEXT_MAX], "ts": ts}
    if len(text) > AGENT_CHAT_TEXT_MAX:
        message["truncated"] = True
    return message


def agent_chat_record(record):
    if not isinstance(record, dict) or record.get("type") in AGENT_CHAT_DROP_TYPES:
        return []
    message = record.get("message")
    if not isinstance(message, dict):
        message = record
    role = message.get("role")
    if role not in ("user", "assistant"):
        return []
    ts = record.get("timestamp") or message.get("timestamp") or ""
    if not isinstance(ts, str):
        ts = ""
    out = []
    buf = []
    for kind, value in agent_chat_parts(message.get("content")):
        if kind == "text":
            if value.strip():
                buf.append(value)
            continue
        if buf:
            out.append(agent_chat_text_message(role, buf, ts))
            buf = []
        out.append({"role": "tool", "tool": value, "ts": ts})
    if buf:
        out.append(agent_chat_text_message(role, buf, ts))
    return out


def agent_chat_messages(text, limit, skip=0):
    messages = []
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        messages += agent_chat_record(record)
    skip = max(0, int(skip))
    if skip:
        messages = messages[:-skip]
    return messages[-limit:]


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def valid_id(value):
    return isinstance(value, str) and ID_RE.match(value) is not None and value not in (".", "..")


def valid_date(value):
    return isinstance(value, str) and DATE_RE.match(value) is not None


def read_hermes_key():
    try:
        with open(HERMES_KEY_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 120
    _body_read = False

    def log_request(self, code="-", size="-"):
        line = "%s %s %s %s %s\n" % (now_iso(), self.client_address[0], self.command, self.path, code)
        try:
            with LOG_LOCK:
                with open(LOG_PATH, "a") as f:
                    f.write(line)
        except OSError:
            pass

    def _undrained(self):
        encoding = (self.headers.get("Transfer-Encoding") or "").strip().lower()
        if encoding and encoding != "identity":
            return True
        try:
            pending = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return True
        if pending < 0:
            return True
        return bool(pending) and not self._body_read

    def _json(self, status, body):
        close = self._undrained() or self.close_connection
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if close:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        header = self.headers.get("Authorization", "")
        return header.startswith("Bearer ") and hmac.compare_digest(header[7:].strip(), TOKEN)

    def _authed_term(self):
        header = self.headers.get("Authorization", "")
        return bool(TERM_TOKEN) and header.startswith("Bearer ") and hmac.compare_digest(header[7:].strip(), TERM_TOKEN)

    def _term_gate(self):
        if not (TERM_ENABLED and TERM_TOKEN):
            self._json(404, b'{"error":"not_found"}')
            return False
        if not self._authed_term():
            self._json(401, b'{"error":"unauthorized"}')
            return False
        return True

    def _term_session_name(self):
        name = self._term_session_name_strict()
        if name is None:
            self._json(400, b'{"error":"bad_name"}')
        return name

    def _term_session_name_strict(self):
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        raw = q.get("session")
        if raw is None:
            return TERM_SESSION
        return raw[0] if TERM_SESSION_RE.match(raw[0]) else None

    def _term_session(self, session):
        with TERM_REGISTRY_LOCK:
            sess = TERM_REGISTRY.get(session)
            if sess is not None and sess.alive:
                return sess
        return term_get_or_spawn(session, self._term_has_sizing_client(session))

    def _term_has_sizing_client(self, session):
        try:
            out = subprocess.run(
                [TERM_TMUX, "list-clients", "-t", term_target(session), "-F", "#{client_tty}\t#{client_flags}"],
                capture_output=True, timeout=5,
            ).stdout.decode("utf-8", "replace")
            own = term_registry_ttys()
            for line in out.split("\n"):
                if not line:
                    continue
                tty, _, flags = line.partition("\t")
                if tty in own or "ignore-size" in flags:
                    continue
                return True
            return False
        except Exception:
            return False

    def _term_stream(self):
        if not self._term_gate():
            return
        session = self._term_session_name()
        if session is None:
            return
        sess = self._term_session(session)
        sub = TermSubscriber()
        snapshot = sess.subscribe(sub)
        try:
            self.close_connection = True
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self._streaming = True
            last_write = time.monotonic()
            if snapshot:
                self.wfile.write(b"event: replay\ndata: " + base64.b64encode(snapshot) + b"\n\n")
                self.wfile.flush()
            while True:
                if sub.dropped:
                    self.wfile.write(b'event: done\ndata: {"status":"dropped"}\n\n')
                    self.wfile.flush()
                    return
                try:
                    data = sub.q.get(timeout=0.5)
                except queue.Empty:
                    data = b""
                if data is None:
                    self.wfile.write(b'event: done\ndata: {"status":"closed"}\n\n')
                    self.wfile.flush()
                    return
                now = time.monotonic()
                if data:
                    self.wfile.write(b"data: " + base64.b64encode(data) + b"\n\n")
                    self.wfile.flush()
                    last_write = now
                elif now - last_write > 15:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_write = now
        finally:
            sess.unsubscribe(sub)

    def _term_input(self):
        if not self._term_gate():
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        self._body_read = True
        raw = self.rfile.read(length) if length else b""
        try:
            data = base64.b64decode(raw, validate=True)
        except ValueError:
            self._json(400, b'{"error":"invalid_body"}')
            return
        session = self._term_session_name()
        if session is None:
            return
        sess = self._term_session(session)
        try:
            sess.write(data)
        except OSError:
            self._json(409, b'{"error":"no_attach"}')
            return
        self._json(200, b'{"ok":true}')

    def _term_resize(self):
        if not self._term_gate():
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        try:
            self._body_read = True
            body = json.loads(self.rfile.read(length)) if length else None
        except ValueError:
            body = None
        if not isinstance(body, dict):
            self._json(400, b'{"error":"invalid_body"}')
            return
        rows = body.get("rows")
        cols = body.get("cols")
        if (
            not isinstance(rows, int) or isinstance(rows, bool) or not 0 < rows < 10000
            or not isinstance(cols, int) or isinstance(cols, bool) or not 0 < cols < 10000
        ):
            self._json(400, b'{"error":"invalid_body"}')
            return
        session = self._term_session_name()
        if session is None:
            return
        sess = self._term_session(session)
        try:
            sess.set_winsize(rows, cols)
        except OSError:
            self._json(409, b'{"error":"no_attach"}')
            return
        self._json(200, b'{"ok":true}')

    def _term_winsize(self):
        if not self._term_gate():
            return
        session = self._term_session_name()
        if session is None:
            return
        try:
            out = subprocess.run(
                [TERM_TMUX, "display-message", "-p", "-t", term_pane_target(session), "#{window_width} #{window_height}"],
                capture_output=True, timeout=5,
            ).stdout.decode("utf-8", "replace").split()
            cols, rows = int(out[0]), int(out[1])
        except Exception:
            self._json(409, b'{"error":"no_session"}')
            return
        shared = self._term_has_sizing_client(session)
        self._json(200, json.dumps({"cols": cols, "rows": rows, "shared": shared}).encode())

    def _term_list(self):
        if not self._term_gate():
            return
        if self._term_session_name() is None:
            return
        try:
            out = subprocess.run(
                [TERM_TMUX, "list-sessions", "-F", "#{session_name}"],
                capture_output=True, timeout=5,
            ).stdout.decode("utf-8", "replace")
            names = [n for n in out.split("\n") if n]
        except Exception:
            names = []
        self._json(200, json.dumps({"sessions": names}).encode())

    def _term_preview(self):
        if not self._term_gate():
            return
        session = self._term_session_name()
        if session is None:
            return
        q = parse_qs(urlsplit(self.path).query)
        try:
            lines = int((q.get("lines") or [str(TERM_PREVIEW_LINES)])[0])
        except ValueError:
            lines = TERM_PREVIEW_LINES
        lines = max(1, min(TERM_PREVIEW_MAX_LINES, lines))
        try:
            proc = subprocess.run(
                [TERM_TMUX, "capture-pane", "-p", "-e", "-t", term_pane_target(session), "-S", "-%d" % lines],
                capture_output=True, timeout=5,
            )
        except Exception:
            self._json(404, b'{"error":"no_session"}')
            return
        if proc.returncode != 0:
            self._json(404, b'{"error":"no_session"}')
            return
        text = proc.stdout.decode("utf-8", "replace")
        self._json(200, json.dumps({"text": text}).encode())

    def _term_health(self):
        if not self._term_gate():
            return
        body = {
            "ok": True,
            "mac_online": status_mac_online(),
            "agent": agent_session_state(),
        }
        self._json(200, json.dumps(body).encode())

    def _term_agent_ensure(self):
        if not self._term_gate():
            return
        self.close_connection = True
        try:
            self._term_session(AGENT_SESSION)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        self._json(200, json.dumps({"ok": True, "agent": agent_session_state()}).encode())

    def _term_agents(self):
        if not self._term_gate():
            return
        units = []
        for unit in STATUS_UNITS:
            active = False
            since = ""
            try:
                out = subprocess.run(
                    ["systemctl", "show", unit, "-p", "ActiveState", "-p", "ActiveEnterTimestamp"],
                    capture_output=True, timeout=5,
                ).stdout.decode("utf-8", "replace")
                for line in out.split("\n"):
                    key, _, value = line.partition("=")
                    if key == "ActiveState":
                        active = value.strip() == "active"
                    elif key == "ActiveEnterTimestamp":
                        since = value.strip()
            except Exception:
                active = False
                since = ""
            units.append({"name": unit, "active": active, "since": since})
        body = {
            "units": units,
            "mac_online": status_mac_online(),
            "agents": [agent_public(entry) for entry in status_agents()],
        }
        self._json(200, json.dumps(body).encode())

    def _term_agent_target(self):
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        project = (q.get("project") or [""])[0]
        pane = (q.get("pane") or [""])[0]
        if not TERM_ATTACH_PROJECT_RE.match(project) or not TERM_ATTACH_PANE_RE.match(pane):
            self._json(400, b'{"error":"bad_target"}')
            return None, None
        return project, pane

    def _term_vm_target(self):
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        raw = q.get("session")
        if raw is None:
            return ""
        if q.get("project") is not None or q.get("pane") is not None or len(raw) != 1:
            self._json(400, b'{"error":"bad_target"}')
            return None
        if not TERM_SESSION_RE.match(raw[0]):
            self._json(400, b'{"error":"bad_target"}')
            return None
        return raw[0]

    def _term_vm_session_required(self):
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        raw = q.get("session")
        if (
            raw is None or len(raw) != 1
            or q.get("project") is not None or q.get("pane") is not None
            or not TERM_SESSION_RE.match(raw[0])
        ):
            self._json(400, b'{"error":"bad_target"}')
            return None
        return raw[0]

    def _term_vm_agent(self, session):
        try:
            found = vm_session_agent(session)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return None
        if found is None:
            self._json(404, b'{"error":"no_session"}')
            return None
        agent, cwd = found
        if not agent:
            self._json(404, b'{"error":"no_agent"}')
            return None
        return agent, cwd

    def _term_chat_limit(self, q=None):
        if q is None:
            q = parse_qs(urlsplit(self.path).query)
        try:
            limit = int((q.get("limit") or [str(AGENT_CHAT_LIMIT)])[0])
        except ValueError:
            limit = AGENT_CHAT_LIMIT
        return max(1, min(AGENT_CHAT_MAX_LIMIT, limit))

    def _term_agent_resolve(self, project, pane, pane_conflict=False):
        try:
            mac_ok, agents, panes = status_scan_full()
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return None
        if not mac_ok:
            self._json(503, b'{"error":"unavailable"}')
            return None
        entry = agent_find(agents, project, pane)
        if entry is None:
            if pane_conflict and pane_find(panes, project, pane) is not None:
                self._json(409, b'{"error":"no_agent_in_pane"}')
            else:
                self._json(404, b'{"error":"no_agent"}')
            return None
        return entry

    def _term_panes(self):
        if not self._term_gate():
            return
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        project = (q.get("project") or [""])[0]
        if not TERM_ATTACH_PROJECT_RE.match(project):
            self._json(400, b'{"error":"bad_target"}')
            return
        try:
            mac_ok, _, panes = status_scan_full()
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if not mac_ok:
            self._json(503, b'{"error":"unavailable"}')
            return
        body = {
            "project": project,
            "panes": [pane_public(entry) for entry in panes if entry.get("project") == project],
        }
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _agent_chat_payload(self, session, limit=None, skip=0):
        """Monta o payload do chat de uma sessão VM; retorna dict ou None (sem sessão/agente)."""
        found = self._term_vm_agent(session)
        if found is None:
            return None
        agent, cwd = found
        if limit is None:
            limit = self._term_chat_limit()
        body = {"agent": agent, "status": agent_chat_status(cwd), "resolved": "", "messages": []}
        script = agent_transcript_script(vm_agent_session(agent), cwd)
        if not script:
            return body
        try:
            proc = agent_local(script, AGENT_CHAT_TIMEOUT)
        except Exception:
            return body
        if proc.returncode != 0:
            return body
        resolved, out = agent_chat_resolved(proc.stdout.decode("utf-8", "replace"))
        body["resolved"] = resolved
        body["messages"] = agent_chat_messages(out, limit, skip)
        return body

    def _term_agent_stream(self):
        """SSE: empurra o payload do chat a cada mudança (~0.5s). Fecho após AGENT_STREAM_MAX_S."""
        if not self._term_gate():
            return
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        session = self._term_session_name()
        if not session:
            return
        limit = self._term_chat_limit(q)
        try:
            deadline = time.monotonic() + AGENT_STREAM_MAX_S
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self._streaming = True
            last_hash = None
            while time.monotonic() < deadline:
                payload = self._agent_chat_payload(session, limit)
                if payload is None:
                    break
                data = json.dumps(payload, ensure_ascii=False).encode()
                digest = hashlib.sha256(data).digest()
                if digest != last_hash:
                    last_hash = digest
                    self.wfile.write(b"data: " + data + b"\n\n")
                    self.wfile.flush()
                elif int((AGENT_STREAM_MAX_S - (deadline - time.monotonic())) * 2) % 30 == 0:
                    pass  # heartbeat implícito: mudanças no hash chegam logo
                time.sleep(AGENT_STREAM_TICK_S)
            self.wfile.write(b"event: bye\ndata: {}\n\n")
            self.wfile.flush()
        except (ConnectionError, BrokenPipeError, socket.timeout, OSError):
            pass
        finally:
            self.close_connection = True

    def _term_agent_chat_vm(self, session):
        body = self._agent_chat_payload(session)
        if body is None:
            return
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_chat(self):
        if not self._term_gate():
            return
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        try:
            before = max(0, int((q.get("before") or ["0"])[0]))
        except ValueError:
            before = 0
        vm = self._term_vm_target()
        if vm is None:
            return
        if vm:
            limit = self._term_chat_limit(q)
            body = self._agent_chat_payload(vm, limit, skip=before)
            if body is None:
                return
            body["hasMore"] = len(body["messages"]) >= max(1, limit)
            self._json(200, json.dumps(body, ensure_ascii=False).encode())
            return
        project, pane = self._term_agent_target()
        if project is None:
            return
        limit = self._term_chat_limit()
        entry = self._term_agent_resolve(project, pane)
        if entry is None:
            return
        body = {
            "agent": entry.get("agent", ""),
            "status": entry.get("status", "unknown"),
            "resolved": "",
            "messages": [],
        }
        script = agent_transcript_script(entry.get("session"), entry.get("cwd", ""))
        if not script:
            self._json(200, json.dumps(body, ensure_ascii=False).encode())
            return
        try:
            proc = agent_ssh(script, AGENT_CHAT_TIMEOUT)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if proc.returncode != 0:
            self._json(503, b'{"error":"unavailable"}')
            return
        resolved, out = agent_chat_resolved(proc.stdout.decode("utf-8", "replace"))
        body["resolved"] = resolved
        body["messages"] = agent_chat_messages(out, limit)
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_prompt_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length <= 0 or length > AGENT_PROMPT_MAX:
            self._json(400, b'{"error":"invalid_body"}')
            return None
        self._body_read = True
        raw = self.rfile.read(length)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            self._json(400, b'{"error":"invalid_body"}')
            return None
        if len(raw) != length or not text.strip():
            self._json(400, b'{"error":"invalid_body"}')
            return None
        return text

    def _term_agent_prompt_vm(self, session):
        text = self._term_agent_prompt_body()
        if text is None:
            return
        line = agent_prompt_line(text)
        if not line:
            self._json(400, b'{"error":"invalid_body"}')
            return
        if self._term_vm_agent(session) is None:
            return
        try:
            sess = self._term_session(session)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        try:
            sess.write(line.encode())
            time.sleep(0.05)
            sess.write(b"\r")
        except OSError:
            self._json(409, b'{"error":"no_attach"}')
            return
        self._json(200, b'{"ok":true}')

    def _term_agent_prompt(self):
        if not self._term_gate():
            return
        self.close_connection = True
        vm = self._term_vm_target()
        if vm is None:
            return
        if vm:
            self._term_agent_prompt_vm(vm)
            return
        project, pane = self._term_agent_target()
        if project is None:
            return
        text = self._term_agent_prompt_body()
        if text is None:
            return
        if self._term_agent_resolve(project, pane) is None:
            return
        try:
            proc = agent_ssh(agent_prompt_script(project, pane, text), AGENT_PROMPT_TIMEOUT)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if proc.returncode != 0:
            self._json(503, b'{"error":"unavailable"}')
            return
        self._json(200, b'{"ok":true}')

    def _term_agent_ask_vm(self, session):
        found = self._term_vm_agent(session)
        if found is None:
            return
        agent, _ = found
        try:
            text = agent_ask_capture(session)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if text is None:
            self._json(503, b'{"error":"unavailable"}')
            return
        body = {"agent": agent}
        body.update(agent_ask_parse(text))
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_ask(self):
        if not self._term_gate():
            return
        vm = self._term_vm_target()
        if vm is None:
            return
        if vm:
            self._term_agent_ask_vm(vm)
            return
        project, pane = self._term_agent_target()
        if project is None:
            return
        entry = self._term_agent_resolve(project, pane)
        if entry is None:
            return
        text = self._term_agent_ask_mac_read(project, pane)
        if text is None:
            return
        body = {"agent": entry.get("agent", ""), "blocked": entry.get("status") == "blocked"}
        body.update(agent_ask_parse(text))
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_ask_mac_read(self, project, pane):
        try:
            proc = agent_ssh(
                herdr_pane_script(project, pane, AGENT_ASK_MAC_READ), AGENT_ASK_MAC_TIMEOUT
            )
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return None
        if proc.returncode != 0:
            self._json(503, b'{"error":"unavailable"}')
            return None
        return proc.stdout.decode("utf-8", "replace")

    def _term_answer_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length <= 0 or length > AGENT_ANSWER_BODY_MAX:
            self._json(400, b'{"error":"invalid_body"}')
            return None
        self._body_read = True
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw) if len(raw) == length else None
        except ValueError:
            body = None
        if not isinstance(body, dict):
            self._json(400, b'{"error":"invalid_body"}')
            return None
        index = body.get("index")
        option = body.get("option")
        if (index is None) == (option is None):
            self._json(400, b'{"error":"invalid_body"}')
            return None
        if index is not None:
            if not isinstance(index, int) or isinstance(index, bool):
                self._json(400, b'{"error":"invalid_body"}')
                return None
            return "index", index
        if not isinstance(option, str) or not option.strip():
            self._json(400, b'{"error":"invalid_body"}')
            return None
        return "option", option.strip()

    def _term_agent_answer(self):
        if not self._term_gate():
            return
        self.close_connection = True
        vm = self._term_vm_target()
        if vm is None:
            return
        if vm:
            self._term_agent_answer_vm(vm)
            return
        project, pane = self._term_agent_target()
        if project is None:
            return
        choice = self._term_answer_body()
        if choice is None:
            return
        if self._term_agent_resolve(project, pane) is None:
            return
        text = self._term_agent_ask_mac_read(project, pane)
        if text is None:
            return
        ask = agent_ask_parse(text)
        if not ask["asking"]:
            self._json(409, b'{"error":"not_asking"}')
            return
        index = agent_ask_choice(ask["options"], choice)
        if index is None:
            self._json(400, b'{"error":"bad_option"}')
            return
        commands = (("send-text", (str(index),)), ("send-keys", ("enter",)))
        try:
            proc = agent_ssh(herdr_pane_script(project, pane, commands), AGENT_ASK_MAC_TIMEOUT)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if proc.returncode != 0:
            self._json(503, b'{"error":"unavailable"}')
            return
        self._json(200, json.dumps({"ok": True, "index": index}).encode())

    def _term_agent_answer_vm(self, session):
        choice = self._term_answer_body()
        if choice is None:
            return
        if self._term_vm_agent(session) is None:
            return
        try:
            text = agent_ask_capture(session)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if text is None:
            self._json(503, b'{"error":"unavailable"}')
            return
        ask = agent_ask_parse(text)
        if not ask["asking"]:
            self._json(409, b'{"error":"not_asking"}')
            return
        index = agent_ask_choice(ask["options"], choice)
        if index is None:
            self._json(400, b'{"error":"bad_option"}')
            return
        try:
            sess = self._term_session(session)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        try:
            sess.write(str(index).encode())
            time.sleep(0.05)
            sess.write(b"\r")
        except OSError:
            self._json(409, b'{"error":"no_attach"}')
            return
        self._json(200, json.dumps({"ok": True, "index": index}).encode())

    def _term_agent_interrupt(self):
        if not self._term_gate():
            return
        vm = self._term_vm_target()
        if vm is None:
            return
        if vm:
            self._term_agent_interrupt_vm(vm)
            return
        project, pane = self._term_agent_target()
        if project is None:
            return
        if self._term_agent_resolve(project, pane) is None:
            return
        commands = (("send-keys", (AGENT_INTERRUPT_KEY_MAC,)),)
        try:
            proc = agent_ssh(herdr_pane_script(project, pane, commands), AGENT_ASK_MAC_TIMEOUT)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if proc.returncode != 0:
            self._json(503, b'{"error":"unavailable"}')
            return
        self._json(200, b'{"ok":true}')

    def _term_agent_interrupt_vm(self, session):
        if self._term_vm_agent(session) is None:
            return
        try:
            sent = term_send_key(session, AGENT_INTERRUPT_KEY)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if not sent:
            self._json(503, b'{"error":"unavailable"}')
            return
        self._json(200, b'{"ok":true}')

    def _term_start_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length <= 0 or length > AGENT_ANSWER_BODY_MAX:
            self._json(400, b'{"error":"invalid_body"}')
            return None
        self._body_read = True
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw) if len(raw) == length else None
        except ValueError:
            body = None
        if not isinstance(body, dict):
            self._json(400, b'{"error":"invalid_body"}')
            return None
        agent = body.get("agent")
        if not isinstance(agent, str) or agent not in AGENT_START_COMMANDS:
            self._json(400, b'{"error":"bad_agent"}')
            return None
        return agent

    def _term_agent_start(self):
        if not self._term_gate():
            return
        self.close_connection = True
        session = self._term_vm_session_required()
        if session is None:
            return
        agent = self._term_start_body()
        if agent is None:
            return
        try:
            found = vm_session_agent(session)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if found is None:
            self._json(404, b'{"error":"no_session"}')
            return
        if found[0]:
            self._json(409, b'{"error":"already_running"}')
            return
        try:
            sess = self._term_session(session)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        try:
            sess.write(AGENT_START_COMMANDS[agent].encode())
            time.sleep(0.05)
            sess.write(b"\r")
        except OSError:
            self._json(409, b'{"error":"no_attach"}')
            return
        self._json(200, json.dumps({"ok": True, "agent": agent}).encode())

    def _term_agent_commands_vm(self, session):
        found = self._term_vm_agent(session)
        if found is None:
            return
        agent, cwd = found
        body = {"agent": agent, "commands": []}
        script = agent_commands_script(agent, cwd)
        if not script:
            body["commands"] = agent_commands_with_builtins(agent, [])
            self._json(200, json.dumps(body, ensure_ascii=False).encode())
            return
        try:
            commands = agent_commands_fetch(("vm", session, agent, cwd), script, agent_local)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if commands is None:
            self._json(503, b'{"error":"unavailable"}')
            return
        body["commands"] = agent_commands_with_builtins(agent, commands)
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_commands(self):
        if not self._term_gate():
            return
        vm = self._term_vm_target()
        if vm is None:
            return
        if vm:
            self._term_agent_commands_vm(vm)
            return
        project, pane = self._term_agent_target()
        if project is None:
            return
        entry = self._term_agent_resolve(project, pane, True)
        if entry is None:
            return
        agent = entry.get("agent", "")
        cwd = entry.get("cwd", "")
        body = {"agent": agent, "commands": []}
        script = agent_commands_script(agent, cwd)
        if not script:
            self._json(200, json.dumps(body, ensure_ascii=False).encode())
            return
        try:
            commands = agent_commands_fetch((project, pane, agent, cwd), script)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if commands is None:
            self._json(503, b'{"error":"unavailable"}')
            return
        body["commands"] = agent_commands_with_builtins(agent, commands)
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_work_vm(self, session):
        found = self._term_vm_agent(session)
        if found is None:
            return
        agent, cwd = found
        body = {
            "agent": agent,
            "supported": False,
            "resolved": "",
            "workflows": [],
            "subagents": [],
            "truncated": False,
        }
        script = agent_work_script({"kind": "cwd", "value": ""}, cwd) if agent == "claude" else ""
        if not script:
            self._json(200, json.dumps(body, ensure_ascii=False).encode())
            return
        try:
            work = agent_work_fetch(("vm", session, agent, cwd), script, agent_local)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if work is None:
            self._json(503, b'{"error":"unavailable"}')
            return
        body["supported"] = True
        body.update(work)
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_work(self):
        if not self._term_gate():
            return
        vm = self._term_vm_target()
        if vm is None:
            return
        if vm:
            self._term_agent_work_vm(vm)
            return
        project, pane = self._term_agent_target()
        if project is None:
            return
        entry = self._term_agent_resolve(project, pane, True)
        if entry is None:
            return
        agent = entry.get("agent", "")
        session = entry.get("session")
        cwd = entry.get("cwd", "")
        body = {
            "agent": agent,
            "supported": False,
            "resolved": "",
            "workflows": [],
            "subagents": [],
            "truncated": False,
        }
        script = agent_work_script(session, cwd) if agent == "claude" else ""
        if not script:
            self._json(200, json.dumps(body, ensure_ascii=False).encode())
            return
        try:
            work = agent_work_fetch((project, pane, agent_work_session_id(session), cwd), script)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        if work is None:
            self._json(503, b'{"error":"unavailable"}')
            return
        body["supported"] = True
        body.update(work)
        self._json(200, json.dumps(body, ensure_ascii=False).encode())

    def _term_agent_upload(self):
        if not self._term_gate():
            return
        self.close_connection = True
        project, pane = self._term_agent_target()
        if project is None:
            return
        name = (self.headers.get("X-Geo-Filename") or "").strip()
        if (
            not TERM_UPLOAD_NAME_RE.match(name)
            or name != os.path.basename(name)
            or name.startswith(".")
        ):
            self._json(400, b'{"error":"invalid_filename"}')
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length > AGENT_UPLOAD_MAX:
            self._json(413, b'{"error":"too_large"}')
            return
        if length <= 0:
            self._json(400, b'{"error":"invalid_body"}')
            return
        self._body_read = True
        data = self.rfile.read(length)
        if len(data) != length:
            self._json(400, b'{"error":"invalid_body"}')
            return
        if self._term_agent_resolve(project, pane, True) is None:
            return
        try:
            proc = agent_ssh(agent_upload_script(name), AGENT_UPLOAD_TIMEOUT, data)
        except Exception:
            self._json(503, b'{"error":"unavailable"}')
            return
        path = proc.stdout.decode("utf-8", "replace").strip()
        if proc.returncode != 0 or not AGENT_UPLOAD_PATH_RE.match(path):
            self._json(503, b'{"error":"unavailable"}')
            return
        self._json(200, json.dumps({"path": path}, ensure_ascii=False).encode())

    def _term_attach(self, prefix, want_pane):
        if not self._term_gate():
            return
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        project = (q.get("project") or [""])[0]
        pane = (q.get("pane") or [""])[0]
        if not TERM_ATTACH_PROJECT_RE.match(project):
            self._json(400, b'{"error":"bad_target"}')
            return
        if want_pane:
            if not TERM_ATTACH_PANE_RE.match(pane):
                self._json(400, b'{"error":"bad_target"}')
                return
            if self._term_agent_resolve(project, pane, True) is None:
                return
        else:
            pane = ""
        session = term_attach_name(prefix, project, pane)
        if not TERM_SESSION_RE.match(session) or session == "mac":
            self._json(400, b'{"error":"bad_target"}')
            return
        term_get_or_spawn(session, self._term_has_sizing_client(session), herdr_attach_command(project, pane))
        self._json(200, json.dumps({"session": session}).encode())

    def _term_kill(self):
        if not self._term_gate():
            return
        session = self._term_session_name_strict()
        if session is None:
            self._json(400, b'{"error":"bad_name"}')
            return
        with TERM_REGISTRY_LOCK:
            sess = TERM_REGISTRY.get(session)
        try:
            subprocess.run([TERM_TMUX, "kill-session", "-t", term_target(session)], capture_output=True, timeout=5)
        except Exception:
            pass
        if sess is not None:
            sess.teardown()
        self._json(200, b'{"ok":true}')

    def _term_rename(self):
        if not self._term_gate():
            return
        session = self._term_session_name_strict()
        if session is None:
            self._json(400, b'{"error":"bad_name"}')
            return
        q = parse_qs(urlsplit(self.path).query)
        to = (q.get("to") or [""])[0]
        if not TERM_SESSION_RE.match(to):
            self._json(400, b'{"error":"bad_name"}')
            return
        if session == "mac" or to == "mac":
            self._json(409, b'{"error":"reserved"}')
            return
        if to == session:
            self._json(200, b'{"ok":true}')
            return
        try:
            probe = subprocess.run(
                [TERM_TMUX, "has-session", "-t", term_target(to)],
                capture_output=True, timeout=5,
            )
        except Exception:
            self._json(404, b'{"error":"no_session"}')
            return
        if probe.returncode == 0:
            self._json(409, b'{"error":"exists"}')
            return
        try:
            proc = subprocess.run(
                [TERM_TMUX, "rename-session", "-t", term_target(session), to],
                capture_output=True, timeout=5,
            )
        except Exception:
            self._json(404, b'{"error":"no_session"}')
            return
        if proc.returncode != 0:
            self._json(404, b'{"error":"no_session"}')
            return
        with TERM_REGISTRY_LOCK:
            sess = TERM_REGISTRY.pop(session, None)
            if sess is not None:
                sess.session = to
                TERM_REGISTRY[to] = sess
        self._json(200, json.dumps({"session": to}).encode())

    def _term_upload(self):
        if not self._term_gate():
            return
        self.close_connection = True
        name = (self.headers.get("X-Geo-Filename") or "").strip()
        if (
            not TERM_UPLOAD_NAME_RE.match(name)
            or name != os.path.basename(name)
            or name.startswith(".")
        ):
            self._json(400, b'{"error":"invalid_filename"}')
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length > TERM_UPLOAD_MAX:
            self._json(413, b'{"error":"too_large"}')
            return
        if length <= 0:
            self._json(400, b'{"error":"invalid_body"}')
            return
        self._body_read = True
        data = self.rfile.read(length)
        if len(data) != length:
            self._json(400, b'{"error":"invalid_body"}')
            return
        try:
            os.makedirs(TERM_UPLOAD_DIR, mode=0o700, exist_ok=True)
            base = os.path.realpath(TERM_UPLOAD_DIR)
            stem, ext = os.path.splitext(name)
            candidate = name
            index = 1
            while True:
                dest = os.path.join(base, candidate)
                if os.path.realpath(dest) != os.path.join(base, candidate):
                    self._json(400, b'{"error":"invalid_filename"}')
                    return
                try:
                    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    break
                except FileExistsError:
                    candidate = "%s-%d%s" % (stem, index, ext)
                    index += 1
                    if index > 1000:
                        self._json(409, b'{"error":"name_conflict"}')
                        return
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
        except OSError:
            self._json(500, b'{"error":"write_failed"}')
            return
        self._json(200, json.dumps({"path": dest}).encode())

    def do_GET(self):
        self._streaming = False
        self._body_read = False
        try:
            path = urlsplit(self.path).path
            if path == "/health":
                self._json(200, b'{"ok":true}')
            elif path == "/term/stream":
                self._term_stream()
            elif path == "/term/list":
                self._term_list()
            elif path == "/term/winsize":
                self._term_winsize()
            elif path == "/term/preview":
                self._term_preview()
            elif path == "/term/agents":
                self._term_agents()
            elif path == "/term/health":
                self._term_health()
            elif path == "/term/panes":
                self._term_panes()
            elif path == "/term/agent-stream":
                self._term_agent_stream()
            elif path == "/term/agent-chat":
                self._term_agent_chat()
            elif path == "/term/agent-ask":
                self._term_agent_ask()
            elif path == "/term/agent-commands":
                self._term_agent_commands()
            elif path == "/term/agent-work":
                self._term_agent_work()
            elif not self._authed():
                self._json(401, b'{"error":"unauthorized"}')
            elif path == "/tasks":
                self._get_tasks()
            elif path == "/vitals/protocol":
                self._get_health_file("protocol.json")
            elif path == "/vitals/state":
                self._get_health_file("state.json")
            elif path == "/vitals/logs":
                self._get_vitals_logs()
            elif path == "/dispatches":
                self._get_dispatches()
            else:
                m = DISPATCH_STREAM_ROUTE.match(path)
                if m:
                    self._stream_dispatch(m.group(1))
                else:
                    self._json(404, b'{"error":"not_found"}')
        except (ConnectionError, socket.timeout):
            pass
        except Exception:
            if not self._streaming:
                try:
                    self._json(500, b'{"error":"internal"}')
                except OSError:
                    pass

    def do_POST(self):
        self._streaming = False
        self._body_read = False
        try:
            path = urlsplit(self.path).path
            if path == "/term/input":
                self._term_input()
                return
            if path == "/term/resize":
                self._term_resize()
                return
            if path == "/term/kill":
                self._term_kill()
                return
            if path == "/term/rename":
                self._term_rename()
                return
            if path == "/term/upload":
                self._term_upload()
                return
            if path == "/term/agent-upload":
                self._term_agent_upload()
                return
            if path == "/term/attach-agent":
                self._term_attach(TERM_ATTACH_AGENT_PREFIX, True)
                return
            if path == "/term/attach-herdr":
                self._term_attach(TERM_ATTACH_HERDR_PREFIX, False)
                return
            if path == "/term/agent-prompt":
                self._term_agent_prompt()
                return
            if path == "/term/agent-answer":
                self._term_agent_answer()
                return
            if path == "/term/agent-interrupt":
                self._term_agent_interrupt()
                return
            if path == "/term/agent-start":
                self._term_agent_start()
                return
            if path == "/term/agent-ensure":
                self._term_agent_ensure()
                return
            if not self._authed():
                self._json(401, b'{"error":"unauthorized"}')
                return
            m = TASK_ROUTE.match(path)
            if m:
                self._mutate_task(m.group(1), "completed" if m.group(2) == "complete" else "pending")
            elif path == "/tasks":
                self._create_task()
            elif path == "/vitals/state":
                self._put_vitals_state()
            elif path == "/vitals/log":
                self._put_vitals_log()
            elif path == "/chat/stream":
                self._chat_stream()
            else:
                self._json(404, b'{"error":"not_found"}')
        except (ConnectionError, socket.timeout):
            pass
        except Exception:
            if not self._streaming:
                try:
                    self._json(500, b'{"error":"internal"}')
                except OSError:
                    pass

    def do_DELETE(self):
        self._streaming = False
        self._body_read = False
        try:
            path = urlsplit(self.path).path
            if not self._authed():
                self._json(401, b'{"error":"unauthorized"}')
                return
            m = TASK_DELETE_ROUTE.match(path)
            if m:
                self._delete_task(m.group(1))
            else:
                self._json(404, b'{"error":"not_found"}')
        except (ConnectionError, socket.timeout):
            pass
        except Exception:
            if not self._streaming:
                try:
                    self._json(500, b'{"error":"internal"}')
                except OSError:
                    pass

    def _delete_task(self, task_id):
        if not valid_id(task_id):
            self._json(400, b'{"error":"invalid_id"}')
            return
        path = os.path.join(TASKS_DIR, task_id + ".json")
        try:
            os.unlink(path)
        except FileNotFoundError:
            self._json(404, b'{"error":"not_found"}')
            return
        except OSError:
            self._json(500, b'{"error":"internal"}')
            return
        self._json(200, b'{"ok":true}')

    def _get_tasks(self):
        try:
            names = sorted(n for n in os.listdir(TASKS_DIR) if n.endswith(".json") and ".sync-conflict-" not in n)
        except OSError:
            names = []
        parts = []
        for name in names:
            try:
                with open(os.path.join(TASKS_DIR, name), "rb") as f:
                    data = f.read()
            except OSError:
                continue
            if not data.strip():
                continue
            try:
                json.loads(data)
            except ValueError:
                continue
            parts.append(data)
        self._json(200, b"[" + b",".join(parts) + b"]")

    def _mutate_task(self, task_id, new_status):
        if not valid_id(task_id):
            self._json(400, b'{"error":"invalid_id"}')
            return
        path = os.path.join(TASKS_DIR, task_id + ".json")
        for attempt in (0, 1):
            try:
                before = os.stat(path)
                with open(path, "rb") as f:
                    raw = f.read()
            except OSError:
                self._json(404, b'{"error":"not_found"}')
                return
            task = json.loads(raw)
            task["status"] = new_status
            task["modifiedAt"] = now_iso()
            data = json.dumps(task, separators=(",", ":"), ensure_ascii=False).encode()
            fd, tmp = tempfile.mkstemp(dir=TASKS_DIR, prefix=".geobridge-")
            try:
                os.write(fd, data)
                os.fsync(fd)
                os.close(fd)
                fd = -1
                os.chmod(tmp, 0o600)
                current = os.stat(path)
                if attempt == 0 and (current.st_mtime_ns, current.st_size) != (before.st_mtime_ns, before.st_size):
                    os.unlink(tmp)
                    continue
                os.replace(tmp, path)
            except OSError:
                if fd != -1:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                self._json(500, b'{"error":"internal"}')
                return
            self._json(200, data)
            return

    def _create_task(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        try:
            self._body_read = True
            task = json.loads(self.rfile.read(length)) if length else None
        except ValueError:
            task = None
        if not isinstance(task, dict):
            self._json(400, b'{"error":"invalid_body"}')
            return
        title = task.get("title")
        body = task.get("body")
        kind = body.get("kind") if isinstance(body, dict) else None
        if (
            not valid_id(task.get("id"))
            or not isinstance(title, str)
            or not title.strip()
            or kind not in ("task", "event", "habit", "milestone")
            or not isinstance(task.get("createdAt"), str)
        ):
            self._json(400, b'{"error":"invalid_body"}')
            return
        if kind == "task":
            due = body.get("due")
            if not isinstance(due, str) or not due:
                self._json(400, b'{"error":"task_due_required"}')
                return
            try:
                datetime.fromisoformat(due.replace("Z", "+00:00"))
            except ValueError:
                self._json(400, b'{"error":"task_due_required"}')
                return
        path = os.path.join(TASKS_DIR, task["id"] + ".json")
        try:
            marker = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            self._json(409, b'{"error":"task_exists"}')
            return
        except OSError:
            self._json(500, b'{"error":"internal"}')
            return
        os.close(marker)
        data = json.dumps(task, separators=(",", ":"), ensure_ascii=False).encode()
        fd, tmp = tempfile.mkstemp(dir=TASKS_DIR, prefix=".geobridge-")
        try:
            os.write(fd, data)
            os.fsync(fd)
            os.close(fd)
            fd = -1
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except OSError:
            if fd != -1:
                try:
                    os.close(fd)
                except OSError:
                    pass
            try:
                os.unlink(tmp)
            except OSError:
                pass
            try:
                os.unlink(path)
            except OSError:
                pass
            self._json(500, b'{"error":"internal"}')
            return
        self._json(201, data)

    def _get_health_file(self, name):
        try:
            with open(os.path.join(HEALTH_DIR, name), "rb") as f:
                data = f.read()
        except OSError:
            self._json(404, b'{"error":"not_found"}')
            return
        self._json(200, data)

    def _write_health_file(self, name, data):
        path = os.path.join(HEALTH_DIR, name)
        try:
            os.makedirs(HEALTH_DIR, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=HEALTH_DIR, prefix=".geobridge-")
        except OSError:
            self._json(500, b'{"error":"internal"}')
            return False
        try:
            os.write(fd, data)
            os.fsync(fd)
            os.close(fd)
            fd = -1
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except OSError:
            if fd != -1:
                try:
                    os.close(fd)
                except OSError:
                    pass
            try:
                os.unlink(tmp)
            except OSError:
                pass
            self._json(500, b'{"error":"internal"}')
            return False
        return True

    def _read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        try:
            self._body_read = True
            return json.loads(self.rfile.read(length)) if length else None
        except ValueError:
            return None

    def _get_vitals_logs(self):
        try:
            names = sorted(
                n for n in os.listdir(HEALTH_DIR)
                if n.startswith("log-") and n.endswith(".json") and ".sync-conflict-" not in n
            )
        except OSError:
            names = []
        parts = []
        for name in names:
            try:
                with open(os.path.join(HEALTH_DIR, name), "rb") as f:
                    data = f.read()
            except OSError:
                continue
            if not data.strip():
                continue
            try:
                json.loads(data)
            except ValueError:
                continue
            parts.append(data)
        self._json(200, b"[" + b",".join(parts) + b"]")

    def _put_vitals_state(self):
        state = self._read_json_body()
        if not isinstance(state, dict):
            self._json(400, b'{"error":"invalid_body"}')
            return
        index = state.get("anchorIndex")
        if (
            not valid_id(state.get("protocolId"))
            or not valid_date(state.get("anchorDate"))
            or not isinstance(index, int)
            or isinstance(index, bool)
            or not 0 <= index <= 5
        ):
            self._json(400, b'{"error":"invalid_body"}')
            return
        data = json.dumps(state, separators=(",", ":"), ensure_ascii=False).encode()
        if self._write_health_file("state.json", data):
            self._json(200, data)

    def _put_vitals_log(self):
        log = self._read_json_body()
        if not isinstance(log, dict):
            self._json(400, b'{"error":"invalid_body"}')
            return
        index = log.get("sessionIndex")
        exercises = log.get("exercises")
        if (
            not valid_id(log.get("id"))
            or not valid_date(log.get("date"))
            or not isinstance(index, int)
            or isinstance(index, bool)
            or not 0 <= index <= 5
            or not isinstance(exercises, list)
        ):
            self._json(400, b'{"error":"invalid_body"}')
            return
        for exercise in exercises:
            if not isinstance(exercise, dict) or not valid_id(exercise.get("id")) or not isinstance(exercise.get("sets"), list):
                self._json(400, b'{"error":"invalid_body"}')
                return
        data = json.dumps(log, separators=(",", ":"), ensure_ascii=False).encode()
        if self._write_health_file("log-" + log["date"] + ".json", data):
            self._json(200, data)

    def _get_dispatches(self):
        try:
            names = os.listdir(DISPATCHES_DIR)
        except OSError:
            names = []
        entries = []
        for name in names:
            dispatch_dir = os.path.join(DISPATCHES_DIR, name)
            if not os.path.isdir(dispatch_dir):
                continue
            try:
                with open(os.path.join(dispatch_dir, "meta.json"), "rb") as f:
                    meta = f.read()
                parsed = json.loads(meta)
            except (OSError, ValueError):
                continue
            status = "running"
            try:
                with open(os.path.join(dispatch_dir, "status")) as f:
                    value = f.read().strip()
                if value:
                    status = value
            except OSError:
                pass
            started = parsed.get("started_at") if isinstance(parsed, dict) else None
            if isinstance(started, bool) or not isinstance(started, (int, float)):
                m = re.match(r"\d+", name)
                started = int(m.group(0)) if m else 0
            entries.append((started, name, meta, status))
        entries.sort(key=lambda e: (e[0], e[1]), reverse=True)
        parts = [
            b'{"id":' + json.dumps(name).encode() + b',"meta":' + meta + b',"status":' + json.dumps(status).encode() + b"}"
            for _, name, meta, status in entries
        ]
        self._json(200, b"[" + b",".join(parts) + b"]")

    def _stream_dispatch(self, dispatch_id):
        if not valid_id(dispatch_id):
            self._json(400, b'{"error":"invalid_id"}')
            return
        dispatch_dir = os.path.join(DISPATCHES_DIR, dispatch_id)
        if not os.path.isfile(os.path.join(dispatch_dir, "meta.json")):
            self._json(404, b'{"error":"not_found"}')
            return
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self._streaming = True
        log_file = os.path.join(dispatch_dir, "log.jsonl")
        status_file = os.path.join(dispatch_dir, "status")
        state = {"offset": 0, "pending": b"", "last_write": time.monotonic()}

        def read_status():
            try:
                with open(status_file) as f:
                    value = f.read().strip()
                return value or "running"
            except OSError:
                return "running"

        def emit():
            try:
                with open(log_file, "rb") as f:
                    f.seek(state["offset"])
                    chunk = f.read()
            except OSError:
                return
            if not chunk:
                return
            state["offset"] += len(chunk)
            state["pending"] += chunk
            lines = state["pending"].split(b"\n")
            state["pending"] = lines.pop()
            out = b"".join(b"data: " + line + b"\n\n" for line in lines if line)
            if out:
                self.wfile.write(out)
                self.wfile.flush()
                state["last_write"] = time.monotonic()

        while True:
            emit()
            status = read_status()
            if status != "running":
                emit()
                if state["pending"]:
                    self.wfile.write(b"data: " + state["pending"] + b"\n\n")
                self.wfile.write(b"event: done\ndata: " + json.dumps({"status": status}, separators=(",", ":")).encode() + b"\n\n")
                self.wfile.flush()
                return
            if time.monotonic() - state["last_write"] > 15:
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
                state["last_write"] = time.monotonic()
            time.sleep(0.5)

    def _hermes(self, method, path, payload):
        parts = urlsplit(HERMES_URL)
        conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=75)
        conn.request(method, path, payload, {
            "Authorization": "Bearer " + read_hermes_key(),
            "Content-Type": "application/json",
        })
        return conn, conn.getresponse()

    def _relay_error(self, resp, body):
        close = self._undrained() or self.close_connection
        self.send_response(resp.status)
        self.send_header("Content-Type", resp.getheader("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(body)))
        if close:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _chat_stream(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        try:
            self._body_read = True
            body = json.loads(self.rfile.read(length)) if length else None
        except ValueError:
            body = None
        if not isinstance(body, dict) or "message" not in body:
            self._json(400, b'{"error":"invalid_body"}')
            return
        session_id = body.get("session_id")
        if not valid_id(session_id):
            self._json(400, b'{"error":"invalid_id"}')
            return
        payload = json.dumps({"message": body["message"]}, ensure_ascii=False).encode()
        stream_path = "/api/sessions/%s/chat/stream" % session_id
        try:
            conn, resp = self._hermes("POST", stream_path, payload)
        except (OSError, http.client.HTTPException):
            self._json(502, b'{"error":"hermes_unreachable"}')
            return
        if resp.status == 404:
            error_body = resp.read()
            conn.close()
            if b"session_not_found" not in error_body:
                self._relay_error(resp, error_body)
                return
            try:
                create_conn, create_resp = self._hermes("POST", "/api/sessions", json.dumps({"id": session_id}).encode())
                create_resp.read()
                create_conn.close()
                conn, resp = self._hermes("POST", stream_path, payload)
            except (OSError, http.client.HTTPException):
                self._json(502, b'{"error":"hermes_unreachable"}')
                return
        if not 200 <= resp.status < 300:
            error_body = resp.read()
            conn.close()
            self._relay_error(resp, error_body)
            return
        self.close_connection = True
        self.send_response(resp.status)
        self.send_header("Content-Type", resp.getheader("Content-Type", "text/event-stream"))
        session_header = resp.getheader("X-Hermes-Session-Id")
        if session_header:
            self.send_header("X-Hermes-Session-Id", session_header)
        self.end_headers()
        self._streaming = True
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (OSError, http.client.HTTPException):
            pass
        finally:
            conn.close()


def main():
    global TOKEN, TERM_TOKEN
    try:
        with open(TOKEN_FILE) as f:
            TOKEN = f.read().strip()
    except OSError:
        TOKEN = ""
    if not TOKEN:
        sys.stderr.write("geobridge: missing or empty token file: %s\n" % TOKEN_FILE)
        sys.exit(1)
    try:
        with open(TERM_TOKEN_FILE) as f:
            TERM_TOKEN = f.read().strip()
    except OSError:
        TERM_TOKEN = ""
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    agent_watch_start()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    signal.signal(signal.SIGTERM, lambda signum, frame: threading.Thread(target=server.shutdown).start())
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
