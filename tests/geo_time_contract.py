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
GEO_SCRIPTS_DIR.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import types
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

SP = ZoneInfo("America/Sao_Paulo")
_DEFAULT_SCRIPTS = Path(__file__).resolve().parent.parent / "hermes" / "scripts"
SCRIPTS_DIR = Path(os.environ.get("GEO_SCRIPTS_DIR") or _DEFAULT_SCRIPTS)


def z(y, mo, d, h, mi) -> str:
    """Local wall-clock -> canonical stored UTC string."""
    return datetime(y, mo, d, h, mi, tzinfo=SP).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def eod_z(y, mo, d) -> str:
    """Date-only / no-time -> local end-of-day (23:59) -> UTC (the all-day sentinel)."""
    return z(y, mo, d, 23, 59)


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
        gc.gather_brain_context = lambda *a, **k: {"moc_titles": [], "block_titles": [], "open_tasks": []}
        gc.render_brain_context = lambda *a, **k: ""
        sys.modules["geo_context"] = gc
    sys.path.insert(0, str(base))
    with tempfile.TemporaryDirectory() as tmp:
        stub = Path(tmp)
        (stub / "__init__.py").write_text("")
        (stub / "geo_write.py").write_text("class _GeoError(Exception):\n    pass\n")
        (stub / "tasks_fs.py").write_text("def _default_reminders(body):\n    return []\n")
        real_spec_from_file = importlib.util.spec_from_file_location

        def _redirecting(name, location=None, *args, **kwargs):
            if name == "geo_tools":
                kwargs["submodule_search_locations"] = [str(stub)]
                return real_spec_from_file(name, stub / "__init__.py", *args, **kwargs)
            return real_spec_from_file(name, location, *args, **kwargs)

        importlib.util.spec_from_file_location = _redirecting
        try:
            spec = real_spec_from_file("wa_extractor_ut", base / "context_scraping.py")
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        finally:
            importlib.util.spec_from_file_location = real_spec_from_file
    return mod


FAILS: list[str] = []


def check(name: str, got, want) -> None:
    ok = got == want
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: got={got!r} want={want!r}")
    if not ok:
        FAILS.append(name)


def main() -> int:
    print(f"scripts={SCRIPTS_DIR}")

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
