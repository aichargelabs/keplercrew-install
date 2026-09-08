"""Installer rejects unsupported licensing endpoints before downloads."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AuthorityTest(unittest.TestCase):
    def check_installer(self, command, nonzero=True):
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, KEPLER_KEYGEN_BASE="https://unsupported.invalid/v1", KEPLER_DRY_RUN="1", KEPLER_LICENSE_KEY="test-only", KEPLER_INSTALL_DIR=str(Path(d)/"install"))
            r = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            if nonzero:
                self.assertNotEqual(r.returncode, 0)
            self.assertIn("Unsupported licensing endpoint", r.stdout+r.stderr)
            self.assertFalse((Path(d)/"install").exists())

    @unittest.skipUnless(shutil.which("sh"), "POSIX shell unavailable")
    def test_posix(self):
        self.check_installer(["sh", str(ROOT/"install.sh")])

    @unittest.skipUnless(shutil.which("pwsh") or shutil.which("powershell"), "PowerShell unavailable")
    def test_windows(self):
        self.check_installer([shutil.which("pwsh") or shutil.which("powershell"), "-NoProfile", "-File", str(ROOT/"install.ps1")], nonzero=False)

if __name__ == "__main__":
    unittest.main()
