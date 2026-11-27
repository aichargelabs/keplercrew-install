import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ["install.sh", "beta/install.sh", "uninstall.sh"]
PS1_SCRIPTS = ["install.ps1", "beta/install.ps1", "uninstall.ps1"]
# The shell fallback needs only these tools when python3 is missing.
FALLBACK_TOOLS = ["grep", "sed"]


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

    def test_missing_home_skips_live_run_lookup(self):
        env = {
            "PATH": os.environ["PATH"],
            "KEPLER_KEYGEN_BASE": "https://unsupported.invalid/v1",
            "KEPLER_INSTALL_DIR": "/tmp/kepler-missing-home-install",
        }
        for script in ("install.sh", "beta/install.sh"):
            with self.subTest(script=script):
                result = subprocess.run(["sh", str(ROOT / script)], env=env, text=True, capture_output=True, timeout=20)
                self.assertNotIn("parameter", result.stderr.lower(), result.stdout + result.stderr)
                self.assertIn("Unsupported licensing endpoint", result.stdout + result.stderr)

    def test_dead_or_missing_live_state_does_not_refuse(self):
        for script in SCRIPTS:
            missing = self.run_script(script)
            self.assertNotEqual(missing.returncode, 3, missing.stdout + missing.stderr)
            with tempfile.TemporaryDirectory() as home:
                self.add_record(home, 2147483647)
                env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install")}
                record = Path(home) / "state" / "live" / "cycle-123.json"
                old = time.time() - 90000
                os.utime(record, (old, old))
                dead = subprocess.run(["sh", str(ROOT / script)], env=env, text=True, capture_output=True, timeout=20)
                self.assertNotEqual(dead.returncode, 3, dead.stdout + dead.stderr)

    def test_live_record_older_than_24_hours_refuses(self):
        for script in SCRIPTS:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as home:
                self.add_record(home, os.getpid())
                record = Path(home) / "state" / "live" / "cycle-123.json"
                old = time.time() - 90000
                os.utime(record, (old, old))
                env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install")}
                result = subprocess.run(["sh", str(ROOT / script)], env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("guard test", result.stdout + result.stderr)

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

    def test_force_running_environment_goes_past_the_guard(self):
        for script in SCRIPTS:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as home:
                self.add_record(home, os.getpid())
                env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install"), "KEPLER_FORCE_RUNNING": "1"}
                result = subprocess.run(["sh", str(ROOT / script)], env=env, text=True, capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_force_running_environment_does_not_override_the_inside_run_guard(self):
        for script in SCRIPTS:
            result = self.run_script(script, KEPLER_INSIDE_RUN="1", KEPLER_FORCE_RUNNING="1")
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
            self.assertIn("This is running inside a Kepler task", result.stdout + result.stderr)

    def test_refusal_names_both_override_forms(self):
        for script in SCRIPTS:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as home:
                self.add_record(home, os.getpid())
                env = {**os.environ, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install")}
                result = subprocess.run(["sh", str(ROOT / script)], env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("--force", result.stdout + result.stderr)
                self.assertIn("KEPLER_FORCE_RUNNING=1", result.stdout + result.stderr)

    def test_busy_run_is_refused_without_python3(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as bindir:
            for tool in FALLBACK_TOOLS:
                found = shutil.which(tool)
                self.assertIsNotNone(found, tool)
                os.symlink(found, os.path.join(bindir, tool))
            kill = shutil.which("kill")
            if kill:
                os.symlink(kill, os.path.join(bindir, "kill"))
            self.add_record(home, os.getpid())
            live = Path(home) / "state" / "live"
            (live / "cycle-done.json").write_text(json.dumps({"apex_status": "completed", "pid": os.getpid(), "title": "finished run"}))
            env = {"PATH": bindir, "HOME": home, "APEX_HOME": home, "KEPLER_INSTALL_DIR": str(Path(home) / "missing-install")}
            result = subprocess.run(["/bin/sh", str(ROOT / "install.sh")], env=env, text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
            self.assertIn("guard test", result.stdout + result.stderr)
            self.assertNotIn("finished run", result.stdout + result.stderr)

    def test_powershell_guard_function_never_exits(self):
        for script in PS1_SCRIPTS:
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                start = text.index("function Test-KeplerInstallerGuard")
                body = text[start:text.index("\n}\n", start)]
                self.assertNotRegex(body, r"(?m)^\s*exit\b")

    def test_powershell_exits_only_in_file_mode(self):
        for script in PS1_SCRIPTS:
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                exit_lines = [line for line in text.splitlines()
                              if re.search(r"(?<![\w$])exit\b", line) and not line.strip().startswith("#")]
                self.assertTrue(exit_lines, script)
                for line in exit_lines:
                    self.assertIn("$PSCommandPath", line, f"{script}: exit outside the -File branch: {line}")

    def test_every_installer_names_the_environment_override(self):
        for script in SCRIPTS + PS1_SCRIPTS:
            with self.subTest(script=script):
                self.assertIn("KEPLER_FORCE_RUNNING", (ROOT / script).read_text())
