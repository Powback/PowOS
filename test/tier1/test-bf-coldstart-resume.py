#!/usr/bin/env python3
"""bf-coldstart.sh `resume`: the resume measurement (bf-return.sh) for the game's APP - alone with no cold variants
first, after them otherwise - and bf-return-phone.sh's resume goal is 2 s (tap -> first new frame of a frozen game)."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "tools/phone/verify"


class ColdstartResume(unittest.TestCase):
    def run_alone(self, *args):
        with tempfile.TemporaryDirectory() as d:
            v = Path(d) / "verify"
            v.mkdir()
            shutil.copy(VERIFY / "bf-coldstart.sh", v)
            # adb.sh would reach the phone: a resume-alone run must never get there.
            (Path(d) / "adb.sh").write_text("#!/bin/bash\necho ADB-CALLED \"$@\"\nexit 9\n")
            (v / "bf-return.sh").write_text('#!/bin/bash\necho "bf-return APP=${APP:-} args=$*"\nexit 0\n')
            for f in (Path(d) / "adb.sh", v / "bf-return.sh"):
                f.chmod(0o755)
            env = dict(os.environ, OUT=str(Path(d) / "out"))
            env.pop("APP", None)
            return subprocess.run(["bash", str(v / "bf-coldstart.sh"), *args], capture_output=True, text=True,
                                  env=env, timeout=30)

    def test_resume_alone_runs_bf_return_only(self):
        r = self.run_alone("resume")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("bf-return APP= args=", r.stdout)
        self.assertNotIn("ADB-CALLED", r.stdout)

    def test_resume_keeps_the_app(self):
        r = self.run_alone("app:1167630", "resume")
        self.assertIn("bf-return APP=1167630", r.stdout)
        self.assertNotIn("ADB-CALLED", r.stdout)

    def test_resume_after_other_variants(self):
        src = (VERIFY / "bf-coldstart.sh").read_text()
        tail = src[src.index('grep "^RESULT" "$OUT/run.txt" | tail -1'):]
        self.assertIn('"$here/bf-return.sh"', tail, "resume with variants runs bf-return after them")

    def test_resume_goal_is_two_seconds(self):
        src = (VERIFY / "bf-return-phone.sh").read_text()
        self.assertIn("GOAL_MS=${GOAL_MS:-2000}", src)

    def test_checks_pushing_bf_lib_push_its_frame_helper(self):
        # bf-lib's xframes runs /var/tmp/powos-bf-xframes.py (split out 10-24): a check that pushes bf-lib.sh without
        # it measures every frame as "none" (bf-return/bf-resume until 11-05: resume never measured).
        import re
        for f in sorted(VERIFY.glob("bf-*.sh")):  # the game checks (they measure frames)
            for m in re.finditer(r"for f in ([^;]*); do \"\$A\" push", f.read_text()):
                if "bf-lib.sh" in m.group(1).split():
                    with self.subTest(check=f.name):
                        self.assertIn("bf-xframes.py", m.group(1).split())


if __name__ == "__main__":
    unittest.main()
