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


    def test_cold_launch_requires_a_measured_frame(self):
        source = (ROOT / "tools/phone/verify/bf-coldstart-phone.sh").read_text()
        start = source.index('    x=$(first_frame 90)')
        block = source[start:source.index('\n  elif', start)]
        # Exercise the actual launch verdict with a timeout, broken probe, stale frame and valid frame.
        for timestamp, valid in [("none", False), ("", False), ("garbage", False), ("99", False), ("101", True)]:
            with self.subTest(timestamp=timestamp):
                script = """first_frame() { printf '%s' "$STAMP"; }
ms() { echo $(( $2 - $1 )); }
fail() { echo failed; }
pill() { :; }
sleep() { :; }
t0=100; v=cold; seen=()
""" + block
                result = subprocess.run(["bash", "-c", 'STAMP=$1; ' + script, "test", timestamp], capture_output=True, text=True)
                self.assertEqual("failed" not in result.stdout, valid)

if __name__ == "__main__":
    unittest.main()
