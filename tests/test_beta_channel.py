"""The beta installer orders stable and prerelease versions correctly."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]

FAKE_CURL = r'''
import json
import os
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
    releases = json.loads(os.environ["FAKE_RELEASES"])
    open(out, "w").write(json.dumps({"data": releases}, separators=(",", ":")))
    print("200", end="")
elif "/artifacts/" in url:
    release_id = url.split("/releases/", 1)[1].split("/", 1)[0]
    bundles = json.loads(os.environ["FAKE_BUNDLES"])
    if release_id in bundles:
        open(headers, "w").write("HTTP/1.1 303 See Other\r\nLocation: https://example.invalid/bundle\r\n\r\n")
        open(out, "w").write('{"checksum":"abc123"}')
    else:
        open(headers, "w").write("HTTP/1.1 404 Not Found\r\n\r\n")
        open(out, "w").write("{}")
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


def release(version, channel):
    return {
        "id": "rid-" + version.replace(".", "-"),
        "attributes": {
            "version": version,
            "status": "PUBLISHED",
            "channel": channel,
        },
    }


MIXED = [
    release("8.6.14-beta.1", "beta"),
    release("8.6.13", "stable"),
    release("8.6.14-beta.2", "beta"),
]

STABLE_AND_BETA = [
    release("8.6.13", "stable"),
    release("8.6.14-beta.2", "beta"),
]


class BetaChannelTest(unittest.TestCase):
    def run_installer(
        self,
        releases,
        script="beta/install.sh",
        bundles=None,
        extra_env=None,
        force_shell=False,
        installed=None,
        dry_run=True,
    ):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            fakebin = root / "bin"
            fakebin.mkdir()
            curl = fakebin / "curl"
            curl.write_text(f"#!{sys.executable}\n" + textwrap.dedent(FAKE_CURL))
            curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
            uname = fakebin / "uname"
            uname.write_text(FAKE_UNAME)
            uname.chmod(uname.stat().st_mode | stat.S_IEXEC)
            if force_shell:
                python = fakebin / "python3"
                python.write_text("#!/bin/sh\nexit 1\n")
                python.chmod(python.stat().st_mode | stat.S_IEXEC)

            install_dir = root / "install"
            if installed is not None:
                install_dir.mkdir()
                (install_dir / "version.txt").write_text(installed)
            env = dict(os.environ)
            for name in ("KEPLER_VERSION", "KEPLER_FORCE", "KEPLER_CHANNEL", "XDG_DATA_HOME"):
                env.pop(name, None)
            env.update(
                PATH=f"{fakebin}:{os.environ['PATH']}",
                KEPLER_LICENSE_KEY="test-only",
                KEPLER_DRY_RUN="1" if dry_run else "0",
                KEPLER_INSTALL_DIR=str(install_dir),
                FAKE_RELEASES=json.dumps(releases),
                FAKE_BUNDLES=json.dumps(
                    bundles if bundles is not None else [item["id"] for item in releases]
                ),
            )
            if extra_env:
                env.update(extra_env)
            result = subprocess.run(
                ["sh", str(ROOT / script)],
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=20,
            )
            channel_file = install_dir / "channel.txt"
            result.channel_text = channel_file.read_text() if channel_file.exists() else None
            if dry_run:
                if installed is None:
                    self.assertFalse(install_dir.exists())
                self.assertIsNone(result.channel_text)
            return result

    def assert_version(self, result, version):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Version:   {version}", result.stdout)
        self.assertIn(f"KeplerCrew-darwin-arm64-{version}.tar.gz", result.stdout)

    def test_mixed_list_picks_newest_beta(self):
        result = self.run_installer(MIXED)
        self.assert_version(result, "8.6.14-beta.2")
        self.assertTrue(result.stdout.startswith("KeplerCrew installer (beta channel)\n"))
        self.assertIn("Channel:   beta", result.stdout)

    def test_beta_numbers_sort_as_integers(self):
        releases = [release("8.6.14-beta.9", "beta"), release("8.6.14-beta.10", "beta")]
        self.assert_version(self.run_installer(releases), "8.6.14-beta.10")

    def test_ga_supersedes_its_betas(self):
        releases = [release("8.6.14-beta.3", "beta"), release("8.6.14", "stable")]
        result = self.run_installer(releases, installed="8.6.14-beta.3")
        self.assert_version(result, "8.6.14")

    def test_newest_beta_without_bundle_falls_back(self):
        bundles = [MIXED[0]["id"], MIXED[1]["id"]]
        result = self.run_installer(MIXED, bundles=bundles)
        self.assert_version(result, "8.6.14-beta.1")
        self.assertIn("using latest available for darwin/arm64: 8.6.14-beta.1", result.stdout)

    def test_pinned_release_without_bundle_is_an_error(self):
        bundles = [MIXED[0]["id"], MIXED[1]["id"]]
        result = self.run_installer(
            MIXED,
            bundles=bundles,
            extra_env={"KEPLER_VERSION": "8.6.14-beta.2"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "KeplerCrew 8.6.14-beta.2 has no build for darwin/arm64 yet.",
            result.stderr,
        )
        self.assertNotIn("Version:", result.stdout)

    def test_up_to_date_beta_install_persists_channel(self):
        result = self.run_installer(
            [release("8.6.13", "stable")],
            installed="8.6.13",
            dry_run=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.channel_text, "beta")
        self.assertIn("Channel set to beta.", result.stdout)

    def test_up_to_date_stable_install_persists_channel(self):
        result = self.run_installer(
            [release("8.6.13", "stable")],
            installed="8.6.13",
            dry_run=False,
            extra_env={"KEPLER_CHANNEL": "stable"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.channel_text, "stable")
        self.assertIn("Channel set to stable.", result.stdout)

    def test_up_to_date_dry_run_reports_channel_without_writing(self):
        result = self.run_installer(
            [release("8.6.13", "stable")],
            installed="8.6.13",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(result.channel_text)
        self.assertIn("Channel:   beta", result.stdout)
        self.assertNotIn("Channel set to beta.", result.stdout)
        self.assertNotIn("Reinstalling", result.stdout)

    def test_stable_installer_still_ignores_beta(self):
        self.assert_version(self.run_installer(MIXED, script="install.sh"), "8.6.13")

    def test_shell_fallback_uses_the_same_ordering(self):
        releases = [release("8.6.14-beta.9", "beta"), release("8.6.14-beta.10", "beta")]
        self.assert_version(self.run_installer(releases, force_shell=True), "8.6.14-beta.10")

    def test_tagged_version_pin(self):
        result = self.run_installer(MIXED, extra_env={"KEPLER_VERSION": "v8.6.14-beta.1"})
        self.assert_version(result, "8.6.14-beta.1")

    def test_prerelease_downgrade_is_refused(self):
        releases = [release("8.6.14-beta.9", "beta")]
        result = self.run_installer(releases, installed="8.6.14-beta.10")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("downgrade refused", result.stderr)

    def test_stable_channel_excludes_beta_releases(self):
        result = self.run_installer(STABLE_AND_BETA, extra_env={"KEPLER_CHANNEL": "stable"})
        self.assert_version(result, "8.6.13")
        self.assertIn("Channel:   stable", result.stdout)

    def test_stable_channel_requires_force_to_leave_newer_beta(self):
        result = self.run_installer(
            STABLE_AND_BETA,
            installed="8.6.14-beta.2",
            extra_env={"KEPLER_CHANNEL": "stable"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("downgrade refused", result.stderr)

    def test_stable_channel_with_force_leaves_newer_beta(self):
        result = self.run_installer(
            STABLE_AND_BETA,
            installed="8.6.14-beta.2",
            extra_env={"KEPLER_CHANNEL": "stable", "KEPLER_FORCE": "1"},
        )
        self.assert_version(result, "8.6.13")
        self.assertIn("Downgrade allowed by KEPLER_FORCE=1.", result.stdout)

    def test_invalid_channel_is_rejected(self):
        result = self.run_installer(MIXED, extra_env={"KEPLER_CHANNEL": "preview"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('KEPLER_CHANNEL must be "beta" or "stable"', result.stderr)

    def test_shell_fallback_honors_stable_channel(self):
        result = self.run_installer(
            STABLE_AND_BETA,
            extra_env={"KEPLER_CHANNEL": "stable"},
            force_shell=True,
        )
        self.assert_version(result, "8.6.13")

    def test_unparseable_installed_version_skips_downgrade_guard(self):
        result = self.run_installer(
            STABLE_AND_BETA,
            installed="garbage",
            extra_env={"KEPLER_CHANNEL": "stable"},
        )
        self.assert_version(result, "8.6.13")
        self.assertIn("could not be read", result.stdout)
        self.assertNotIn("downgrade refused", result.stderr)
        self.assertNotIn("integer expression expected", result.stderr)

    def test_stable_channel_hides_way_back_hint(self):
        result = self.run_installer(MIXED, extra_env={"KEPLER_CHANNEL": "stable"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("To return to stable", result.stdout)

    def test_powershell_way_back_command_is_exactly_quoted(self):
        text = (ROOT / "beta/install.ps1").read_text()
        command = (
            'powershell -NoProfile -ExecutionPolicy Bypass -Command "'
            "$env:KEPLER_CHANNEL='stable'; $env:KEPLER_FORCE=1; "
            'iex (irm https://get.keplercrew.com/beta/install.ps1)"'
        )
        source_line = "Write-Host '" + command.replace("'", "''") + "'"
        self.assertEqual(text.count(source_line), 1)
        self.assertNotIn("$env:KEPLER_CHANNEL=stable;", text)


if __name__ == "__main__":
    unittest.main()
