#!/usr/bin/env python3
"""bf-quiet.sh's soak pass criteria: the game's window in front and its processes using CPU for the whole soak.

The 2026-11-05 03:02 soak printed "PASS game ran 600 s" with home (HomeShell) focused, no FEX/wine process and the
game never started: `adb shell "pgrep -f Broforce_beta.exe"` matched its own sh -c. These fixtures keep that a FAIL.
"""
from pathlib import Path
import importlib.util
import os
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
V = ROOT / "tools/phone/verify"
spec = importlib.util.spec_from_file_location("bfq", V / "bf-quiet-verdict.py")
bfq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bfq)


def sample(t, focus="PowosWindowActivity", resumed="PowosWindowActivity", cpu=130, procs="4/4", end_focus=None):
    return "\n".join([f"sample t={t}", f"start focus {focus}", f"start resumed {resumed}", "top 130.0% wine64",
                      f"gamecpu {cpu} procs={procs}", f"end focus {end_focus or focus}", f"end resumed {resumed}",
                      "skin 41090", "caps 1459200 1785600 1593600"])


def soak(n=10, over=None):
    return "\n".join(sample(i * 61, **(over or {}).get(i, {})) for i in range(n))


class Verdict(unittest.TestCase):
    def test_full_soak_in_front_passes(self):
        ok, line = bfq.verdict(soak(), 600)
        self.assertTrue(ok, line)
        self.assertTrue(line.startswith("PASS"))

    def test_the_0302_soak_home_in_front_no_game_fails(self):
        text = soak(over={i: dict(focus="HomeShell", resumed="HomeShell", cpu=0, procs="0/0") for i in range(10)})
        ok, line = bfq.verdict(text, 600)
        self.assertFalse(ok)
        self.assertIn("not in front", line)

    def test_no_game_process_fails_even_in_front(self):
        ok, line = bfq.verdict(soak(over={3: dict(cpu=0, procs="0/0")}), 600)
        self.assertFalse(ok)
        self.assertIn("no game process", line)

    def test_idle_game_process_fails(self):
        ok, line = bfq.verdict(soak(over={5: dict(cpu=3)}), 600)
        self.assertFalse(ok)
        self.assertIn("game CPU 3%", line)

    def test_focus_lost_during_a_sample_fails(self):
        ok, line = bfq.verdict(soak(over={7: dict(end_focus="NotificationShade")}), 600)
        self.assertFalse(ok)
        self.assertIn("end focus = NotificationShade", line)

    def test_short_soak_fails(self):
        ok, line = bfq.verdict(soak(n=3), 600)
        self.assertFalse(ok)
        self.assertIn("covered", line)

    def test_no_samples_fails(self):
        self.assertFalse(bfq.verdict("", 600)[0])

    def test_incomplete_sample_fails(self):
        self.assertFalse(bfq.verdict("sample t=0\ngamecpu 120 procs=3/3", 0)[0])


class PhoneSample(unittest.TestCase):
    """bf-quiet-phone.sh's front(): the activity / window name out of real dumpsys lines."""

    def front(self, focus_line, resumed_line):
        src = (V / "bf-quiet-phone.sh").read_text()
        fn = next(l for l in src.splitlines() if l.startswith("front()"))
        fn += "\n" + next(l for l in src.splitlines() if l.lstrip().startswith('echo "resumed'))
        with tempfile.TemporaryDirectory() as d:
            stub = Path(d) / "dumpsys"
            stub.write_text(f"#!/bin/sh\n[ \"$1\" = window ] && echo '{focus_line}'\n[ \"$1\" = activity ] && echo '{resumed_line}'\nexit 0\n")
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            r = subprocess.run(["sh", "-c", fn + "\nfront"], capture_output=True, text=True,
                               env={**os.environ, "PATH": f"{d}:{os.environ['PATH']}"})
            return r.stdout.split("\n")[:2]

    def test_game_task(self):
        self.assertEqual(self.front("  mCurrentFocus=Window{974d492 u0 com.powos.app/andro.marchy.PowosWindowActivity}",
                                    "  topResumedActivity=ActivityRecord{1 u0 com.powos.app/andro.marchy.PowosWindowActivity t9}"),
                         ["focus PowosWindowActivity", "resumed PowosWindowActivity"])

    def test_home(self):
        self.assertEqual(self.front("  mCurrentFocus=Window{974d492 u0 com.powos.app/andro.marchy.HomeShell}",
                                    "  topResumedActivity=ActivityRecord{1 u0 com.powos.app/andro.marchy.HomeShell t2}"),
                         ["focus HomeShell", "resumed HomeShell"])

    def test_window_without_activity(self):
        self.assertEqual(self.front("  mCurrentFocus=Window{332df39 u0 NotificationShade}", "")[0], "focus NotificationShade")


class Scripts(unittest.TestCase):
    def test_no_self_matching_game_pgrep_over_adb(self):
        # A plain pattern inside `adb shell "..."` is also in that shell's own command line: always "found".
        for f in V.glob("*.sh"):
            for n, line in enumerate(f.read_text().splitlines(), 1):
                if '" shell "' in line or "' shell '" in line:
                    self.assertIsNone(re.search(r"pgrep -f ['\"]?Broforce_beta\.exe", line), f"{f.name}:{n}")

    def test_bf_quiet_reads_the_real_session_log_and_starts_the_game(self):
        src = (V / "bf-quiet.sh").read_text()
        self.assertIn("LOG=/data/powos/root/run/powos-app/hyprland.log", src)
        self.assertIn("asuser bf-start.sh", src)
        self.assertIn("bf-quiet-verdict.py", src.splitlines()[-1])


if __name__ == "__main__":
    unittest.main()
