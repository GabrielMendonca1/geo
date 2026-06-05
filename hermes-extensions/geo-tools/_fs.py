"""Shared filesystem primitives for the file-native Geo tools.

The Geo vault is truth: blocks are ``.md`` under ``Blocks/`` (YAML frontmatter
+ inline body), tasks are ``.json`` under ``Tasks/``. The Geo.app FileWatcher
reconciles its derived SQLite index after any out-of-band write — so reads.py
and tasks_fs.py write files directly and never call HTTP.

``now_iso`` MUST stay ``%Y-%m-%dT%H:%M:%SZ`` (UTC, NO microseconds): Swift's
``.iso8601`` decoder rejects fractional seconds and would silently drop the
whole task from the app's in-memory store.
"""

from __future__ import annotations

import json
import os
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

GEO_HOME = Path.home() / "Library" / "Application Support" / "Geo"
BLOCKS_DIR = GEO_HOME / "Blocks"
TASKS_DIR = GEO_HOME / "Tasks"
INDEX_DB = GEO_HOME / "Index" / "blocks.sqlite"


def nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s or "")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def atomic_write_json(path: Path, obj) -> None:
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=2))


def split_frontmatter(text: str) -> tuple[str, str]:
    """Return (frontmatter_block_including_fences, body). ('', text) if none."""
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[: end + 5], text[end + 5 :]
    return "", text


def parse_frontmatter(text: str) -> dict:
    """Flat key:value parse of a block's frontmatter (layer/type/status/...).

    Good enough for the scalar Properties Geo writes; values stay raw strings.
    """
    fm, _ = split_frontmatter(text)
    out: dict[str, str] = {}
    if not fm:
        return out
    for line in fm.splitlines():
        if line in ("---", ""):
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out
