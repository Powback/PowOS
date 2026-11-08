#!/usr/bin/env python3
"""bf-pacing.sh's parser (tools/phone/verify/bf-frames.py) and layer pick (bf-present.sh), on the saved outputs of
the 2026-11-05 runs (fixtures/bf-frames/<mode>/: layers, window.txt, L<n>.txt deduped):
  - base (02:45) PASSed on "no presents": its 6 layers were leftover start-animation leashes + Bounds/Background
    containers, the game's BLAST SurfaceView was cut by head -6. Now: FAIL, exit 1 - no presents is never a PASS.
  - env:FEX_TSOENABLED=0 (02:48) / env:WINE_CPU_TOPOLOGY=4:0,1,2,7 (02:53): the BLAST layer's presents are the
    game's (~38 fps); a mode dir with ':' and ',' in its name no longer breaks the parse (int('') from ffprobe).
  - play (11-08 02:02, fixtures/bf-frames-home/): PASSed "2.3 fps ... front HomeShell" while Xwayland showed the game
    presenting 37/s - its web window's frames never reached the screen. Now: FAIL "not the game on the screen".
    A window that never settled to full size, a front that isn't the game, and an fps under half this game's last
    PASSes (BF_APP + BF_HISTORY) FAIL too.
  - bf-present.sh, with a stub dumpsys listing the base run's layers + its BLAST layer, picks the BLAST layer first
    and none of the leashes / containers.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
VER = os.path.normpath(os.path.join(HERE, "..", "..", "tools", "phone", "verify"))
FIX = os.path.join(HERE, "fixtures", "bf-frames")
spec = importlib.util.spec_from_file_location("bf_frames", os.path.join(VER, "bf-frames.py"))
bf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bf)


HOME_FIX = os.path.join(HERE, "fixtures", "bf-frames-home")


def run_main(modes, fix=FIX, **env):
    """bf-frames.py main() over the fixtures (no rec.mp4 there, so no docker): (rc, last line)."""
    e = {k: v for k, v in os.environ.items() if k not in ("BF_APP", "BF_HISTORY", "BF_WINDOWED")}
    e.update(env)
    out = subprocess.run([sys.executable, os.path.join(VER, "bf-frames.py"), fix] + modes, capture_output=True,
                         text=True, env=e)
    return out.returncode, (out.stdout.strip().splitlines() or [""])[-1], out.stderr


class BfFramesTest(unittest.TestCase):
    def test_base_leashes_only_is_fail(self):
        self.assertIsNone(bf.presents(os.path.join(FIX, "base")))
        rc, last, err = run_main(["base"])
        self.assertEqual(rc, 1, err)
        self.assertTrue(last.startswith("FAIL no game presents in base"), last)

    def test_env_modes_measure_the_blast_layer(self):
        for m in ("env:FEX_TSOENABLED=0", "env:WINE_CPU_TOPOLOGY=4:0,1,2,7"):
            p = bf.presents(os.path.join(FIX, m))
            self.assertIsNotNone(p, m)
            self.assertIn("(BLAST)", p["layer"])
            self.assertTrue(30 < p["fps"] < 45, (m, p["fps"]))
            self.assertGreater(p["n"], 1000)
        rc, last, err = run_main(["env:FEX_TSOENABLED=0", "env:WINE_CPU_TOPOLOGY=4:0,1,2,7"])
        self.assertEqual(rc, 0, err)
        self.assertNotIn("FAIL", last)
        self.assertIn(" fps, frame ms p50", last)

    def test_one_mode_without_presents_fails_the_run(self):
        rc, last, _ = run_main(["env:FEX_TSOENABLED=0", "base"])
        self.assertEqual(rc, 1)
        self.assertTrue(last.startswith("FAIL no game presents in base"), last)

    def test_home_in_front_while_the_game_presents_is_fail(self):
        rc, last, err = run_main(["play"], HOME_FIX)
        self.assertEqual(rc, 1, err)
        self.assertTrue(last.startswith("FAIL not the game on the screen - play: the screen showed 2.3 fps of the "
                                        "game's 37.0"), last)

    def copy_mode(self, src, window=None):
        tmp = tempfile.mkdtemp(prefix="bf-truth-test-")
        self.addCleanup(shutil.rmtree, tmp)
        shutil.copytree(os.path.join(FIX, src), os.path.join(tmp, "m"))
        if window is not None:
            with open(os.path.join(tmp, "m", "window.txt"), "w") as f:
                f.write(window)
        return tmp

    def test_window_never_full_size_or_not_in_front_is_fail(self):
        d = self.copy_mode("env:FEX_TSOENABLED=0", "314x208 on 1116x2484\nsettled 314x208 on 1116x2484\n"
                                                    "front PowosWindowActivity\n")
        rc, last, _ = run_main(["m"], d)
        self.assertEqual(rc, 1)
        self.assertIn("never settled to full size (314x208 on 1116x2484)", last)
        self.assertEqual(run_main(["m"], d, BF_WINDOWED="1")[0], 0)
        d = self.copy_mode("env:FEX_TSOENABLED=0", "settled 1116x2484 on 1116x2484\nfront HomeShell\n")
        rc, last, _ = run_main(["m"], d)
        self.assertEqual(rc, 1)
        self.assertIn("the game isn't in front (front HomeShell", last)

    def test_fps_far_under_previous_runs_is_fail_and_a_pass_is_recorded(self):
        d = self.copy_mode("env:FEX_TSOENABLED=0")
        hist = os.path.join(d, "hist.tsv")
        rc, _, err = run_main(["m"], d, BF_APP="274190", BF_HISTORY=hist)
        self.assertEqual(rc, 0, err)
        self.assertRegex(open(hist).read(), r"^\d+\t274190\tm\t3\d\.\d\n$")
        with open(hist, "w") as f:
            f.write("".join("1\t274190\tm\t%d\n" % v for v in (110, 120, 116)))
        rc, last, _ = run_main(["m"], d, BF_APP="274190", BF_HISTORY=hist)
        self.assertEqual(rc, 1)
        self.assertIn("under half this game's previous runs (median 116.0 of 3)", last)
        self.assertEqual(run_main(["m"], d, BF_APP="384190", BF_HISTORY=hist)[0], 0)  # another game: its own history

    def test_percentile_matches_numpy_linear(self):
        v = [1.0, 2.0, 4.0, 8.0]
        self.assertAlmostEqual(bf.pct(v, 50), 3.0)
        self.assertAlmostEqual(bf.pct(v, 95), 7.4)
        self.assertEqual(bf.pct(v, 100), 8.0)

    def test_present_picks_blast_first(self):
        tmp = tempfile.mkdtemp(prefix="bf-present-test-")
        try:
            names = [l.rstrip("\n") for l in open(os.path.join(FIX, "base", "layers"))]
            names.insert(2, "ca81dbf SurfaceView[com.powos.app/andro.marchy.PowosWindowActivity](BLAST)#208")
            names.append("ActivityRecord{42 u0 com.powos.app/andro.marchy.PowosWindowActivity t9}#199")
            with open(os.path.join(tmp, "list"), "w") as f:
                f.write("".join("RequestedLayerState{%s parentId=1 z=0}\n" % n for n in names))
            stub = os.path.join(tmp, "dumpsys")
            with open(stub, "w") as f:
                f.write('#!/bin/sh\n[ "$2" = --list ] && cat "%s/list"\nexit 0\n' % tmp)
            os.chmod(stub, 0o755)
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"])
            rx = "PowosWindowActivity|SurfaceView|steam_app"
            subprocess.run(["sh", os.path.join(VER, "bf-present.sh"), "0", rx, os.path.join(tmp, "o"), "0"],
                           env=env, check=True, timeout=30)
            got = open(os.path.join(tmp, "o", "layers")).read().splitlines()
            self.assertTrue(got and "(BLAST)" in got[0], got)
            for g in got:
                self.assertNotRegex(g, r"animation-leash|^Bounds for|^Background for|ActivityRecord")
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
