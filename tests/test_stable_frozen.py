"""The stable installer entry points must remain byte-identical."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# bump only on a deliberate stable installer change. CI runs this file on every installer push.
# 2026-11-26: bumped for the self-update and live-run guards, then again for the
# guard fixes: refusal override, cross-platform age and PID identity checks.
# Only the installer guard block changed in the stable scripts; release logic is frozen.
FROZEN_SHA256 = {
    "install.ps1": "0f001ab309469be4b753c53bd9c1544253f51f33e453188d447cbc82085bff1e",
    "install.sh": "70adc8534733ee60d86c5f6ea367578575e1ff08407b855fda5a0d1ae4f58509",
}


class StableFrozenTest(unittest.TestCase):
    def test_stable_installers_match_frozen_hashes(self):
        for name, expected in FROZEN_SHA256.items():
            with self.subTest(installer=name):
                actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
