#!/usr/bin/env python3
"""brain — build and manage Obsidian-like Markdown brain vaults.

A brain is a plain folder of .md notes (YAML frontmatter + [[wikilinks]]) under
~/Geo/Brains/<name>/ — the SOURCE OF TRUTH. The 24/7 agent reads, writes, and
ingests these files directly on the filesystem, so brains work with the Geo app
closed. The Swift app is an optional viewer/indexer over the same folders.

Ingestion uses the **Claude Code account** (the Claude Max OAuth credential the
`claude` CLI stores in the macOS Keychain — no separate API key) and the
**Anthropic Message Batches API** to distill every source chunk into one atomic
note cheaply and asynchronously.

Usage:
  brain create <name> [--title "…"] [--gist "…"]
  brain list
  brain ingest <name> <file…> [--dry-run] [--model <id>]
  brain reindex <name>

--dry-run skips the model entirely (writes raw chunks) — for structure testing.
Vault root override: $GEO_BRAINS_ROOT (default ~/Geo/Brains).
"""
import argparse
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_MODEL = "claude-haiku-4-5"
ANTHROPIC = "https://api.anthropic.com"

# --- Claude Code account (Max OAuth from Keychain) — same path haiku.py / whatsapp-extractor use
KEYCHAIN_SERVICE = "Claude Code-credentials"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_ENDPOINTS = (
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
)
OAUTH_BETA = "oauth-2025-04-20"
BATCH_BETA = "message-batches-2024-09-24"
USER_AGENT = "claude-cli/2.1.152 (external, cli)"
TOKEN_EXPIRY_BUFFER_MS = 60_000


def log(msg: str) -> None:
    print(f"[brain] {msg}", file=sys.stderr, flush=True)


def root() -> Path:
    return Path(os.environ.get("GEO_BRAINS_ROOT", str(Path.home() / "Geo" / "Brains")))


def vault(name: str) -> Path:
    return root() / name


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def sha(text: str) -> str:
    return hashlib.sha256(nfc(text).encode("utf-8")).hexdigest()


def slugify(text: str, fallback: str = "note") -> str:
    base = re.sub(r"[^a-z0-9]+", "-", nfc(text).strip().lower()).strip("-")
    return base[:60] or fallback


def load_meta(name: str) -> dict:
    path = vault(name) / ".brain.json"
    return json.loads(path.read_text()) if path.exists() else {}


def save_meta(name: str, meta: dict) -> None:
    meta["updated"] = now_iso()
    (vault(name) / ".brain.json").write_text(json.dumps(meta, indent=2, sort_keys=True))


# ---------------------------------------------------------------- OAuth (Claude Code account)

def _keychain_read() -> dict | None:
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as e:
        log(f"keychain lookup failed: {e}")
        return None
    if out.returncode != 0:
        return None
    try:
        full = json.loads(out.stdout.strip())
    except Exception:
        return None
    return full if isinstance(full.get("claudeAiOauth"), dict) else None


def _keychain_write(full: dict) -> None:
    try:
        subprocess.run(
            ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
             "-a", getpass.getuser(), "-w", json.dumps(full)],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as e:
        log(f"keychain write error: {e}")


def _refresh_oauth(refresh_token: str) -> dict | None:
    body = urllib.parse.urlencode(
        {"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": OAUTH_CLIENT_ID}
    ).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT}
    for url in OAUTH_TOKEN_ENDPOINTS:
        try:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
            if data.get("access_token"):
                return data
        except Exception as e:
            log(f"oauth refresh at {url} failed: {type(e).__name__}")
    return None


def load_oauth_token() -> str | None:
    full = _keychain_read()
    if not full:
        return None
    oauth = full["claudeAiOauth"]
    access = oauth.get("accessToken")
    exp_ms = oauth.get("expiresAt")
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    if access and (not exp_ms or now_ms < exp_ms - TOKEN_EXPIRY_BUFFER_MS):
        return access
    refresh = oauth.get("refreshToken")
    if not refresh:
        return access
    refreshed = _refresh_oauth(refresh)
    if not refreshed:
        return access
    oauth["accessToken"] = refreshed["access_token"]
    oauth["refreshToken"] = refreshed.get("refresh_token", refresh)
    oauth["expiresAt"] = now_ms + int(refreshed.get("expires_in", 3600)) * 1000
    _keychain_write(full)
    return oauth["accessToken"]


def _auth_headers(token: str) -> dict:
    return {
        "content-type": "application/json",
        "authorization": f"Bearer {token}",
        "anthropic-version": "2023-06-01",
        "anthropic-beta": f"{OAUTH_BETA},{BATCH_BETA}",
        "user-agent": USER_AGENT,
        "x-app": "cli",
    }


