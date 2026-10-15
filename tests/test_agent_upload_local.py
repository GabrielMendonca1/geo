"""Contrato do upload gravado no proprio host do bridge (agente de sessao)."""

import importlib.util
import os
import stat
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "geobridge_upload", os.path.join(ROOT, "GeoBridge", "geobridge.py")
)
geobridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(geobridge)


class LocalUploadWriteTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()

    def write(self, name, data=b"payload"):
        return geobridge.local_upload_write(name, data, home=self.home)

    def test_writes_inside_the_uploads_directory(self):
        path = self.write("foto-20260825.jpg")
        self.assertTrue(path.startswith(self.home))
        self.assertIn(geobridge.AGENT_UPLOAD_DIR, path)
        with open(path, "rb") as handle:
            self.assertEqual(handle.read(), b"payload")

    def test_never_overwrites_an_existing_upload(self):
        first = self.write("foto.jpg", b"um")
        second = self.write("foto.jpg", b"dois")
        self.assertNotEqual(first, second)
        self.assertTrue(second.endswith("foto-1.jpg"))
        with open(first, "rb") as handle:
            self.assertEqual(handle.read(), b"um")

    def test_file_is_private_to_the_owner(self):
        path = self.write("segredo.jpg")
        mode = stat.S_IMODE(os.stat(path).st_mode)
        self.assertEqual(mode, 0o600)

    def test_directory_is_private_to_the_owner(self):
        path = self.write("foto.jpg")
        mode = stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode)
        self.assertEqual(mode, 0o700)

    def test_returned_path_matches_the_contract_regex(self):
        path = self.write("foto.jpg")
        self.assertTrue(geobridge.AGENT_UPLOAD_PATH_RE.match(path))

    def test_does_not_follow_a_symlink_planted_at_the_target(self):
        directory = os.path.join(self.home, geobridge.AGENT_UPLOAD_DIR)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        victim = os.path.join(self.home, "vitima.txt")
        with open(victim, "wb") as handle:
            handle.write(b"intocado")
        os.symlink(victim, os.path.join(directory, "foto.jpg"))

        path = self.write("foto.jpg", b"invasor")

        self.assertTrue(path.endswith("foto-1.jpg"))
        with open(victim, "rb") as handle:
            self.assertEqual(handle.read(), b"intocado")


if __name__ == "__main__":
    unittest.main()
