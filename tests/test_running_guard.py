import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ["install.sh", "beta/install.sh", "uninstall.sh"]


class RunningGuardTest(unittest.TestCase):
    def run_script(self, script, **extra):
        with tempfile.TemporaryDirectory() as home:
            env = os.environ.copy()
            env.update({"APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install"), **extra})
            return subprocess.run(["sh", str(ROOT / script), "--force"], env=env, text=True, capture_output=True, timeout=20)

    def add_record(self, home, pid, status="running"):
        live = Path(home) / "state" / "live"
        live.mkdir(parents=True)
        (live / "cycle-123.json").write_text(json.dumps({"apex_status": status, "pid": pid, "title": "guard test"}))

    def test_busy_live_record_refuses_without_force(self):
        for script in SCRIPTS:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as home:
                self.add_record(home, os.getpid())
                env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install")}
                result = subprocess.run(["sh", str(ROOT / script)], env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("guard test", result.stdout + result.stderr)
                self.assertNotIn("Stopping the running KeplerCrew", result.stdout + result.stderr)
                self.assertFalse((Path(home) / "missing-install").exists())

    def test_inside_run_refuses_even_with_force(self):
        for script in SCRIPTS:
            result = self.run_script(script, KEPLER_INSIDE_RUN="1")
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
            self.assertIn("This is running inside a Kepler task", result.stdout + result.stderr)
            self.assertNotIn("Stopping the running KeplerCrew", result.stdout + result.stderr)

    def test_dead_or_missing_live_state_does_not_refuse(self):
        for script in SCRIPTS:
            missing = self.run_script(script)
            self.assertNotEqual(missing.returncode, 3, missing.stdout + missing.stderr)
            with tempfile.TemporaryDirectory() as home:
                self.add_record(home, 2147483647)
                env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install")}
                dead = subprocess.run(["sh", str(ROOT / script)], env=env, text=True, capture_output=True, timeout=20)
                self.assertNotEqual(dead.returncode, 3, dead.stdout + dead.stderr)

    def test_reinstall_environment_flag_does_not_override_live_guard(self):
        with tempfile.TemporaryDirectory() as home:
            self.add_record(home, os.getpid())
            env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install"), "KEPLER_FORCE": "1"}
            result = subprocess.run(["sh", str(ROOT / "install.sh")], env=env, text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_force_allows_busy_record(self):
        with tempfile.TemporaryDirectory() as home:
            self.add_record(home, os.getpid())
            env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install")}
            result = subprocess.run(["sh", str(ROOT / "install.sh"), "--force"], env=env, text=True, capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 3, result.stdout + result.stderr)
