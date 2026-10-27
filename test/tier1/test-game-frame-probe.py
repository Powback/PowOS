#!/usr/bin/env python3
"""A broken frame probe must report no frame, never an empty successful timestamp."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FUNCTION = next(line for line in (ROOT / "tools/phone/verify/bf-lib.sh").read_text().splitlines()
                if line.startswith("xframes()"))


class FrameProbe(unittest.TestCase):
    def probe(self, helper=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            if helper is not None:
                (root / "powos-bf-xframes.py").write_text(helper)
            script = root / "probe.sh"
            script.write_text(FUNCTION + '\nBF_XFRAMES="$(dirname "$0")/powos-bf-xframes.py" xframes change 123 5 30\n')
            return subprocess.run(["bash", str(script)], capture_output=True, text=True).stdout.strip()

    def test_missing_helper_is_no_frame(self):
        self.assertEqual(self.probe(), "none")

    def test_crashed_helper_is_no_frame(self):
        self.assertEqual(self.probe("raise RuntimeError('display unavailable')"), "none")

    def test_frame_timestamp_survives(self):
        self.assertEqual(self.probe("print('1793133042.100')"), "1793133042.100")


if __name__ == "__main__":
    unittest.main()
