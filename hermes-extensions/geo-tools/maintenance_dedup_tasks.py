#!/usr/bin/env python3
"""Dedup Geo pending tasks — file-native (the vault is truth).

Groups pending tasks by (normalized title, kind), keeps the earliest-created
one in each group, and deletes the rest (native rm of Tasks/<id>.json — the
Geo.app FileWatcher reconciles the derived index). Milestones are never
touched. A task and an event with the same title are treated as DIFFERENT
(kept) because kind differs.

Usage:
    python3 maintenance_dedup_tasks.py            # dry run, prints what it would delete
    python3 maintenance_dedup_tasks.py --commit   # actually delete duplicates
"""
import json
import os
import sys
import unicodedata
from pathlib import Path

TASKS_DIR = Path.home() / "Vault" / "Tasks"


def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    return " ".join(s.lower().split())


def _kind(t):
    body = t.get("body") or {}
    return body.get("kind") if isinstance(body, dict) else None


def load_pending():
    if not TASKS_DIR.exists():
        sys.exit(f"{TASKS_DIR} missing — is Geo installed?")
    out = []
    for p in sorted(TASKS_DIR.glob("*.json")):
        try:
            t = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if t.get("status") == "completed":
            continue
        t["_path"] = p
        out.append(t)
    return out


def main():
    commit = "--commit" in sys.argv
    tasks = load_pending()

    groups = {}
    for t in tasks:
        if _kind(t) == "milestone":
            continue
        key = (norm(t.get("title")), _kind(t))
        groups.setdefault(key, []).append(t)

    to_delete = []
    for (title, kind), items in groups.items():
        if len(items) < 2:
            continue
        items.sort(key=lambda x: x.get("createdAt") or x.get("created_at") or x.get("id") or "")
        keep, dups = items[0], items[1:]
        for d in dups:
            to_delete.append((d, keep))

    if not to_delete:
        print("No duplicates found.")
        return

    print(f"Found {len(to_delete)} duplicate(s):")
    for d, keep in to_delete:
        print(f"  DELETE {d['id']}  '{d.get('title')}' [{_kind(d)}]  (keeping {keep['id']})")

    if not commit:
        print("\nDry run. Re-run with --commit to delete.")
        return

    for d, _ in to_delete:
        os.remove(d["_path"])
        print(f"  deleted {d['id']} '{d.get('title')}'")
    print("Done.")


if __name__ == "__main__":
    main()
