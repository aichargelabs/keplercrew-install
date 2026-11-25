"""Beta installers cannot silently drift too far from their stable sources."""
import difflib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Ceilings track the measured behavioral diffs with a few lines of headroom.
PS1_CHANGED_LINE_CEILING = 190
SH_CHANGED_LINE_CEILING = 170


def changed_line_count(stable, beta):
    before = stable.read_text().splitlines()
    after = beta.read_text().splitlines()
    count = 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, before, after).get_opcodes():
        if tag != "equal":
            count += (i2 - i1) + (j2 - j1)
    return count


class BetaParityTest(unittest.TestCase):
    def assert_bounded_diff(self, stable_name, beta_name, ceiling):
        count = changed_line_count(ROOT / stable_name, ROOT / beta_name)
        print(f"{beta_name}: {count} changed lines (ceiling {ceiling})")
        self.assertLessEqual(count, ceiling)

    def test_powershell_beta_diff_is_bounded(self):
        self.assert_bounded_diff("install.ps1", "beta/install.ps1", PS1_CHANGED_LINE_CEILING)

    def test_posix_beta_diff_is_bounded(self):
        self.assert_bounded_diff("install.sh", "beta/install.sh", SH_CHANGED_LINE_CEILING)


if __name__ == "__main__":
    unittest.main()
