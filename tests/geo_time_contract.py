#!/usr/bin/env python3
"""Contract harness for Geo time/timezone handling (loop A+B verification).

Encodes the TARGET contract, not current behavior:
  - The LLM/agent emits LOCAL wall-clock (naive, no Z) or a bare date (YYYY-MM-DD).
  - Code converts naive -> local (America/Sao_Paulo) -> UTC. Explicit tz honored.
  - Date-only / no-time lands on the local end-of-day sentinel (23:59 local ->
    ...T02:59:00Z) so the Swift/EventKit layer renders it all-day.
  - event start/end are converted like every other anchor (today they pass RAW).

Run: python3 tests/geo_time_contract.py   (exit 0 = all cases green)
Targets the SOURCE copies by default so it tests what we edit; override with
GEO_TOOLS_DIR / GEO_SCRIPTS_DIR.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import types
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

SP = ZoneInfo("America/Sao_Paulo")
HOME = Path.home()
TOOLS_DIR = Path(os.environ.get("GEO_TOOLS_DIR", HOME / "ARCA/Forge/Geo/hermes-extensions/geo-tools"))
SCRIPTS_DIR = Path(os.environ.get("GEO_SCRIPTS_DIR", HOME / "ARCA/Forge/Geo/hermes/scripts"))


def z(y, mo, d, h, mi) -> str:
    """Local wall-clock -> canonical stored UTC string."""
    return datetime(y, mo, d, h, mi, tzinfo=SP).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def eod_z(y, mo, d) -> str:
    """Date-only / no-time -> local end-of-day (23:59) -> UTC (the all-day sentinel)."""
    return z(y, mo, d, 23, 59)


def _load_geotools(base: Path):
    """Load the hyphenated `geo-tools` package under a synthetic name so its
    relative imports (from ._fs / .client / .matching) resolve."""
    pkg = types.ModuleType("gtut")
    pkg.__path__ = [str(base)]
    sys.modules["gtut"] = pkg

    def load(name: str):
        spec = importlib.util.spec_from_file_location(f"gtut.{name}", base / f"{name}.py")
        mod = importlib.util.module_from_spec(spec)
        sys.modules[f"gtut.{name}"] = mod
        spec.loader.exec_module(mod)
        return mod

    for dep in ("_fs", "client", "matching"):
        load(dep)
    return load("tasks_fs")


def _load_extractor(base: Path):
    """Import context_scraping for its pure _resolve_due; stub heavy deps it
    imports at module top so the harness runs under a plain python3."""
    for dep in ("httpx",):
        if dep not in sys.modules:
            try:
                __import__(dep)
            except ImportError:
                sys.modules[dep] = types.ModuleType(dep)
    if "geo_context" not in sys.modules:
        gc = types.ModuleType("geo_context")
        gc.render_brain_context = lambda *a, **k: ""
        sys.modules["geo_context"] = gc
    sys.path.insert(0, str(base))
    spec = importlib.util.spec_from_file_location("wa_extractor_ut", base / "context_scraping.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FAILS: list[str] = []


def check(name: str, got, want) -> None:
    ok = got == want
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: got={got!r} want={want!r}")
    if not ok:
        FAILS.append(name)


def main() -> int:
    print(f"tools={TOOLS_DIR}")
    print(f"scripts={SCRIPTS_DIR}")

    tf = _load_geotools(TOOLS_DIR)

    print("\n-- plugin tasks_fs.build_task_body (live-agent write path) --")
    # task/due: naive local time must convert (+3h), not be stamped as UTC
    b = tf.build_task_body({"kind": "task", "due": "2026-12-15T14:50:00"})
    check("task.due naive local->utc", b.get("due"), z(2026, 12, 15, 14, 50))
    # task/due: bare date -> all-day sentinel
    b = tf.build_task_body({"kind": "task", "due": "2026-12-15"})
    check("task.due date-only->eod sentinel", b.get("due"), eod_z(2026, 12, 15))
    # task/due: explicit Z honored as genuine UTC (identity round-trip)
    b = tf.build_task_body({"kind": "task", "due": "2026-12-15T17:50:00Z"})
    check("task.due explicit-Z honored", b.get("due"), "2026-12-15T17:50:00Z")
    # event start/end: MUST be normalized (today they pass RAW -> fails pre-fix)
    b = tf.build_task_body({"kind": "event", "start": "2026-12-15T14:50:00", "end": "2026-12-15T15:50:00"})
    check("event.start naive local->utc", b.get("start"), z(2026, 12, 15, 14, 50))
    check("event.end naive local->utc", b.get("end"), z(2026, 12, 15, 15, 50))
    # habit timeOfDay + milestone target: same rule
    b = tf.build_task_body({"kind": "habit", "recurrence": "daily", "time_of_day": "2026-12-15T07:00:00"})
    check("habit.timeOfDay naive local->utc", b.get("timeOfDay"), z(2026, 12, 15, 7, 0))
    b = tf.build_task_body({"kind": "milestone", "target": "2026-12-15"})
    check("milestone.target date-only->eod sentinel", b.get("target"), eod_z(2026, 12, 15))
    # absolute reminder: naive local must convert (raw passthrough would break Swift .iso8601)
    r = tf._normalize_reminders([{"trigger": "absolute", "at": "2026-12-15T09:00:00"}])
    check("reminder absolute naive local->utc", r[0]["trigger"]["date"], z(2026, 12, 15, 9, 0))

    print("\n-- plugin _normalize_anchor (direct) --")
    check("_normalize_anchor naive local", tf._normalize_anchor("2026-12-15T14:50:00"), z(2026, 12, 15, 14, 50))
    check("_normalize_anchor date-only", tf._normalize_anchor("2026-12-15"), eod_z(2026, 12, 15))

    print("\n-- cron context_scraping._resolve_due --")
    try:
        wa = _load_extractor(SCRIPTS_DIR)
        check("resolve_due naive local->utc", wa._resolve_due("2026-12-15T14:50:00"), z(2026, 12, 15, 14, 50))
        check("resolve_due date-only->eod sentinel", wa._resolve_due("2026-12-15"), eod_z(2026, 12, 15))
        check("resolve_due explicit-Z honored", wa._resolve_due("2026-12-15T17:50:00Z"), "2026-12-15T17:50:00Z")
    except Exception as e:  # import failure counts as a fail, not a crash
        FAILS.append(f"extractor-load ({type(e).__name__}: {e})")
        print(f"  [FAIL] could not load extractor: {e}")

    print(f"\n{'='*48}\n{len(FAILS)} failing case(s): {FAILS or 'none'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
