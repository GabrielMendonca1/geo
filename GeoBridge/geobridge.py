#!/usr/bin/env python3
import base64
import fcntl
import hmac
import http.client
import json
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TASKS_DIR = os.path.expanduser(os.environ.get("GEO_TASKS_DIR", "~/GeoVault/Tasks"))
DISPATCHES_DIR = os.path.expanduser(os.environ.get("GEO_DISPATCHES_DIR", "~/.hermes/dispatches"))
BIND = os.environ.get("GEO_BRIDGE_BIND", "100.123.44.9")
PORT = int(os.environ.get("GEO_BRIDGE_PORT", "8643"))
TOKEN_FILE = os.path.expanduser(os.environ.get("GEO_BRIDGE_TOKEN_FILE", "~/.hermes/geobridge.token"))
HERMES_URL = os.environ.get("HERMES_URL", "http://127.0.0.1:8642")
HERMES_KEY_FILE = os.path.expanduser(os.environ.get("HERMES_KEY_FILE", "~/.hermes/api_server.key"))
LOG_PATH = os.path.expanduser("~/Library/Logs/geobridge.log")

TERM_ENABLED = os.environ.get("GEO_TERM_ENABLED", "0") == "1"
TERM_TMUX = os.environ.get("GEO_TERM_TMUX", "/opt/homebrew/bin/tmux")
TERM_SHELL = os.environ.get("GEO_TERM_SHELL", "")
TERM_SESSION = os.environ.get("GEO_TERM_SESSION", "mobile")
TERM_SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
TERM_TOKEN_FILE = os.path.expanduser(os.environ.get("GEO_BRIDGE_TERM_TOKEN_FILE", "~/.hermes/geobridge.term.token"))
TERM_IDLE_SECONDS = 600

ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
TASK_ROUTE = re.compile(r"^/tasks/([^/]+)/(complete|reopen)$")
DISPATCH_STREAM_ROUTE = re.compile(r"^/dispatches/([^/]+)/stream$")

TOKEN = ""
TERM_TOKEN = ""
LOG_LOCK = threading.Lock()
TERM_REGISTRY = {}
TERM_REGISTRY_LOCK = threading.Lock()


class TermSession:
    def __init__(self, master_fd, pid, session):
        self.master_fd = master_fd
        self.pid = pid
        self.session = session
        self.write_lock = threading.Lock()
        self.last_activity = time.monotonic()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def valid_id(value):
    return isinstance(value, str) and ID_RE.match(value) is not None and value not in (".", "..")


