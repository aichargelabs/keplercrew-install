"""The stable installer entry points must remain byte-identical."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# bump only on a deliberate stable installer change.
FROZEN_SHA256 = {
    "install.ps1": "cef15b4908894c6b5338cb93358984a592b1f692f11a49e61df799988a693e0b",
    "install.sh": "d087ff3c48a26c08a7d1c691c48a70f66f74de5d4c9fa19ed76d0a9846b0a2f8",
}


class StableFrozenTest(unittest.TestCase):
    def test_stable_installers_match_frozen_hashes(self):
        for name, expected in FROZEN_SHA256.items():
            with self.subTest(installer=name):
                actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
