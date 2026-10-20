#!/usr/bin/env python3

import contextlib
import copy
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TRAINING = ROOT / "GeoBridge" / "training"
SPEC = importlib.util.spec_from_file_location(
    "generate_week_plan",
    ROOT / "GeoBridge" / "tools" / "generate_week_plan.py",
)
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


class GenerateWeekPlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((TRAINING / "catalog.json").read_text())
        cls.blocks = json.loads((TRAINING / "blocks.json").read_text())
        cls.safety = json.loads((TRAINING / "safety.json").read_text())
        cls.exercises = {value["id"]: value for value in cls.catalog["exercises"]}
        cls.block_index = {value["id"]: value for value in cls.blocks["blocks"]}

    def build(self, days, revision=1):
        return generator.build_plan(self.catalog, self.blocks, self.safety, "2026-W35", days, revision)

    def test_four_and_five_day_variants_are_valid_deterministic_and_safe(self):
        denied_reviews = set(self.safety["publicationRules"]["denyReviewStates"])
        denied_gate_states = set(self.safety["publicationRules"]["denyGateStates"])
        gates = {value["id"]: value for value in self.safety["gates"]}
        blocked_by_gate = {
            exercise_id
            for gate in gates.values()
            if gate["state"] in denied_gate_states
            for exercise_id in gate.get("exerciseIds", [])
        }
        for count in (4, 5):
            first = self.build(count)
            second = self.build(count)
            self.assertEqual(generator.plan_bytes(first), generator.plan_bytes(second))
            self.assertTrue(generator.valid_plan(first))
            training_days = [day for day in first["days"] if not day["rest"]]
            self.assertEqual(len(training_days), count)
            for day in training_days:
                ids = [item["exerciseId"] for item in day["items"]]
                self.assertEqual(len(ids), len(set(ids)))
                for item in day["items"]:
                    exercise_id = item["exerciseId"]
                    exercise = self.exercises[exercise_id]
                    self.assertEqual(item["doseType"], exercise["doseType"])
                    self.assertNotIn(exercise_id, generator.DENIED_IDS)
                    self.assertNotIn(exercise_id, blocked_by_gate)
                    self.assertNotIn(exercise["reviewState"], denied_reviews)
                    self.assertNotIn(exercise["shoulderTier"], {"C", "COND"})
                    self.assertTrue(generator.DENIED_RISK_FLAGS.isdisjoint(exercise["riskFlags"]))
            self.assertNotIn("protocol", first)
            self.assertNotIn("state", first)

    def test_every_session_uses_publishable_blocks_with_time_inside_limits(self):
        for count in (4, 5):
            recipes = generator.RECIPES[count]
            for recipe in recipes:
                duration = sum(self.block_index[block_id]["estimatedMinutes"] for block_id in recipe)
                self.assertGreaterEqual(duration, generator.MIN_SESSION_MINUTES)
                self.assertLessEqual(duration, generator.MAX_SESSION_MINUTES)
                for block_id in recipe:
                    block = self.block_index[block_id]
                    self.assertTrue(block["publishable"])
                    self.assertEqual(block["blockedReasons"], [])

    def test_invalid_reference_review_gate_and_time_fail_closed(self):
        missing = copy.deepcopy(self.blocks)
        missing["blocks"][0]["items"][0]["exerciseId"] = "missing"
        denied = copy.deepcopy(self.catalog)
        next(value for value in denied["exercises"] if value["id"] == "remada-baixa")["reviewState"] = "pending"
        gate = copy.deepcopy(self.safety)
        gate["gates"][0]["state"] = "unknown"
        duration = copy.deepcopy(self.blocks)
        next(value for value in duration["blocks"] if value["id"] == "bl.aquecimento")["estimatedMinutes"] = 100
        cases = (
            (self.catalog, missing, self.safety),
            (denied, self.blocks, self.safety),
            (self.catalog, self.blocks, gate),
            (self.catalog, duration, self.safety),
        )
        for catalog, blocks, safety in cases:
            with self.assertRaises(generator.GenerationError):
                generator.build_plan(catalog, blocks, safety, "2026-W35", 5)

    def test_versioned_five_day_example_is_generator_output(self):
        fixture = ROOT / "GeoBridge" / "fixtures" / "training" / "generated" / "plan-2026-W35.r2-5days.json"
        expected = generator.plan_bytes(self.build(5, revision=2))
        self.assertEqual(fixture.read_bytes(), expected)
        self.assertTrue(generator.valid_plan(json.loads(expected)))
        self.assertFalse(list(fixture.parent.glob("protocol.json")))
        self.assertFalse(list(fixture.parent.glob("state.json")))

    def test_historical_revision_one_remains_valid_without_dose_metadata(self):
        fixture = ROOT / "GeoBridge" / "fixtures" / "training" / "generated" / "plan-2026-W35.r1-5days.json"
        plan = json.loads(fixture.read_text())
        self.assertTrue(generator.valid_plan(plan))
        self.assertTrue(all("doseType" not in item for day in plan["days"] for item in day["items"]))

    def test_cli_refuses_legacy_state_output_names(self):
        with tempfile.TemporaryDirectory() as directory:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                generator.main([
                    "--week", "2026-W35",
                    "--days", "4",
                    "--output", str(pathlib.Path(directory) / "state.json"),
                ])
            self.assertFalse(pathlib.Path(directory, "state.json").exists())


if __name__ == "__main__":
    unittest.main()