def read_hermes_key():
    try:
        with open(HERMES_KEY_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


class Handler(BaseHTTPRequestHandler):
    timeout = 30

    def log_request(self, code="-", size="-"):
        line = "%s %s %s %s %s\n" % (now_iso(), self.client_address[0], self.command, self.path, code)
        try:
            with LOG_LOCK:
                with open(LOG_PATH, "a") as f:
                    f.write(line)
        except OSError:
            pass

    def _json(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
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
        q = parse_qs(urlsplit(self.path).query)
        name = (q.get("session") or [TERM_SESSION])[0]
        return name if TERM_SESSION_RE.match(name) else TERM_SESSION

    def _term_spawn(self, session, ignore_size=False):
        args = [
            TERM_TMUX, "-u", "new-session", "-A", "-s", session,
            ";", "set-option", "mouse", "on",
            ";", "set-option", "-g", "history-limit", "100000",
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
                os.execve(TERM_TMUX, args, child_env)
            except BaseException:
                os._exit(127)
        return TermSession(master_fd, pid, session)

    def _term_close(self, sess):
        with TERM_REGISTRY_LOCK:
            if TERM_REGISTRY.get(sess.session) is sess:
                del TERM_REGISTRY[sess.session]
        try:
            os.kill(sess.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(sess.pid, 0)
        except OSError:
            pass
        try:
            os.close(sess.master_fd)
        except OSError:
            pass
        if self._streaming:
            try:
                self.wfile.write(b'event: done\ndata: {"status":"closed"}\n\n')
                self.wfile.flush()
            except OSError:
                pass

    def _term_has_sizing_client(self, session):
        try:
            out = subprocess.run(
                [TERM_TMUX, "list-clients", "-t", session, "-F", "#{client_flags}"],
                capture_output=True, timeout=5,
            ).stdout.decode("utf-8", "replace")
            return any(line and "ignore-size" not in line for line in out.split("\n"))
        except Exception:
            return False

    def _term_stream(self):
        if not self._term_gate():
            return
        session = self._term_session_name()
        with TERM_REGISTRY_LOCK:
            old = TERM_REGISTRY.pop(session, None)
        if old is not None:
            try:
                os.kill(old.pid, signal.SIGKILL)
            except OSError:
                pass
            time.sleep(0.15)
        sess = self._term_spawn(session, self._term_has_sizing_client(session))
        try:
            with TERM_REGISTRY_LOCK:
                TERM_REGISTRY[session] = sess
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self._streaming = True
            last_write = time.monotonic()
            while True:
                with TERM_REGISTRY_LOCK:
                    if TERM_REGISTRY.get(session) is not sess:
                        return
                r, _, _ = select.select([sess.master_fd], [], [], 0.5)
                now = time.monotonic()
                if r:
                    try:
                        data = os.read(sess.master_fd, 65536)
                    except OSError:
                        data = b""
                    if not data:
                        return
                    self.wfile.write(b"data: " + base64.b64encode(data) + b"\n\n")
                    self.wfile.flush()
                    last_write = now
                    sess.last_activity = now
                if now - sess.last_activity > TERM_IDLE_SECONDS:
                    return
                if now - last_write > 15:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_write = now
        finally:
            self._term_close(sess)

    def _term_input(self):
        if not self._term_gate():
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length else b""
        try:
            data = base64.b64decode(raw, validate=True)
        except ValueError:
            self._json(400, b'{"error":"invalid_body"}')
            return
        with TERM_REGISTRY_LOCK:
            sess = TERM_REGISTRY.get(self._term_session_name())
        if sess is None:
            self._json(409, b'{"error":"no_attach"}')
            return
        try:
            with sess.write_lock:
                os.write(sess.master_fd, data)
        except OSError:
            self._json(409, b'{"error":"no_attach"}')
            return
        sess.last_activity = time.monotonic()
        self._json(200, b'{"ok":true}')

    def _term_resize(self):
        if not self._term_gate():
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        try:
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
        with TERM_REGISTRY_LOCK:
            sess = TERM_REGISTRY.get(self._term_session_name())
        if sess is None:
            self._json(409, b'{"error":"no_attach"}')
            return
        try:
            with sess.write_lock:
                fcntl.ioctl(sess.master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            self._json(409, b'{"error":"no_attach"}')
            return
        sess.last_activity = time.monotonic()
        self._json(200, b'{"ok":true}')

    def _term_winsize(self):
        if not self._term_gate():
            return
        session = self._term_session_name()
        try:
            out = subprocess.run(
                [TERM_TMUX, "display-message", "-p", "-t", session, "#{window_width} #{window_height}"],
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
        try:
            out = subprocess.run(
                [TERM_TMUX, "list-sessions", "-F", "#{session_name}"],
                capture_output=True, timeout=5,
            ).stdout.decode("utf-8", "replace")
            names = [n for n in out.split("\n") if n]
        except Exception:
            names = []
        self._json(200, json.dumps({"sessions": names}).encode())

    def _term_kill(self):
        if not self._term_gate():
            return
        session = self._term_session_name()
        with TERM_REGISTRY_LOCK:
            sess = TERM_REGISTRY.get(session)
        if sess is not None:
            try:
                os.kill(sess.pid, signal.SIGKILL)
            except OSError:
                pass
        try:
            subprocess.run([TERM_TMUX, "kill-session", "-t", session], capture_output=True, timeout=5)
        except Exception:
            pass
        self._json(200, b'{"ok":true}')

    def do_GET(self):
        self._streaming = False
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
            elif not self._authed():
                self._json(401, b'{"error":"unauthorized"}')
            elif path == "/tasks":
                self._get_tasks()
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
            if not self._authed():
                self._json(401, b'{"error":"unauthorized"}')
                return
            m = TASK_ROUTE.match(path)
            if m:
                self._mutate_task(m.group(1), "completed" if m.group(2) == "complete" else "pending")
            elif path == "/tasks":
                self._create_task()
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
                os.chmod(tmp, 0o644)
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
        path = os.path.join(TASKS_DIR, task["id"] + ".json")
        try:
            marker = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
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
            os.chmod(tmp, 0o644)
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
        self.send_response(resp.status)
        self.send_header("Content-Type", resp.getheader("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _chat_stream(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        try:
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
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    signal.signal(signal.SIGTERM, lambda signum, frame: threading.Thread(target=server.shutdown).start())
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
