"""Contract tests for the shared, standard-library Python provisioner."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import venv
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/provision_python.py"
SPEC = importlib.util.spec_from_file_location("provision_python", SCRIPT)
provision_python = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provision_python)


class ProvisionPythonTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zaq-provision-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.crawler = self.root / "crawler with spaces"
        self.crawler.mkdir()
        self.destination = self.root / "venv with spaces"

    def run_script(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.crawler), str(self.destination)],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

    def write_lock(self, contents):
        (self.crawler / "requirements.lock").write_text(contents, encoding="utf-8")

    def test_recreates_existing_venv_at_final_path_and_checks_it(self):
        self.write_lock("# No application dependencies in this fixture.\n")
        venv.EnvBuilder(with_pip=False).create(self.destination)
        stale = self.destination / "stale-package-marker"
        stale.write_text("old", encoding="utf-8")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(stale.exists())
        python = provision_python.venv_python(self.destination)
        self.assertTrue(python.is_file())
        self.assertEqual(
            subprocess.run(
                [str(python), "-m", "pip", "check"],
                capture_output=True,
                text=True,
                check=False,
            ).returncode,
            0,
        )

    def test_missing_lock_preserves_existing_venv(self):
        venv.EnvBuilder(with_pip=False).create(self.destination)
        marker = self.destination / "keep-me"
        marker.write_text("old", encoding="utf-8")

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Crawler lock is missing", result.stderr)
        self.assertEqual(marker.read_text(encoding="utf-8"), "old")

    def test_refuses_non_venv_directory_and_symlink(self):
        self.write_lock("# Fixture lock.\n")
        self.destination.mkdir()
        marker = self.destination / "keep-me"
        marker.write_text("old", encoding="utf-8")

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace non-venv", result.stderr)
        self.assertEqual(marker.read_text(encoding="utf-8"), "old")

        marker.unlink()
        self.destination.rmdir()
        self.destination.symlink_to(self.crawler, target_is_directory=True)

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace symlink", result.stderr)
        self.assertTrue(self.crawler.is_dir())

    def test_install_failure_removes_incomplete_venv(self):
        self.write_lock("--not-a-real-pip-option\n")

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Python provisioning failed", result.stderr)
        self.assertFalse(self.destination.exists())

    def test_pip_check_failure_removes_incomplete_venv(self):
        wheel = self.root / "broken_dep-1.0-py3-none-any.whl"
        dist_info = "broken_dep-1.0.dist-info"
        with zipfile.ZipFile(wheel, "w") as archive:
            archive.writestr(
                f"{dist_info}/METADATA",
                "Metadata-Version: 2.1\nName: broken-dep\nVersion: 1.0\n"
                "Requires-Dist: missing-zaq-provision-test>=1\n",
            )
            archive.writestr(
                f"{dist_info}/WHEEL",
                "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
            )
            archive.writestr(f"{dist_info}/RECORD", "")
        self.write_lock(f"{wheel.as_uri()}\n")

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing-zaq-provision-test", result.stdout)
        self.assertFalse(self.destination.exists())

    def test_wrong_python_minor_fails_before_replacing_venv(self):
        self.write_lock("# Fixture lock.\n")
        self.destination.mkdir()
        marker = self.destination / "keep-me"
        marker.write_text("old", encoding="utf-8")

        with mock.patch.object(provision_python.sys, "version_info", (3, 12, 0)):
            with self.assertRaisesRegex(provision_python.ProvisionError, "CPython 3.13"):
                provision_python.provision(self.crawler, self.destination)

        self.assertEqual(marker.read_text(encoding="utf-8"), "old")


if __name__ == "__main__":
    unittest.main()
