"""User-layer (Você) write-guard for the file-native block tools.

Mirrors ``BlockLayer.allowsAgentWrites`` (Geo BlockType.swift:63) — agents may
write only ``agent``/``review``/``shared`` blocks, never ``user`` (Você). The
HTTP path never actually enforced this (the Swift property existed but no
router/tool checked it); going file-native is the first place it is real.

Layer truth is the frontmatter ``layer:`` (absent → ``user``, matching
``BlockLayer.default``). The folder segment is checked FIRST so the guard keeps
working after the ADR-0002 layer-folder split (Voce/Agente/Revisao/
Compartilhado), even though the vault is flat today.
"""

from __future__ import annotations

from pathlib import Path

from ._fs import BLOCKS_DIR, parse_frontmatter
from .client import GeoError

_AGENT_LAYERS = frozenset({"agent", "review", "shared"})

# folder-segment slug -> layer (BlockLayer.init?(folderSegment:), NFC-lowercased)
_FOLDER_LAYER = {
    "voce": "user",
    "agente": "agent",
    "revisao": "review",
    "compartilhado": "shared",
}


def _folder_layer(path: Path) -> str | None:
    try:
        rel = path.relative_to(BLOCKS_DIR)
    except ValueError:
        return None
    for seg in rel.parts[:-1]:
        layer = _FOLDER_LAYER.get(seg.lower())
        if layer is not None:
            return layer
    return None


def layer_of(path: Path) -> str:
    """Effective layer of a block file: folder segment first, then frontmatter,
    defaulting to 'user' (BlockLayer.default) when neither is present."""
    folder = _folder_layer(path)
    if folder is not None:
        return folder
    try:
        fm = parse_frontmatter(path.read_text(encoding="utf-8"))
    except OSError:
        return "user"
    return (fm.get("layer") or "user").strip() or "user"


def assert_writable(path: Path) -> None:
    """Refuse agent mutation/relabel/delete of a user-layer block."""
    if layer_of(path) not in _AGENT_LAYERS:
        raise GeoError(
            f"refused: '{path.name}' is a user-layer (Você) block — "
            "agents may only write agent/review/shared blocks"
        )


def assert_create_layer(layer: str, folder: str = "") -> None:
    """Refuse creating a user-layer block or filing into a Você/ folder."""
    seg = (folder or "").strip("/").split("/", 1)[0].lower() if folder else ""
    if _FOLDER_LAYER.get(seg) == "user":
        raise GeoError("refused: cannot create a block in the user (Você) folder")
    if layer not in _AGENT_LAYERS:
        raise GeoError(
            f"refused: cannot create a '{layer}'-layer block — "
            "agents may only create agent/review/shared blocks"
        )


def assert_set_layer(target_layer: str) -> None:
    """Refuse moving a block into the user layer."""
    if target_layer not in _AGENT_LAYERS:
        raise GeoError("refused: cannot move a block into the user (Você) layer")
