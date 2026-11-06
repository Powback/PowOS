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


def sample(t, focus="PowosWindowActivity", resumed="PowosWindowActivity", cpu=130, procs="4/4", end_focus=None,
           shown="onscreen 1 task x"):
    return "\n".join([f"sample t={t}", f"start focus {focus}", f"start resumed {resumed}", f"start {shown}",
                      "top 130.0% wine64", f"gamecpu {cpu} procs={procs}", f"end focus {end_focus or focus}",
                      f"end resumed {resumed}", f"end {shown}", "skin 41090", "caps 1459200 1785600 1593600"])


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

    def test_unfolded_home_with_its_full_screen_web_window_passes(self):
        # 11-05 19:49-22:36: unfolded, the game is home's full-screen web window - HomeShell is rightly in front.
        web = dict(focus="HomeShell", resumed="HomeShell", shown="onscreen 1 web [BBQ]_powos-ww-42-linux#1")
        ok, line = bfq.verdict(soak(over={i: web for i in range(10)}), 600)
        self.assertTrue(ok, line)

    def test_home_without_a_game_layer_still_fails(self):
        # 11-05 21:38: the full-screen web window left on home's dead surface - nothing of the game composed.
        dead = dict(focus="HomeShell", resumed="HomeShell", shown="onscreen 0 none -")
        ok, line = bfq.verdict(soak(over={i: dead for i in range(10)}), 600)
        self.assertFalse(ok)
        self.assertIn("game layers 0 none", line)

    def test_a_web_layer_never_excuses_another_app_in_front(self):
        other = dict(focus="NotificationShade", resumed="HomeShell", shown="onscreen 1 web x")
        self.assertFalse(bfq.verdict(soak(over={2: other}), 600)[0])

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


def hwc(*layers):
    """A SurfaceFlinger dump's active HWC table: (name, l, t, r, b) per layer, plus an inactive display's stale one."""
    rows = ["Display 9 (inactive) HWC layers:", " SurfaceView[com.powos.app/andro.marchy.PowosWindowActivity](BLAST)#1",
            "   1 | 0 | 0 | DEVICE | 0 |    0    0 2440 2268 | 0 | [ ]", "Display 8 (active) HWC layers:", "-" * 20,
            " Layer name", "   Z | Window Type | Layer Class | Comp Type | Transform | Disp Frame (LTRB) | Crop | Rate", "-" * 20]
    for n, l, t, r, b in layers:
        rows += [f" {n}", f"   1 |  0 |  0 |  DEVICE |  0 | {l:4} {t:4} {r:4} {b:4} |  0.0 0.0 1.0 1.0 | [ ]", "-" * 20]
    return "\n".join(rows + ['Display 8 (physical, "")', "    powerMode=On"]) + "\n"


HOME = ("com.powos.app/andro.marchy.HomeShell#10430", 0, 0, 2440, 2268)


