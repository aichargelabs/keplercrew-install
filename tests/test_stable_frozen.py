"""The stable installer entry points must remain byte-identical."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# bump only on a deliberate stable installer change. CI runs this file on every installer push.
# 2026-11-26: bumped for the self-update and live-run guards.
FROZEN_SHA256 = {
    "install.ps1": "0b4b2636672b0c2cce0706b4a5a727e71501ce9e08cf9e5e69c6d5a6976d537e",
    "install.sh": "5dc231111380b12d81b0d61a14025a3f73a2cb67b51ba0b98146c74d21232ea2",
}


class StableFrozenTest(unittest.TestCase):
    def test_stable_installers_match_frozen_hashes(self):
        for name, expected in FROZEN_SHA256.items():
            with self.subTest(installer=name):
                actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
