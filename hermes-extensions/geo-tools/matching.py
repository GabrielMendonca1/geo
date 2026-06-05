"""Shared title normalization + fuzzy scoring for the semantic task tools.

Stdlib only (``unicodedata``, ``difflib``, ``re``). Used by ``geo_find_tasks``,
``geo_resolve_task`` and ``geo_upsert_task`` so all three score identically.
"""

from __future__ import annotations

import re
import unicodedata
from difflib import SequenceMatcher
from typing import Any

_PUNCT = re.compile(r"[^\w\s]", re.UNICODE)
_WS = re.compile(r"\s+")


def normalize(s: Any) -> str:
    """Lowercase, strip accents, drop punctuation, collapse whitespace."""
    if not s:
        return ""
    text = unicodedata.normalize("NFKD", str(s))
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.lower()
    text = _PUNCT.sub(" ", text)
    return _WS.sub(" ", text).strip()


def _score_norm(q: str, title: str) -> float:
    """Similarity in [0, 1] against an already-normalized query `q`."""
    t = normalize(title)
    if not q or not t:
        return 0.0
    if q == t:
        return 1.0

    substring = 0.0
    if q in t or t in q:
        shorter, longer = (q, t) if len(q) <= len(t) else (t, q)
        substring = 0.7 + 0.3 * (len(shorter) / len(longer))

    ratio = SequenceMatcher(None, q, t).ratio()

    q_tokens = set(q.split())
    t_tokens = set(t.split())
    jaccard = 0.0
    if q_tokens and t_tokens:
        inter = len(q_tokens & t_tokens)
        union = len(q_tokens | t_tokens)
        jaccard = inter / union if union else 0.0

    return max(substring, ratio, jaccard)


def score(query: str, title: str) -> float:
    """Similarity in [0, 1]: max of substring, sequence ratio, and token Jaccard."""
    return _score_norm(normalize(query), title)


def rank(query: str, tasks: list, limit: int | None = None) -> list:
    """Score each task's title against query; return copies with a ``score`` key, desc."""
    q = normalize(query)
    scored = []
    for task in tasks:
        item = dict(task)
        item["score"] = round(_score_norm(q, task.get("title", "")), 4)
        scored.append(item)
    scored.sort(key=lambda x: x["score"], reverse=True)
    if limit is not None:
        scored = scored[:limit]
    return scored
