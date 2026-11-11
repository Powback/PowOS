#!/usr/bin/env python3
"""A device command must not consume the remaining tasks in a cleanup loop."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ShellInput(unittest.TestCase):
    def test_command_preserves_loop_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            adb = pathlib.Path(tmp) / "adb"
            adb.write_text("#!/bin/bash\ncat >/dev/null\n")
            adb.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", '''source "$1/tools/phone/verify/e2e-lib.sh"
A=$2
while read -r task; do
  sh_ "am stack remove $task"
  echo "$task"
done <<EOF
101
102
103
EOF
''', "test", str(ROOT), str(adb)],
                text=True, capture_output=True, check=True,
            )
            self.assertEqual(result.stdout.splitlines(), ["101", "102", "103"])

    def test_tap_guards_pill_in_one_call(self):
        """tap() checks the verify pill on the phone in its input's own adb call: refused near it, made elsewhere."""
        with tempfile.TemporaryDirectory() as tmp:
            t = pathlib.Path(tmp)
            (t / "bin").mkdir()
            (t / "bin" / "dumpsys").write_text("#!/bin/sh\necho '  Window #3 Window{a u0 PowOS verify status}:'\n"
                                               "echo '    frame=[400,0][700,100] x'\n")
            (t / "bin" / "input").write_text("#!/bin/sh\necho \"INPUT $*\"\n")
            (t / "adb").write_text(f"#!/bin/bash\necho call >> {t}/calls\nPATH={t}/bin:$PATH sh -s\n")
            for f in ("bin/dumpsys", "bin/input", "adb"):
                (t / f).chmod(0o755)
            (t / "tw").write_text("5 0 0\n")
            result = subprocess.run(
                ["bash", "-c", '''source "$1/tools/phone/verify/e2e-lib.sh"
A=$2; OUT=$3; E2E_TW=$3/tw; RESTORED=0; CUR=x.png
fail() { echo "FAIL $*"; }
I0=5; tap 100 500 far; echo "rc=$?"; tap 550 120 near; echo "rc=$?"
''', "test", str(ROOT), str(t / "adb"), str(t)],
                text=True, capture_output=True, check=True,
            )
            out = result.stdout
            self.assertIn("INPUT tap 100 500", out)
            self.assertNotIn("INPUT tap 550 120", out)
            self.assertIn("FAIL not touched: near at 550,120 is under the verify status pill (400,0 700,100)", out)
            self.assertIn("rc=1", out)
            self.assertEqual((t / "calls").read_text().count("call"), 2)  # one adb call per tap


if __name__ == "__main__":
    unittest.main()
