#!/usr/bin/env python3
"""brain — build and manage Obsidian-like Markdown brain vaults.

A brain is a plain folder of .md notes (YAML frontmatter + [[wikilinks]]) under
~/Geo/Brains/<name>/ — the SOURCE OF TRUTH. The 24/7 agent reads, writes, and
ingests these files directly on the filesystem, so brains work with the Geo app
closed. The Swift app is an optional viewer/indexer over the same folders.

Vault layout:
  ~/Geo/Brains/<name>/
    .brain.json        meta (id, title, gist, counts, sources)
    index.md           the MOC — links every note
    sources/           original attached files (the backup of record)
    *.md               atomic notes (flat, Obsidian-style)

Usage:
  brain create <name> [--gist "..."]
  brain list
  brain ingest <name> <file...> [--dry-run] [--model <id>]
  brain reindex <name>

Ingestion summarizes each source chunk into one atomic note via Anthropic Haiku.
--dry-run skips the model and writes the raw chunk (for structure testing / no key).
API key: $ANTHROPIC_API_KEY, else the `ANTHROPIC_API_KEY` line in ~/.hermes/.env.
Vault root override: $GEO_BRAINS_ROOT (default ~/Geo/Brains).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_MODEL = "claude-haiku-4-5-20251001"
WIKILINK = re.compile(r"\[\[([^\[\]|]+)(?:\|[^\[\]]+)?\]\]")


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
    base = nfc(text).strip().lower()
    base = re.sub(r"[^a-z0-9]+", "-", base).strip("-")
    return base[:60] or fallback


def load_meta(name: str) -> dict:
    path = vault(name) / ".brain.json"
    if path.exists():
        return json.loads(path.read_text())
    return {}


def save_meta(name: str, meta: dict) -> None:
    meta["updated"] = now_iso()
    (vault(name) / ".brain.json").write_text(json.dumps(meta, indent=2, sort_keys=True))


def api_key() -> str | None:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    env = Path.home() / ".hermes" / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line.startswith("ANTHROPIC_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"')
    return None


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
            out = subprocess.run(["pdftotext", str(path), "-"], capture_output=True, text=True)
            return out.stdout
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


def summarize(text: str, brain_title: str, source: str, key: str, model: str) -> str:
    system = (
        "You distill one chunk of an external source into a single atomic Markdown note "
        "for an Obsidian-style Zettelkasten. Output ONLY Markdown, no code fences. "
        "Line 1 is '# Title' — a concise, self-contained title. Then 2-5 sentences in your "
        "own words. Wrap every salient concept/entity/term in [[wikilinks]] so the vault connects. "
        f'This chunk is from "{source}" in the "{brain_title}" knowledge base.'
    )
    body = json.dumps({
        "model": model,
        "max_tokens": 1024,
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": text}],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "content-type": "application/json",
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "prompt-caching-2024-07-31",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
    return "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text").strip()


def title_of(markdown: str, fallback: str) -> str:
    for line in markdown.splitlines():
        s = line.strip()
        if s.startswith("#"):
            return s.lstrip("#").strip() or fallback
    return fallback


def write_note(name: str, title: str, markdown: str, source: str, chash: str) -> str:
    used = {p.stem for p in vault(name).glob("*.md")}
    slug, base, n = slugify(title), slugify(title), 1
    while slug in used:
        slug = f"{base}-{n}"
        n += 1
    front = f"---\ntype: literature\nsource: {source}\nchunk: {chash}\ncreated: {now_iso()}\n---\n"
    (vault(name) / f"{slug}.md").write_text(front + markdown.rstrip() + "\n")
    return slug


def reindex(name: str) -> int:
    meta = load_meta(name)
    notes = sorted(p for p in vault(name).glob("*.md") if p.name != "index.md")
    lines = [f"# {meta.get('title', name)}", ""]
    if meta.get("gist"):
        lines += [meta["gist"], ""]
    lines += [f"## Notes ({len(notes)})", ""]
    lines += [f"- [[{p.stem}]]" for p in notes]
    (vault(name) / "index.md").write_text("\n".join(lines) + "\n")
    meta["nodes"] = len(notes)
    save_meta(name, meta)
    return len(notes)


def cmd_create(args) -> None:
    name = args.name
    if vault(name).exists():
        raise SystemExit(f"Brain already exists: {vault(name)}")
    (vault(name) / "sources").mkdir(parents=True)
    save_meta(name, {"id": name, "title": args.title or name, "gist": args.gist or "",
                     "created": now_iso(), "nodes": 0, "sources": []})
    reindex(name)
    print(f"Created brain: {vault(name)}")


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
    key = None if args.dry_run else api_key()
    if not args.dry_run and not key:
        raise SystemExit("No ANTHROPIC_API_KEY (env or ~/.hermes/.env). Use --dry-run to test without it.")
    existing = {p.read_text().split("chunk: ", 1)[1].split("\n", 1)[0]
                for p in vault(name).glob("*.md") if "chunk: " in p.read_text()}
    written = 0
    for raw in args.files:
        src = Path(raw).expanduser()
        if not src.exists():
            print(f"  skip (missing): {src}", file=sys.stderr)
            continue
        dest = vault(name) / "sources" / src.name
        shutil.copy2(src, dest)
        if src.name not in meta.get("sources", []):
            meta.setdefault("sources", []).append(src.name)
        for piece in chunk(extract_text(src)):
            chash = sha(piece)
            if chash in existing:
                continue
            existing.add(chash)
            if args.dry_run:
                md = "# " + " ".join(piece.split()[:6]) + "\n\n" + piece
            else:
                md = summarize(piece, meta.get("title", name), src.name, key, args.model)
            write_note(name, title_of(md, src.stem), md, src.name, chash)
            written += 1
    count = reindex(name)
    save_meta(name, meta)
    print(f"Ingested {written} new notes into '{name}' ({count} total). Vault: {vault(name)}")


def cmd_reindex(args) -> None:
    if not vault(args.name).exists():
        raise SystemExit(f"No such brain: {args.name}")
    print(f"Reindexed '{args.name}': {reindex(args.name)} notes")


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="brain", description="Manage Obsidian-like brain vaults.")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create"); c.add_argument("name"); c.add_argument("--title"); c.add_argument("--gist"); c.set_defaults(fn=cmd_create)
    l = sub.add_parser("list"); l.set_defaults(fn=cmd_list)
    i = sub.add_parser("ingest"); i.add_argument("name"); i.add_argument("files", nargs="+")
    i.add_argument("--dry-run", action="store_true"); i.add_argument("--model", default=DEFAULT_MODEL); i.set_defaults(fn=cmd_ingest)
    r = sub.add_parser("reindex"); r.add_argument("name"); r.set_defaults(fn=cmd_reindex)
    args = p.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
