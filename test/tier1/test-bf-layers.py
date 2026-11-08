#!/usr/bin/env python3
"""bf-layers.py (tools/phone/verify, games-120): the per-layer rate table bf-pacing.sh prints, on lines shaped like the
2026-11-05 19:33 Broforce run's (cover screen, kwin 3.66, xwayland-kgsl 24.1.13-11): Xwayland 1364 flips + 1361
commits / 30 s with 1211 frame callbacks and 150 timeouts, KWin ~40 drawn/s with commit -> drawn p90 ~104 ms, the
consumer's "pacing:" line, SurfaceFlinger actual presents at 40/s, and the cover panel at 60 Hz (render 0-60) - plus
a mode with nothing collected, which prints "?" per stage instead of failing.
"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.normpath(os.path.join(HERE, "..", "..", "tools", "phone", "verify", "bf-layers.py"))

KGSL = """Xwayland KGSL: last 30s: 1364 Present flips, 0 copies
Xwayland KGSL: last 30s: 1361 surface commits (1361 with damage): flip=1361/1361; frame callbacks 1211, frame timeouts 150; async flips paced 1360, skipped 0
"""
KWIN = "".join(
    f"kwin_backend_anland: window task 9 frames: last 5 s 225 commits, {d} drawn ({d / 5:.1f} fps); commit -> drawn "
    f"median 12 ms, p90 {p} ms, max 120 ms\n" for d, p in ((200, 102), (205, 106))
)
CONSUMER = ("11-05 19:34:01.000 I/Andromarchy( 1234): surface 9 pacing: last 5004 ms 201 queued (40.2/s), 5 bufs; "
            "free-buffer wait p50 0 p90 1 max 3 ms (0 dequeue timeouts), release-fence wait max 0 ms; producer wait "
            "p50 13 p90 104 max 118 ms\n")
DISPLAYS = """Display 4630946704981769859
    powerMode=Off
    activeMode={id=0, hwcId=0, resolution=2440x2268, vsyncRate=120.00 Hz, dpi=427.42x426.72, group=0}
    displayManagerPolicy={defaultModeId=0, allowGroupSwitching=false, primaryRanges={physical=[120.00 Hz, 120.00 Hz], render=[120.00 Hz, 120.00 Hz]}}
Display 4630946316123810436
    powerMode=On
    activeMode={id=1, hwcId=1, resolution=1116x2484, vsyncRate=60.00 Hz, dpi=436.10x432.15, group=0}
    displayManagerPolicy={defaultModeId=1, allowGroupSwitching=false, primaryRanges={physical=[0.00 Hz, 120.00 Hz], render=[0.00 Hz, 60.00 Hz]}}
"""


class BfLayers(unittest.TestCase):
    def run_tool(self, files):
        with tempfile.TemporaryDirectory() as out:
            md = os.path.join(out, "base")
            os.makedirs(md)
            for name, text in files.items():
                with open(os.path.join(md, name), "w") as f:
                    f.write(text)
            os.makedirs(os.path.join(out, "empty"))
            r = subprocess.run([sys.executable, "-I", TOOL, out, "base", "empty"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout.splitlines()

    def test_every_stage_of_the_1933_run(self):
        t0 = 59277758066865
        presents = "\n".join(str(t0 + i * 25_000_000) for i in range(41)) + "\n"  # 40 frames over 1 s
        base, empty = self.run_tool({"kgsl.txt": KGSL, "kwin.txt": KWIN, "consumer.txt": CONSUMER,
                                     "A1.txt": presents + presents, "A2.txt": "1\n2\n", "displays.txt": DISPLAYS,
                                     "prof.txt": "temp cpu-1-9 59.6\nskin 35.1 38.3\n"})
        self.assertIn("game 45.5 > xwayland 45.4 (cb 40.4, timeouts 5.0/s)", base)
        self.assertIn("> kwin 40.5 (commit->drawn p50 12 p90 104 ms)", base)
        self.assertIn("> consumer 40.2 (5 bufs, free-buffer wait p50 0 p90 1 ms, 0.0 timeouts/s, producer wait p50 13 ms)", base)
        self.assertIn("> sf 40.0 >", base)  # the layer with the most presents, overlapping polls deduped
        self.assertIn("panel 60 Hz (render 0-60)", base)  # the ON display, not the off inner one
        self.assertTrue(base.endswith("; skin 35.1->38.3 C"), base)
        self.assertEqual(empty, "layers empty: game ? > xwayland ? (cb ?, timeouts ?/s) > kwin ? (commit->drawn p50 ? "
                                "p90 ? ms) > consumer ? > sf ? > panel ? Hz (render ?) ; skin ? C")

    def test_a_stall_in_the_window_is_not_hidden_by_the_lines_before_it(self):
        # 11-08 02:02 (Broforce, web window over HomeShell): KWin's "Remote Control" prompt took the focus, the game
        # minimized itself, was restored, then presented nothing - Xwayland and KWin wrote no lines in the measured
        # window, and the last two 30 s lines from before the stall read as "game 37 > xwayland 38" while the consumer
        # got 0.5/s: the stall looked like the web window's. Lines after bf-pacing's mark only; none = 0.
        stall_kwin = KWIN + "window task == measuring\n" + KWIN.replace("225 commits, 200 drawn (40.0 fps)", "0 commits, 1 drawn (0.2 fps)").replace("225 commits, 205 drawn (41.0 fps)", "0 commits, 2 drawn (0.4 fps)")
        base, _ = self.run_tool({"kgsl.txt": KGSL + "Xwayland KGSL: == measuring\n", "kwin.txt": stall_kwin})
        self.assertIn("game 0.0 > xwayland 0.0 (cb 0.0, timeouts 0.0/s) > kwin 0.3 ", base)
        # The lines a running game writes inside the window still count.
        base, _ = self.run_tool({"kgsl.txt": "Xwayland KGSL: == measuring\n" + KGSL, "kwin.txt": "window task == measuring\n" + KWIN})
        self.assertIn("game 45.5 > xwayland 45.4 (cb 40.4, timeouts 5.0/s) > kwin 40.5 ", base)

    def test_colors_touch_idle_render_cap(self):
        # sf-latch-60 (11-06): `dumpsys SurfaceFlinger --oplus vrr` under a game with no touch for 2.5 s - the panel at
        # 120 Hz, SurfaceFlinger woken at 60 by ColorOS's touch idle (CVT oti-adfr); no cap (rate 0) says nothing.
        vrr = "OplusVSyncPredictor:\n  mCvtFps: 60 \n\nCVT:\n  Enable: true, Mute: false\n  CurrentRate: [60, oti-adfr]\n"
        base, _ = self.run_tool({"vrr.txt": vrr, "displays.txt": DISPLAYS})
        self.assertIn("panel 60 Hz (render 0-60, render cap 60 oti-adfr)", base)
        base, _ = self.run_tool({"vrr.txt": vrr.replace("[60, oti-adfr]", "[0, null]"), "displays.txt": DISPLAYS})
        self.assertIn("panel 60 Hz (render 0-60) ;", base)


if __name__ == "__main__":
    unittest.main()
