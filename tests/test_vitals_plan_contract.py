#!/usr/bin/env python3
"""GeoBridge training catalog and frozen weekly-plan contract tests."""

import copy
import http.client
import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1] / "GeoBridge"
SPEC = importlib.util.spec_from_file_location("geobridge", ROOT / "geobridge.py")
geobridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(geobridge)


class TrainingContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        geobridge.HEALTH_DIR = self.temp.name
        geobridge.LOG_PATH = str(pathlib.Path(self.temp.name) / "access.log")
        geobridge.TOKEN = "test-token"
        self.server = geobridge.ThreadingHTTPServer(("127.0.0.1", 0), geobridge.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]
        self.fixture = json.loads((ROOT / "fixtures/training/plan-2026-W35.r1.json").read_text())

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def request(self, method, path, body=None, authorized=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        headers = {}
        if authorized:
            headers["Authorization"] = "Bearer test-token"
        encoded = None
        if body is not None:
            encoded = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        connection.request(method, path, body=encoded, headers=headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, data

    def revision(self, number):
        payload = copy.deepcopy(self.fixture)
        payload["revision"] = number
        payload["id"] = f"plan-{payload['week']}.r{number}"
        return payload

    def test_training_routes_require_auth_and_missing_files_are_empty_state(self):
        status, _ = self.request("GET", "/vitals/catalog", authorized=False)
        self.assertEqual(status, 401)
        for path in ("/vitals/catalog", "/vitals/blocks", "/vitals/safety", "/vitals/plan?week=2026-W35"):
            status, data = self.request("GET", path)
            self.assertEqual((status, json.loads(data)["error"]), (404, "not_found"))

    def test_plan_is_validated_write_once_and_latest_revision_wins(self):
        status, _ = self.request("GET", "/vitals/plan?week=2026-W99")
        self.assertEqual(status, 400)
        status, data = self.request("POST", "/vitals/plan", self.fixture)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)["revision"], 1)
        self.assertTrue((pathlib.Path(self.temp.name) / "plan-2026-W35.r1.json").exists())

        status, _ = self.request("POST", "/vitals/plan", self.fixture)
        self.assertEqual(status, 409)
        status, _ = self.request("POST", "/vitals/plan", self.revision(3))
        self.assertEqual(status, 400)
        status, _ = self.request("POST", "/vitals/plan", self.revision(2))
        self.assertEqual(status, 200)

        conflict = pathlib.Path(self.temp.name) / "plan-2026-W35.r99.sync-conflict-copy.json"
        conflict.write_text(json.dumps(self.revision(99)))
        status, data = self.request("GET", "/vitals/plan?week=2026-W35")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)["revision"], 2)

    def test_malformed_plan_is_rejected_and_plan_files_do_not_enter_logs(self):
        malformed = copy.deepcopy(self.fixture)
        malformed["days"] = malformed["days"][:-1]
        status, _ = self.request("POST", "/vitals/plan", malformed)
        self.assertEqual(status, 400)

        pathlib.Path(self.temp.name, "log-2026-08-03.json").write_text('{"id":"log-demo"}')
        pathlib.Path(self.temp.name, "plan-2026-W35.r1.json").write_text(json.dumps(self.fixture))
        status, data = self.request("GET", "/vitals/logs")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data), [{"id": "log-demo"}])

    def test_catalog_and_blocks_are_served_verbatim(self):
        for name, endpoint in (("catalog.json", "/vitals/catalog"), ("blocks.json", "/vitals/blocks")):
            expected = (ROOT / "fixtures/training" / name).read_bytes()
            pathlib.Path(self.temp.name, name).write_bytes(expected)
            status, data = self.request("GET", endpoint)
            self.assertEqual(status, 200)
            self.assertEqual(data, expected)


if __name__ == "__main__":
    unittest.main()
