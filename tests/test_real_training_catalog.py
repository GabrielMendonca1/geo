#!/usr/bin/env python3
"""Deterministic integrity tests for the canonical real training catalog."""

import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TRAINING = ROOT / "GeoBridge" / "training"
LEGACY_IDS = {
    "puxada-alta",
    "remada-baixa",
    "remada-cavalinho",
    "desenvolvimento-ombro",
    "elevacao-lateral",
    "elevacao-posterior",
    "cadeira-extensora",
    "agachamento-sumo",
    "leg-press",
    "passada",
    "supino",
    "voador-crucifixo",
    "paralela",
    "rosca-alternada-inclinada",
    "rosca-w",
    "rosca-concentrada",
    "triceps-corda",
    "triceps-testa",
    "triceps-polia-alta",
    "mesa-flexora",
    "cadeira-flexora-unilateral",
    "stiff",
    "elevacao-pelvica",
}
REQUIRED_METADATA = {
    "pattern",
    "goals",
    "riskFlags",
    "shoulderTier",
    "substitutes",
    "doseType",
    "variantNote",
    "reviewState",
}
TIER_RANK = {"A": 0, "B": 1, "COND": 2, "C": 3}


class RealTrainingCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((TRAINING / "catalog.json").read_text())
        cls.blocks = json.loads((TRAINING / "blocks.json").read_text())
        cls.safety = json.loads((TRAINING / "safety.json").read_text())
        cls.exercises = {item["id"]: item for item in cls.catalog["exercises"]}

    def test_canonical_directory_contains_only_static_artifacts(self):
        self.assertEqual(
            {path.name for path in TRAINING.iterdir() if path.is_file()},
            {"README.md", "catalog.json", "blocks.json", "safety.json"},
        )
        forbidden = {"protocol.json", "state.json"}
        self.assertTrue(forbidden.isdisjoint(path.name for path in TRAINING.iterdir()))
        self.assertFalse(list(TRAINING.glob("plan-*.json")))

    def test_catalog_has_37_unique_ids_and_exact_legacy_set(self):
        exercises = self.catalog["exercises"]
        ids = [item["id"] for item in exercises]
        self.assertEqual(len(ids), 37)
        self.assertEqual(len(set(ids)), 37)
        self.assertEqual({item["id"] for item in exercises if "legado" in item["tags"]}, LEGACY_IDS)
        self.assertEqual(sum("novo-2026" in item["tags"] for item in exercises), 14)
        self.assertFalse(any(item_id.startswith("demo.") for item_id in ids))

    def test_catalog_statuses_metadata_and_current_app_shape(self):
        self.assertEqual(self.catalog["schema"], "vitals.catalog/1")
        self.assertGreater(self.catalog["version"], 0)
        for item in self.catalog["exercises"]:
            self.assertIn(item["status"], {"active", "retired"})
            self.assertTrue(REQUIRED_METADATA.issubset(item))
            self.assertIsInstance(item["name"], str)
            self.assertIsInstance(item["muscles"], list)
            self.assertIsInstance(item["equipment"], str)
            self.assertIsInstance(item["tags"], list)
            self.assertIn(item["shoulderTier"], TIER_RANK)

    def test_substitutes_resolve_without_reducing_safety(self):
        for source in self.catalog["exercises"]:
            for substitute_id in source["substitutes"]:
                self.assertIn(substitute_id, self.exercises)
                substitute = self.exercises[substitute_id]
                self.assertLessEqual(TIER_RANK[substitute["shoulderTier"]], TIER_RANK[source["shoulderTier"]])
                self.assertNotEqual(substitute["reviewState"], "locked")

    def test_block_items_resolve_and_publishable_blocks_are_safe_now(self):
        block_ids = [block["id"] for block in self.blocks["blocks"]]
        self.assertEqual(len(block_ids), len(set(block_ids)))
        self.assertEqual(self.blocks["schema"], "vitals.blocks/1")
        for block in self.blocks["blocks"]:
            for item in block["items"]:
                self.assertIn(item["exerciseId"], self.exercises)
                self.assertGreaterEqual(item["restSec"], 0)
                self.assertTrue(item["sets"])
                self.assertTrue(all(len(value) == 2 and 0 < value[0] <= value[1] for value in item["sets"]))
                exercise = self.exercises[item["exerciseId"]]
                if block["publishable"]:
                    self.assertNotIn(
                        exercise["reviewState"],
                        set(self.safety["publicationRules"]["denyReviewStates"]),
                    )
                    self.assertNotIn(exercise["shoulderTier"], {"C", "COND"})

    def test_locked_and_conditional_items_never_leak_to_publishable_blocks(self):
        unavailable = {
            item["id"]
            for item in self.catalog["exercises"]
            if item["reviewState"] == "locked" or item["shoulderTier"] == "COND"
        }
        published = {
            item["exerciseId"]
            for block in self.blocks["blocks"]
            if block["publishable"]
            for item in block["items"]
        }
        self.assertTrue(unavailable.isdisjoint(published))

    def test_professional_gates_cannot_be_unlocked_by_self_report(self):
        gates = {gate["id"]: gate for gate in self.safety["gates"]}
        overhead = {item["id"] for item in self.catalog["exercises"] if "overhead-load" in item["riskFlags"]}
        self.assertEqual(overhead, set(gates["gate-overhead-load"]["exerciseIds"]))
        self.assertTrue(all(self.exercises[item_id]["reviewState"] == "locked" for item_id in overhead))
        for gate_id in ("gate-overhead-load", "gate-manguito-escapula", "gate-tier-c"):
            gate = gates[gate_id]
            self.assertEqual(gate["state"], "locked")
            self.assertTrue(gate["professionalClearanceRequired"])
            self.assertFalse(gate["selfReportAloneCanUnlock"])
        self.assertEqual(gates["gate-tier-b-sem-overhead"]["state"], "pending")
        self.assertEqual(gates["gate-tier-b-sem-overhead"]["currentCondition"], "overhead-discomfort-present")
        self.assertEqual(
            set(self.safety["publicationRules"]["denyReviewStates"]),
            {"locked", "pending", "phase-gated"},
        )
        self.assertFalse(self.safety["governance"]["agentMayUnlockGates"])
        self.assertIn("não é tratamento nem cura", self.safety["disclaimer"])

    def test_conditional_manguito_block_uses_recalculated_duration(self):
        block = next(item for item in self.blocks["blocks"] if item["id"] == "bl.manguito-escapula")
        self.assertFalse(block["publishable"])
        self.assertEqual(block["estimatedMinutes"], 13.0)


if __name__ == "__main__":
    unittest.main()
