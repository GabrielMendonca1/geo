#!/usr/bin/env python3

import http.client
import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1] / "GeoBridge"
SPEC = importlib.util.spec_from_file_location("geobridge_log_contract", ROOT / "geobridge.py")
geobridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(geobridge)


class LogIdentityContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        geobridge.HEALTH_DIR = self.temp.name
        geobridge.LOG_PATH = str(pathlib.Path(self.temp.name) / "access.log")
        geobridge.TOKEN = "test-token"
        self.server = geobridge.ThreadingHTTPServer(("127.0.0.1", 0), geobridge.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def request(self, method, path, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        headers = {"Authorization": "Bearer test-token"}
        encoded = None
        if body is not None:
            encoded = json.dumps(body, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        connection.request(method, path, body=encoded, headers=headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, data

    def legacy(self):
        return {
            "id": "legacy-log",
            "date": "2026-08-23",
            "sessionIndex": 3,
            "exercises": [{"id": "remada-baixa", "sets": [{"reps": 12, "kg": 40.0}]}],
            "note": "ok",
            "futureField": {"preserve": True},
        }

    def plan(self):
        return {
            "id": "plan-log",
            "date": "2026-08-24",
            "planId": "plan-2026-W35.r12",
            "planDayId": "2026-08-24",
            "exercises": [{"id": "remada-baixa", "sets": []}],
            "note": "",
        }

    def test_legacy_and_plan_identities_are_accepted_and_mixed_on_read(self):
        for payload in (self.legacy(), self.plan()):
            status, data = self.request("POST", "/vitals/log", payload)
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(data), payload)
        status, data = self.request("GET", "/vitals/logs")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data), [self.legacy(), self.plan()])
        self.assertFalse(pathlib.Path(self.temp.name, "state.json").exists())

    def test_identity_is_strict_and_plan_provenance_is_coherent(self):
        cases = []
        mixed = self.plan()
        mixed["sessionIndex"] = 1
        cases.append((mixed, "mixed_identity"))
        missing = self.plan()
        missing.pop("planId")
        missing.pop("planDayId")
        cases.append((missing, "missing_identity"))
        partial = self.plan()
        partial.pop("planDayId")
        cases.append((partial, "invalid_plan_identity"))
        wrong_day = self.plan()
        wrong_day["planDayId"] = "2026-08-25"
        cases.append((wrong_day, "invalid_plan_day"))
        wrong_week = self.plan()
        wrong_week["planId"] = "plan-2026-W34.r1"
        cases.append((wrong_week, "invalid_plan_week"))
        invalid_date = self.plan()
        invalid_date["date"] = "2026-02-30"
        invalid_date["planDayId"] = "2026-02-30"
        cases.append((invalid_date, "invalid_body"))
        for payload, error in cases:
            status, data = self.request("POST", "/vitals/log", payload)
            self.assertEqual((status, json.loads(data)["error"]), (400, error))

    def test_legacy_unknown_fields_round_trip_and_past_log_is_untouched(self):
        old = self.legacy()
        old_bytes = json.dumps(old, separators=(",", ":"), ensure_ascii=False).encode()
        old_path = pathlib.Path(self.temp.name, "log-2026-08-23.json")
        old_path.write_bytes(old_bytes)
        status, data = self.request("POST", "/vitals/log", self.plan())
        self.assertEqual(status, 200)
        self.assertEqual(old_path.read_bytes(), old_bytes)
        status, data = self.request("GET", "/vitals/logs")
        self.assertEqual(status, 200)
        logs = json.loads(data)
        self.assertEqual(logs[0], old)
        self.assertEqual(logs[0]["futureField"], {"preserve": True})


if __name__ == "__main__":
    unittest.main()