def _api(method: str, url: str, token: str, body: dict | None = None, timeout: int = 60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=_auth_headers(token), method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="ignore")[:400]
        raise SystemExit(f"Anthropic {method} {url} -> HTTP {e.code}: {detail}")


# ---------------------------------------------------------------- Batch ingestion

def _system_prompt(brain_title: str, source: str) -> str:
    return (
        "You distill one chunk of an external source into a single atomic Markdown note "
        "for an Obsidian-style Zettelkasten. Output ONLY Markdown, no code fences. "
        "Line 1 is '# Title' — a concise, self-contained title. Then 2-5 sentences in your "
        "own words. Wrap every salient concept/entity/term in [[wikilinks]] so the vault connects. "
        f'This chunk is from "{source}" in the "{brain_title}" knowledge base.'
    )


def run_batch(items: list[tuple[str, str, str]], brain_title: str, model: str, token: str) -> dict[str, str]:
    """items: list of (custom_id, source_label, chunk_text). Returns {custom_id: markdown}."""
    requests = [
        {
            "custom_id": cid,
            "params": {
                "model": model,
                "max_tokens": 1024,
                "system": [{"type": "text", "text": _system_prompt(brain_title, src)}],
                "messages": [{"role": "user", "content": text}],
            },
        }
        for cid, src, text in items
    ]
    log(f"submitting batch of {len(requests)} chunks to {model} (Claude Code account)…")
    created = _api("POST", f"{ANTHROPIC}/v1/messages/batches", token, {"requests": requests})
    batch_id = created["id"]
    log(f"batch {batch_id} submitted; polling…")
    waited, interval, max_wait = 0, 5, 3600
    results_url = None
    while True:
        status = _api("GET", f"{ANTHROPIC}/v1/messages/batches/{batch_id}", token)
        st = status.get("processing_status")
        counts = status.get("request_counts", {})
        if st == "ended":
            results_url = status.get("results_url")
            break
        if waited >= max_wait:
            raise SystemExit(f"batch {batch_id} timed out (status={st})")
        log(f"  …{st} {counts}")
        time.sleep(interval)
        waited += interval
    out: dict[str, str] = {}
    req = urllib.request.Request(results_url, headers=_auth_headers(token), method="GET")
    with urllib.request.urlopen(req, timeout=180) as resp:
        for line in resp.read().decode().splitlines():
            if not line.strip():
                continue
            obj = json.loads(line)
            res = obj.get("result", {})
            if res.get("type") == "succeeded":
                content = res.get("message", {}).get("content", [])
                text = "".join(b.get("text", "") for b in content if b.get("type") == "text").strip()
                if text:
                    out[obj.get("custom_id")] = text
            else:
                log(f"  chunk {obj.get('custom_id')} {res.get('type')}: {str(res)[:120]}")
    log(f"batch done: {len(out)}/{len(requests)} notes returned")
    return out


# ---------------------------------------------------------------- extraction / chunking

