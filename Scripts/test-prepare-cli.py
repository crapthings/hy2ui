#!/usr/bin/env python3
"""Check development artifact selection without building an app or changing networking."""
import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock

# Loads the build's single artifact selection implementation.
SPEC = importlib.util.spec_from_file_location("prepare_cli", pathlib.Path(__file__).with_name("prepare-cli.py"))
# Retains the imported preparation module for isolated tests.
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


# Exercises opt-in, integrity and architecture failures before a binary is published.
class DevelopmentArtifactTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name).resolve()
        self.binary = self.root / "core"
        self.binary.write_bytes(b"fixture-not-an-executable")
        self.binary.chmod(0o755)
        self.metadata = {
            "schema_version": 1, "commit": "a" * 40,
            "artifacts": {"arm64": {"path": "core", "sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest()}},
        }
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps(self.metadata))

    def test_debug_validates_architecture_after_hash(self):
        with mock.patch.object(PREPARE.subprocess, "run") as run:
            source, digest, label = PREPARE.development_artifact("debug", "arm64", self.manifest)
        self.assertEqual(source, self.binary)
        self.assertEqual(digest, self.metadata["artifacts"]["arm64"]["sha256"])
        self.assertIn(self.metadata["commit"], label)
        run.assert_called_once_with(["/usr/bin/lipo", str(self.binary), "-verify_arch", "arm64"], check=True)

    def test_release_refuses_even_a_missing_manifest(self):
        with self.assertRaisesRegex(SystemExit, "only in debug"):
            PREPARE.development_artifact("release", "arm64", self.root / "missing.json")

    def test_tampered_binary_is_rejected(self):
        self.binary.write_bytes(b"changed")
        with mock.patch.object(PREPARE.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "SHA-256 mismatch"):
                PREPARE.development_artifact("debug", "arm64", self.manifest)
            run.assert_not_called()

    def test_missing_architecture_never_falls_back(self):
        with self.assertRaisesRegex(SystemExit, "Invalid development"):
            PREPARE.development_artifact("debug", "x86_64", self.manifest)

    def test_architecture_mismatch_fails(self):
        with mock.patch.object(PREPARE.subprocess, "run", side_effect=PREPARE.subprocess.CalledProcessError(1, "lipo")):
            with self.assertRaises(PREPARE.subprocess.CalledProcessError):
                PREPARE.development_artifact("debug", "arm64", self.manifest)


if __name__ == "__main__":
    unittest.main()