class OnScreen(unittest.TestCase):
    """bf-onscreen.sh: which screen-sized game layer SurfaceFlinger composes - a task's, home's web window's, or none."""

    def probe(self, dump):
        with tempfile.TemporaryDirectory() as d:
            fx = Path(d) / "sf.txt"; fx.write_text(dump)
            stub = Path(d) / "dumpsys"; stub.write_text(f"#!/bin/sh\ncat {fx}\n"); stub.chmod(0o755)
            return subprocess.run(["sh", str(V / "bf-onscreen.sh")], capture_output=True, text=True,
                                  env={**os.environ, "PATH": f"{d}:{os.environ['PATH']}"}).stdout.strip()

    def test_folded_task(self):
        out = self.probe(hwc(("540fc89 SurfaceView[com.powos.app/andro.marchy.PowosWindowActivity](BLAST)#9184", 0, 0, 1116, 2484),
                             ("com.powos.app/andro.marchy.PowosWindowActivity#9177", 0, 0, 1116, 2484)))
        self.assertTrue(out.startswith("onscreen 1 task 540fc89_SurfaceView"), out)

    def test_folded_task_direct_scanout(self):
        # debug.powos.direct_scanout=1: the client's buffer shows on the SurfaceView's child "powos-direct", the
        # SurfaceView's own layer drops out of the HWC list (11-06 job 110246: 4115/4118 frames direct, INVALID before).
        out = self.probe(hwc(("powos-direct#9190", 0, 0, 1116, 2484),
                             ("com.powos.app/andro.marchy.PowosWindowActivity#9177", 0, 0, 1116, 2484)))
        self.assertTrue(out.startswith("onscreen 1 task powos-direct"), out)

    def test_unfolded_full_screen_web_window(self):
        out = self.probe(hwc(("[BBQ] powos-ww-42-linux#10267", 0, 0, 2440, 2268), HOME))
        self.assertEqual(out, "onscreen 1 web [BBQ]_powos-ww-42-linux#10267")

    def test_windowed_steam_is_no_game_on_screen(self):
        self.assertEqual(self.probe(hwc(HOME, ("[BBQ] powos-ww-41-linux#1", 478, 497, 1613, 1862))), "onscreen 0 none -")

    def test_the_2138_dead_surface_home_only(self):
        # The full-screen layer hung on home's old surface: not in the active HWC list (the inactive one never counts).
        self.assertEqual(self.probe(hwc(("Wallpaper BBQ wrapper#73", 0, 0, 2440, 2268), HOME)), "onscreen 0 none -")

    def test_pacing_accepts_each_way_with_its_own_front(self):
        src = (V / "bf-pacing.sh").read_text()
        self.assertIn("bf-onscreen.sh", src)
        self.assertIn('[ "$how" = task ] && [ "$top" = PowosWindowActivity ]', src)
        self.assertIn('[ "$how" = web ] && [ "$top" = HomeShell ]', src)
        self.assertIn("powos-ww-[0-9]+-linux", src)
        self.assertIn("bf-onscreen.sh", (V / "bf-quiet.sh").read_text())


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

    def test_hwc_blur_lines_only_from_the_powered_display(self):
        # 11-05 04:19 and 08:02: the folded phone's OFF inner display kept 7 stale clientType=BLUR output layers (same
        # pointers 4 h apart) and read as "blur is back"; the active cover display had none, all 7 layers DEVICE.
        src = (V / "bf-quiet.sh").read_text()
        fn = re.search(r"^hwc\(\) \{.*?sort -u; \}$", src, re.S | re.M).group(0)
        dump = "\n".join([
            "Display 111 (inactive) HWC layers:", "Display 222 (active) HWC layers:",
            " game#1", "   0 | 0 | 0 | DEVICE | x",
            'Display 111 (physical, "")', "    powerMode=Off",
            "      forceClientComposition=true clientType=BLUR clearClientTarget=false stale",
            'Display 222 (physical, "")', "    powerMode=On",
            "      blend=NONE (1) alpha=1.000000 backgroundBlurRadius=0 composition type=DEVICE (2) ",
            "SurfaceFlinger global state:", "      clientType=BLUR after-the-blocks"])
        with tempfile.TemporaryDirectory() as d:
            adb = Path(d) / "adb"; fx = Path(d) / "sf.txt"; fx.write_text(dump + "\n")
            adb.write_text(f"#!/bin/sh\ncat {fx}\n"); adb.chmod(0o755)
            run = lambda: subprocess.run(["bash", "-c", fn + "\nhwc end"], capture_output=True, text=True,
                                         env={**os.environ, "A": str(adb), "OUT": d}).stdout
            out = run()
            self.assertIn("hwc DEVICE  game#1", out)
            self.assertNotIn("blur", out)
            fx.write_text(dump.replace("222 (physical", "000 (physical").replace("111 (physical", "222 (physical") + "\n")
            self.assertIn("clientType=BLUR clearClientTarget=false stale", run())

if __name__ == "__main__":
    unittest.main()
