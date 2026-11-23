"""The POSIX installer selects the newest release carrying this platform's bundle."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]

FAKE_CURL = r'''
import sys
args = sys.argv[1:]
sys.stdin.read()
def value(flag):
    return args[args.index(flag) + 1] if flag in args else None
url = next((a for a in args if a.startswith("http")), "")
out = value("-o")
headers = value("-D")
if "validate-key" in url:
    print('{"meta":{"valid":true}}')
elif "/releases?" in url:
    data = {"data": [
        {"id": "rid13", "attributes": {"version": "8.6.13", "status": "PUBLISHED", "channel": "stable"}},
        {"id": "rid11", "attributes": {"version": "8.6.11", "status": "PUBLISHED", "channel": "stable"}},
    ]}
    open(out, "w").write(__import__("json").dumps(data))
    print("200", end="")
elif "/artifacts/" in url:
    if "rid13" in url:
        open(headers, "w").write("HTTP/1.1 404 Not Found\r\n\r\n")
        open(out, "w").write("{}")
    else:
        open(headers, "w").write("HTTP/1.1 303 See Other\r\nLocation: https://example.invalid/bundle\r\n\r\n")
        open(out, "w").write('{"checksum":"abc123"}')
else:
    raise SystemExit(f"unexpected URL: {url}")
'''

FAKE_UNAME = """#!/bin/sh
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
  *) echo Darwin ;;
esac
"""


class PlatformFallbackTest(unittest.TestCase):
    def run_installer(self, extra_env):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            fakebin = root / "bin"
            fakebin.mkdir()
            curl = fakebin / "curl"
            curl.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(FAKE_CURL))
            curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
            uname = fakebin / "uname"
            uname.write_text(FAKE_UNAME)
            uname.chmod(uname.stat().st_mode | stat.S_IEXEC)
            env = dict(
                os.environ,
                PATH=f"{fakebin}:{os.environ['PATH']}",
                KEPLER_LICENSE_KEY="test-only",
                KEPLER_DRY_RUN="1",
                KEPLER_INSTALL_DIR=str(root / "install"),
            )
            env.update(extra_env)
            result = subprocess.run(
                ["sh", str(ROOT / "install.sh")],
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertFalse((root / "install").exists())
            return result

    def test_unpinned_falls_back_to_latest_darwin_bundle(self):
        result = self.run_installer({})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("using latest available for darwin/arm64: 8.6.11", result.stdout)
        self.assertIn("Version:   8.6.11", result.stdout)
        self.assertIn("KeplerCrew-darwin-arm64-8.6.11.tar.gz", result.stdout)

    def test_pinned_release_without_bundle_does_not_fall_back(self):
        result = self.run_installer({"KEPLER_VERSION": "8.6.13"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Release 8.6.13 has no darwin/arm64 bundle yet.", result.stdout)
        self.assertNotIn("Version:", result.stdout)


if __name__ == "__main__":
    unittest.main()
