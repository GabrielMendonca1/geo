#!/usr/bin/env python3
"""Dedup Geo pending tasks over the local HTTP API.

Groups pending tasks by (normalized title, kind), keeps the earliest-created
one in each group, and deletes the rest via DELETE /tasks/{id}.
Milestones are never touched. A task and an event with the same title are
treated as DIFFERENT (kept) because kind differs.

Usage:
    python3 geo_dedup.py            # dry run, prints what it would delete
    python3 geo_dedup.py --commit   # actually delete duplicates
"""
import json
import subprocess
import sys
import unicodedata
import urllib.request
import urllib.error
from pathlib import Path

API_JSON = Path.home() / "Library" / "Application Support" / "Geo" / "api.json"
KEYCHAIN_SERVICE = "geo-api-bootstrap"
KEYCHAIN_ACCOUNT = "hermes-runtime"


def base_url():
    if not API_JSON.exists():
        sys.exit("api.json missing — open Geo.app first")
    obj = json.loads(API_JSON.read_text())
    return f"http://127.0.0.1:{obj['port']}/v1"


def token():
    p = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
         "-a", KEYCHAIN_ACCOUNT, "-w"],
        capture_output=True, text=True, timeout=5)
    if p.returncode != 0 or not p.stdout.strip():
        sys.exit(f"keychain miss ({KEYCHAIN_SERVICE}/{KEYCHAIN_ACCOUNT})")
    return p.stdout.strip()


def req(method, url, tok, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", f"Bearer {tok}")
    r.add_header("X-Caller-Id", "claude-code-dedup")
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} -> {e.code}: {e.read().decode(errors='replace')}")


def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    return " ".join(s.lower().split())


def main():
    commit = "--commit" in sys.argv
    b = base_url()
    tok = token()
    tasks = req("GET", f"{b}/tasks?status=pending", tok) or []

    groups = {}
    for t in tasks:
        if t.get("kind") == "milestone":
            continue
        key = (norm(t.get("title")), t.get("kind"))
        groups.setdefault(key, []).append(t)

    to_delete = []
    for (title, kind), items in groups.items():
        if len(items) < 2:
            continue
        items.sort(key=lambda x: x.get("created_at") or x.get("createdAt") or x.get("id") or "")
        keep, dups = items[0], items[1:]
        for d in dups:
            to_delete.append((d, keep))

    if not to_delete:
        print("No duplicates found.")
        return

    print(f"Found {len(to_delete)} duplicate(s):")
    for d, keep in to_delete:
        print(f"  DELETE {d['id']}  '{d.get('title')}' [{d.get('kind')}]  (keeping {keep['id']})")

    if not commit:
        print("\nDry run. Re-run with --commit to delete.")
        return

    for d, _ in to_delete:
        req("DELETE", f"{b}/tasks/{d['id']}", tok)
        print(f"  deleted {d['id']} '{d.get('title')}'")
    print("Done.")


if __name__ == "__main__":
    main()
