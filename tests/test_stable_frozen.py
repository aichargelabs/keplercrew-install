"""The stable installer entry points must remain byte-identical."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# bump only on a deliberate stable installer change. CI runs this file on every installer push.
# 2026-11-26: bumped for the self-update and live-run guards, then again for the
# guard fixes: the terminal stays open on a refusal, KEPLER_FORCE_RUNNING=1
# overrides the live-run check, and the check works without python3.
FROZEN_SHA256 = {
    "install.ps1": "84991b20968b6b34b126c327d7accf8e481f0b30197957290d6b03ddf444482d",
    "install.sh": "69d3c04693474bcf1fae23d8869582ed5fa93526c1509273f88d9afd9b15c3bd",
}


class StableFrozenTest(unittest.TestCase):
    def test_stable_installers_match_frozen_hashes(self):
        for name, expected in FROZEN_SHA256.items():
            with self.subTest(installer=name):
                actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
