#!/usr/bin/env python3
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

VAULT = "/mnt/garime/Gabriel"
TASKS = "/mnt/garime/state/tasks"
MOUNT = "/mnt/garime"
SYNC_CONFIG = "/mnt/garime/.syncthing-config/config.xml"
MAC_NAME = "biel-macbook-pro"

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

MAUVE = "\x1b[38;5;177m"
GREEN = "\x1b[38;5;84m"
RED = "\x1b[38;5;197m"
YELLOW = "\x1b[38;5;220m"
SUB = "\x1b[38;5;249m"
SURF = "\x1b[38;5;103m"
BOLD = "\x1b[1m"
RESET = "\x1b[0m"

DASH = RED + "—" + RESET


def vis_len(s):
    return len(ANSI_RE.sub("", s))


def width():
    try:
        cols = shutil.get_terminal_size((46, 24)).columns
    except Exception:
        cols = 46
    return max(24, min(cols, 46))


def clip(s, n):
    return s if len(s) <= n else s[: max(0, n - 1)] + "…"


def human(n):
    try:
        n = float(n)
    except Exception:
        return "—"
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            if unit == "B":
                return "%dB" % int(n)
            return "%.1f%s" % (n, unit)
        n /= 1024.0
    return "—"


def run(cmd):
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=2
    ).stdout.strip()


def http_json(url, headers=None, timeout=2):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def probe_bridge():
    try:
        t0 = time.time()
        req = urllib.request.Request("http://127.0.0.1:8643/health")
        with urllib.request.urlopen(req, timeout=2) as r:
            r.read()
            code = r.status
        ms = int((time.time() - t0) * 1000)
        if 200 <= code < 400:
            return GREEN + "●" + RESET + SUB + " %dms" % ms + RESET
    except Exception:
        pass
    return RED + "●" + RESET + SUB + " down" + RESET


def probe_unit(name):
    try:
        state = run(["systemctl", "is-active", name])
    except Exception:
        state = ""
    if state == "active":
        return GREEN + "●" + RESET + SUB + " active" + RESET
    if not state:
        return DASH
    return RED + "●" + RESET + SUB + " " + clip(state, 10) + RESET


def probe_mac():
    try:
        root = ET.parse(SYNC_CONFIG).getroot()
        key = root.find(".//gui/apikey").text
        names = {}
        for d in root.findall(".//device"):
            did = d.get("id")
            if did:
                names[did] = d.get("name") or ""
        data = http_json(
            "http://127.0.0.1:8384/rest/system/connections",
            {"X-API-Key": key},
        )
        conns = data.get("connections", {})
        for did, name in names.items():
            if name == MAC_NAME:
                if conns.get(did, {}).get("connected"):
                    return GREEN + "●" + RESET + SUB + " online" + RESET
                return RED + "●" + RESET + SUB + " offline" + RESET
    except Exception:
        pass
    return DASH


def probe_vault():
    md = 0
    total = 0
    try:
        for dirpath, dirnames, filenames in os.walk(VAULT):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for f in filenames:
                if f.endswith(".md"):
                    md += 1
                try:
                    total += os.lstat(os.path.join(dirpath, f)).st_size
                except Exception:
                    pass
    except Exception:
        return None
    if not os.path.isdir(VAULT):
        return None
    return md, total


def probe_tasks():
    try:
        return len(
            [
                f
                for f in os.listdir(TASKS)
                if not f.startswith(".")
            ]
        )
    except Exception:
        return None


def probe_tmux():
    try:
        out = run(["tmux", "ls"])
    except Exception:
        return None
    if not out:
        return None
    sessions = []
    for line in out.splitlines():
        if ":" not in line:
            continue
        name = line.split(":", 1)[0]
        sessions.append((name, "(attached)" in line))
    return sessions or None


def probe_disk():
    try:
        st = os.statvfs(MOUNT)
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total <= 0:
            return None
        return total - free, total
    except Exception:
        return None


def probe_mem():
    try:
        vals = {}
        with open("/proc/meminfo") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2:
                    vals[parts[0].rstrip(":")] = int(parts[1]) * 1024
        total = vals["MemTotal"]
        used = total - vals["MemAvailable"]
        return used, total
    except Exception:
        return None


def probe_load():
    try:
        with open("/proc/loadavg") as fh:
            return float(fh.read().split()[0])
    except Exception:
        return None


