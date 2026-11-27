"""The stable installer entry points must remain byte-identical."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# bump only on a deliberate stable installer change. CI runs this file on every installer push.
# 2026-11-26: bumped for the self-update and live-run guards, then again for the
# guard fixes: refusal override, cross-platform age and PID identity checks,
# then removal of the stale-live-record escape.
# 2026-11-27: skip live-run lookup when no data home is configured.
# Only the installer guard block changed in the stable scripts; release logic is frozen.
FROZEN_SHA256 = {
    "install.ps1": "7fb08b67af825c5b00c6fc0d686a5ecb200d42ae7fe2a6e2516438a60734aa13",
    "install.sh": "83ec02102186da8f275fcea927c64b3dcbc07e5ebcdb0c565d1306ee5e7c5d98",
}


class StableFrozenTest(unittest.TestCase):
    def test_stable_installers_match_frozen_hashes(self):
        for name, expected in FROZEN_SHA256.items():
            with self.subTest(installer=name):
                actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
