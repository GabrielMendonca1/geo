#!/usr/bin/env python3
"""Regression checks for Vault graph quality and materialized views."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from geo_time_contract import SCRIPTS_DIR, _load_extractor

FAILS: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}{(': ' + detail) if detail else ''}")
    if not condition:
        FAILS.append(name)


def load_geo_context():
    spec = importlib.util.spec_from_file_location("geo_context_quality", SCRIPTS_DIR / "geo_context.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def case_real_moc_discovery() -> None:
    print("\n-- MOCs from the reorganized human tree --")
    geo = load_geo_context()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        geo.BLOCKS_DIR = root / "40 Conhecimento"
        geo.MOC_DIR = root / "00 Entrada" / "Mapas"
        geo.TASKS_DIR = root / "tasks"
        geo.BLOCKS_DIR.mkdir(parents=True)
        geo.MOC_DIR.mkdir(parents=True)
        (geo.BLOCKS_DIR / "Nota.md").write_text("# Nota\n", encoding="utf-8")
        (geo.MOC_DIR / "MOC — Trabalho.md").write_text(
            "---\ntype: moc\n---\n# MOC — Trabalho\n", encoding="utf-8"
        )
        (geo.MOC_DIR / "MOC — Falsa.md").write_text("# MOC — Falsa\n", encoding="utf-8")
        context = geo.gather_brain_context()
        check("discovers a real MOC in 00 Entrada/Mapas", context["moc_titles"] == ["MOC — Trabalho"])
        check("keeps knowledge titles", context["block_titles"] == ["Nota"])
    check("plain § date is provenance", geo._has_day_provenance("§ 2026-09-03 — fato", "2026-09-03"))
    check("plain heading date is provenance", geo._has_day_provenance("## 2026-09-03", "2026-09-03"))


def case_write_guards_and_digest(wa) -> None:
    print("\n-- deterministic MOC and digest guards --")
    valid = {"MOC — Trabalho", "MOC — Pessoal"}
    body, error = wa._validated_block_body("Parte de [[Trabalho]]\nFato [[2026-09-03]]", valid)
    check("short MOC is canonicalized", error is None and body.startswith("Parte de [[MOC — Trabalho]]"), repr((body, error)))
    check("date wikilinks become plain provenance", "[[2026-09-03]]" not in body and "2026-09-03" in body)
    body, error = wa._validated_block_body("Parte de [[Bloko]]\nFato", valid)
    check("unknown MOC is rejected", body is None and error == "MOC inexistente: Bloko")
    body, error = wa._validated_block_body("Fato sem casa", valid)
    check("missing home is rejected", body is None and error is not None)

    lines = ["- Churrasco na casa de Benso em 07/09."]
    merged = wa._merge_digest_line(lines, "Churrasco na casa de Benso em 7 de setembro; Gabriel confirmou presença.")
    check("near-duplicate event is merged", len(merged) == 1)
    check("richer event wins", "confirmou presença" in merged[0])
    day = (
        "## 2026-09-01\n<!-- geo:social:2026-09-01 -->\n"
        "- Churrasco na casa de Benso em 07/09.\n"
        "- Churrasco na casa de Benso em 7 de setembro; Gabriel confirmou presença.\n"
        "<!-- /geo:social:2026-09-01 -->\n[[2026-09-01]]"
    )
    compacted = wa._compact_diary_day("2026-09-01", day)
    check("existing diary duplicates are compacted", compacted.count("Churrasco") == 1)
    check("existing day link becomes plain", "[[2026-09-01]]" not in compacted)
    with tempfile.TemporaryDirectory() as tmp:
        old_path = wa.DIARY_PATH
        wa.DIARY_PATH = Path(tmp) / "Diário de contexto.md"
        wa.DIARY_PATH.write_text(
            "---\nid: TEST-ID\ntype: fleeting\nlayer: review\n---\n# Diário de contexto\nParte de [[MOC — Rotina]]\n\n"
            "<!-- geo:day:2026-09-01 -->\n" + day + "\n<!-- /geo:day:2026-09-01 -->\n",
            encoding="utf-8",
        )
        try:
            changed = wa.compact_daily_digest()
            persisted = wa.DIARY_PATH.read_text(encoding="utf-8")
        finally:
            wa.DIARY_PATH = old_path
        check("daily compaction persists all existing days", changed and persisted.count("Churrasco") == 1)


def case_proposal_reconciliation(wa) -> None:
    print("\n-- stale proposal reconciliation --")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        old_tasks, old_proposals = wa.TASKS_DIR, wa.PROPOSALS_PATH
        wa.TASKS_DIR = root / "tasks"
        wa.PROPOSALS_PATH = root / "proposals.json"
        wa.TASKS_DIR.mkdir()
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (wa.TASKS_DIR / "T1.json").write_text(json.dumps({
            "id": "T1", "title": "Ligar para Jaciva", "status": "completed", "modifiedAt": now,
        }), encoding="utf-8")
        wa.PROPOSALS_PATH.write_text(json.dumps([
            {"hash": "abc123", "title": "Ligar para Jaciva", "status": "pending", "ts": now},
            {"hash": "def456", "title": "Outra tarefa", "status": "pending", "ts": now},
            {"hash": "old789", "title": "Definir o representante da empresa", "status": "pending", "ts": "2026-09-02T10:00:00Z"},
            {"hash": "new789", "title": "Definir representante da empresa", "status": "pending", "ts": now},
        ]), encoding="utf-8")
        try:
            changed = wa.reconcile_proposals({})
            proposals = json.loads(wa.PROPOSALS_PATH.read_text())
        finally:
            wa.TASKS_DIR, wa.PROPOSALS_PATH = old_tasks, old_proposals
        check("exact existing task closes stale proposal", proposals[0]["status"] == "superseded")
        check("unmatched proposal stays pending", proposals[1]["status"] == "pending")
        check("near-identical older proposal is superseded", changed == 2 and proposals[2]["status"] == "superseded" and proposals[3]["status"] == "pending")


def case_alert_and_chat_rollup(wa) -> None:
    print("\n-- existing WhatsApp alert path and chat rollup --")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        wa.OUTBOX_DIR = root / "outbox"
        sent = asyncio.run(wa.send_urgent_alert("alerta de teste"))
        queued = list(wa.OUTBOX_DIR.glob("curator-urgent-*.txt"))
        check("urgent alert uses file outbox", sent and len(queued) == 1)
        check("urgent payload preserved", queued[0].read_text() == "alerta de teste\n")

        wa.BLOCKS_DIR = root / "knowledge"
        wa.BLOCKS_DIR.mkdir()
        wa.CHAT_ROLLUP_PATH = wa.BLOCKS_DIR / "Conversas ativas.md"
        real_find = wa._find_person_block
        wa._find_person_block = lambda label: None
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            count = wa.materialize_chat_summaries({"chats": {
                "5511@s.whatsapp.net": {
                    "label": "5511@s.whatsapp.net", "summary": "Resumo útil",
                    "last_msg_ts": now, "is_group": False,
                },
                "group@g.us": {
                    "label": "Equipe", "summary": "Decisão do projeto",
                    "last_msg_ts": now, "is_group": True,
                },
            }})
        finally:
            wa._find_person_block = real_find
        text = wa.CHAT_ROLLUP_PATH.read_text(encoding="utf-8")
        check("rollup does not require pre-existing people", count == 0 and "Resumo útil" in text)
        check("named chats stay navigable", "## Equipe" in text and "Decisão do projeto" in text)
        check("raw JID is not exposed as a heading", "## 5511@s.whatsapp.net" not in text)


def main() -> int:
    print(f"scripts={SCRIPTS_DIR}")
    case_real_moc_discovery()
    wa = _load_extractor(SCRIPTS_DIR)
    case_write_guards_and_digest(wa)
    case_proposal_reconciliation(wa)
    case_alert_and_chat_rollup(wa)
    print(f"\n{'=' * 48}\n{len(FAILS)} failing case(s): {FAILS or 'none'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