def probe_uptime():
    try:
        with open("/proc/uptime") as fh:
            secs = float(fh.read().split()[0])
    except Exception:
        return None
    d = int(secs // 86400)
    h = int((secs % 86400) // 3600)
    m = int((secs % 3600) // 60)
    if d:
        return "%dd %dh" % (d, h)
    return "%dh %dm" % (h, m)


def bar(frac, n):
    frac = max(0.0, min(1.0, frac))
    filled = int(round(frac * n))
    color = GREEN
    if frac >= 0.9:
        color = RED
    elif frac >= 0.75:
        color = YELLOW
    return color + "▰" * filled + RESET + SURF + "▱" * (n - filled) + RESET


class Panel:
    def __init__(self, w):
        self.w = w
        self.inner = w - 4
        self.lines = []

    def head(self, title):
        left = "╭─ " + title + " "
        self.lines.append(
            SURF + "╭─" + RESET + MAUVE + " " + title + " " + RESET
            + SURF + "─" * max(0, self.w - vis_len(left) - 1) + "╮" + RESET
        )

    def row(self, label, value):
        lab = clip(label, 9).ljust(9)
        room = self.inner - len(lab) - 1
        plain = ANSI_RE.sub("", value)
        if len(plain) > room:
            value = clip(plain, room)
            plain = ANSI_RE.sub("", value)
        body = SUB + lab + RESET + " " + value
        pad = " " * (self.inner - len(lab) - 1 - len(plain))
        self.lines.append(
            SURF + "│" + RESET + " " + body + pad + " " + SURF + "│" + RESET
        )

    def raw(self, text):
        plain = ANSI_RE.sub("", text)
        if len(plain) > self.inner:
            text = clip(plain, self.inner)
            plain = ANSI_RE.sub("", text)
        pad = " " * (self.inner - len(plain))
        self.lines.append(
            SURF + "│" + RESET + " " + text + pad + " " + SURF + "│" + RESET
        )

    def foot(self):
        self.lines.append(SURF + "╰" + "─" * (self.w - 2) + "╯" + RESET)


def render():
    w = width()
    out = []

    try:
        host = socket.gethostname().split(".")[0]
    except Exception:
        host = "?"
    up = probe_uptime()
    title = BOLD + MAUVE + "GARIME" + RESET
    meta = SUB + host + " · up " + (up or "—") + RESET
    line = title + " " + meta
    if vis_len(line) > w:
        line = title + " " + SUB + clip(host, w - 8) + RESET
    out.append(line)
    out.append(SURF + "─" * w + RESET)

    p = Panel(w)
    p.head("SERVIÇOS")
    p.row("bridge", probe_bridge())
    p.row("wa", probe_unit("garime-wa"))
    p.row("syncthing", probe_unit("syncthing-garime"))
    p.row("mac", probe_mac())
    p.foot()
    out += p.lines

    p = Panel(w)
    p.head("VAULT")
    v = probe_vault()
    t = probe_tasks()
    if v is None:
        p.row("notas", DASH)
        p.row("tamanho", DASH)
    else:
        p.row("notas", YELLOW + "%d" % v[0] + RESET + SUB + " .md" + RESET)
        p.row("tamanho", YELLOW + human(v[1]) + RESET)
    p.row("tarefas", DASH if t is None else YELLOW + str(t) + RESET)
    p.foot()
    out += p.lines

    p = Panel(w)
    p.head("TERM")
    sessions = probe_tmux()
    if not sessions:
        p.row("tmux", SUB + "nenhuma" + RESET)
    else:
        for name, att in sessions[:6]:
            mark = GREEN + "●" + RESET if att else SUB + "○" + RESET
            tag = SUB + (" attached" if att else " detached") + RESET
            p.raw(mark + " " + clip(name, 18) + tag)
    p.foot()
    out += p.lines

    p = Panel(w)
    p.head("MÁQUINA")
    d = probe_disk()
    if d is None:
        p.row("disco", DASH)
    else:
        used, total = d
        p.row("disco", YELLOW + human(used) + RESET + SUB + "/" + human(total) + RESET)
        n = max(8, min(20, p.inner - 6))
        pct = used / float(total)
        p.raw(bar(pct, n) + SUB + " %d%%" % int(pct * 100) + RESET)
    m = probe_mem()
    if m is None:
        p.row("ram", DASH)
    else:
        p.row("ram", YELLOW + human(m[0]) + RESET + SUB + "/" + human(m[1]) + RESET)
    l = probe_load()
    p.row("load", DASH if l is None else YELLOW + "%.2f" % l + RESET)
    p.row("uptime", DASH if up is None else YELLOW + up + RESET)
    p.foot()
    out += p.lines

    return "\n".join(out)


def main():
    live = "--live" in sys.argv[1:]
    if not live:
        print(render())
        return 0
    sys.stdout.write("\x1b[?25l")
    try:
        while True:
            sys.stdout.write("\x1b[2J\x1b[H")
            sys.stdout.write(render() + "\n")
            sys.stdout.flush()
            time.sleep(5)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\x1b[?25h")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.stdout.write("\x1b[?25h\n")
        sys.exit(0)
