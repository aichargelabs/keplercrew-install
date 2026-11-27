"""The stable installer entry points must remain byte-identical."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# bump only on a deliberate stable installer change. CI runs this file on every installer push.
# 2026-11-26: bumped for the self-update and live-run guards, then again for the
# guard fixes: refusal override, cross-platform age and PID identity checks,
# then removal of the stale-live-record escape.
# Only the installer guard block changed in the stable scripts; release logic is frozen.
FROZEN_SHA256 = {
    "install.ps1": "6038043e6b1b9907188b119bf658cb88a5821de522ea679a98042509f01108db",
    "install.sh": "947963dd9c5042074b18091e2691740b2c6e0a873c3684991434cd5993f7ca8f",
}


class StableFrozenTest(unittest.TestCase):
    def test_stable_installers_match_frozen_hashes(self):
        for name, expected in FROZEN_SHA256.items():
            with self.subTest(installer=name):
                actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