def extract_text(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in {".txt", ".md", ".markdown", ".text"}:
        return path.read_text(errors="ignore")
    if ext in {".html", ".htm"}:
        raw = path.read_text(errors="ignore")
        raw = re.sub(r"(?s)<(script|style)\b.*?</\1>", " ", raw)
        raw = re.sub(r"<[^>]+>", " ", raw)
        for a, b in (("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">")):
            raw = raw.replace(a, b)
        return "\n".join(l.strip() for l in raw.splitlines() if l.strip())
    if ext == ".pdf":
        if shutil.which("pdftotext"):
            return subprocess.run(["pdftotext", str(path), "-"], capture_output=True, text=True).stdout
        raise SystemExit("PDF needs `pdftotext` (brew install poppler) — or convert to .txt first.")
    raise SystemExit(f"Unsupported source type: {ext} ({path.name})")


def chunk(text: str, target: int = 800, overlap: int = 80) -> list[str]:
    words = text.split()
    if not words:
        return []
    stride = max(1, target - overlap)
    chunks, start = [], 0
    while start < len(words):
        end = min(start + target, len(words))
        chunks.append(" ".join(words[start:end]))
        if end == len(words):
            break
        start += stride
    return chunks


def title_of(markdown: str, fallback: str) -> str:
    for line in markdown.splitlines():
        s = line.strip()
        if s.startswith("#"):
            return s.lstrip("#").strip() or fallback
    return fallback


def write_note(name: str, title: str, markdown: str, source: str, chash: str) -> None:
    used = {p.stem for p in vault(name).glob("*.md")}
    slug, base, n = slugify(title), slugify(title), 1
    while slug in used:
        slug = f"{base}-{n}"
        n += 1
    front = f"---\ntype: literature\nsource: {source}\nchunk: {chash}\ncreated: {now_iso()}\n---\n"
    (vault(name) / f"{slug}.md").write_text(front + markdown.rstrip() + "\n")


def reindex(name: str) -> int:
    meta = load_meta(name)
    notes = sorted(p for p in vault(name).glob("*.md") if p.name != "index.md")
    lines = [f"# {meta.get('title', name)}", ""]
    if meta.get("gist"):
        lines += [meta["gist"], ""]
    lines += [f"## Notes ({len(notes)})", ""] + [f"- [[{p.stem}]]" for p in notes]
    (vault(name) / "index.md").write_text("\n".join(lines) + "\n")
    meta["nodes"] = len(notes)
    save_meta(name, meta)
    return len(notes)


# ---------------------------------------------------------------- commands

def cmd_create(args) -> None:
    if vault(args.name).exists():
        raise SystemExit(f"Brain already exists: {vault(args.name)}")
    (vault(args.name) / "sources").mkdir(parents=True)
    save_meta(args.name, {"id": args.name, "title": args.title or args.name, "gist": args.gist or "",
                          "created": now_iso(), "nodes": 0, "sources": []})
    reindex(args.name)
    print(f"Created brain: {vault(args.name)}")


def cmd_list(args) -> None:
    base = root()
    if not base.exists():
        print(f"No brains yet ({base})")
        return
    for meta_file in sorted(base.glob("*/.brain.json")):
        m = json.loads(meta_file.read_text())
        print(f"{m.get('id'):24} {m.get('nodes', 0):>4} notes  {m.get('gist', '')[:60]}")


def cmd_ingest(args) -> None:
    name = args.name
    if not vault(name).exists():
        raise SystemExit(f"No such brain: {name} (run `brain create {name}` first)")
    meta = load_meta(name)
    existing = {p.read_text().split("chunk: ", 1)[1].split("\n", 1)[0]
                for p in vault(name).glob("*.md") if "chunk: " in p.read_text()}

    # collect pending chunks across all sources
    pending: list[tuple[str, str, str]] = []  # (chunk_hash, source_label, text)
    for raw in args.files:
        src = Path(raw).expanduser()
        if not src.exists():
            print(f"  skip (missing): {src}", file=sys.stderr)
            continue
        shutil.copy2(src, vault(name) / "sources" / src.name)
        if src.name not in meta.get("sources", []):
            meta.setdefault("sources", []).append(src.name)
        for piece in chunk(extract_text(src)):
            chash = sha(piece)
            if chash in existing:
                continue
            existing.add(chash)
            pending.append((chash, src.name, piece))

    if not pending:
        save_meta(name, meta)
        print(f"No new chunks for '{name}' ({reindex(name)} notes).")
        return

    if args.dry_run:
        for chash, source, text in pending:
            write_note(name, "# " + " ".join(text.split()[:6]), "# " + " ".join(text.split()[:6]) + "\n\n" + text, source, chash)
    else:
        token = load_oauth_token()
        if not token:
            raise SystemExit("No Claude Code credential in Keychain. Log in with `claude` first, or use --dry-run.")
        labels = {chash: source for chash, source, _ in pending}
        results = run_batch(pending, meta.get("title", name), args.model, token)
        for chash, md in results.items():
            write_note(name, title_of(md, "Untitled"), md, labels.get(chash, "source"), chash)

    save_meta(name, meta)
    print(f"Ingested {min(len(pending), len(list(vault(name).glob('*.md'))))} chunks → '{name}' ({reindex(name)} notes). Vault: {vault(name)}")


def cmd_reindex(args) -> None:
    if not vault(args.name).exists():
        raise SystemExit(f"No such brain: {args.name}")
    print(f"Reindexed '{args.name}': {reindex(args.name)} notes")


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="brain", description="Manage Obsidian-like brain vaults.")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create"); c.add_argument("name"); c.add_argument("--title"); c.add_argument("--gist"); c.set_defaults(fn=cmd_create)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    i = sub.add_parser("ingest"); i.add_argument("name"); i.add_argument("files", nargs="+")
    i.add_argument("--dry-run", action="store_true"); i.add_argument("--model", default=DEFAULT_MODEL); i.set_defaults(fn=cmd_ingest)
    r = sub.add_parser("reindex"); r.add_argument("name"); r.set_defaults(fn=cmd_reindex)
    args = p.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
