"""The stable installer entry points must remain byte-identical."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# bump only on a deliberate stable installer change. CI runs this file on every installer push.
FROZEN_SHA256 = {
    "install.ps1": "2c8996460795fb769f4c0f7707bcfb8e1416617a657cbfc8e3ba4569682a1c38",
    "install.sh": "33ecc59b9ee3a5a53d53ddeffd2e951d13f1efa9c292d14a934d53031e65a077",
}


class StableFrozenTest(unittest.TestCase):
    def test_stable_installers_match_frozen_hashes(self):
        for name, expected in FROZEN_SHA256.items():
            with self.subTest(installer=name):
                actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
