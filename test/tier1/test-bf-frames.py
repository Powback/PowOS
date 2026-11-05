#!/usr/bin/env python3
"""bf-pacing.sh's parser (tools/phone/verify/bf-frames.py) and layer pick (bf-present.sh), on the saved outputs of
the 2026-11-05 runs (fixtures/bf-frames/<mode>/: layers, window.txt, L<n>.txt deduped):
  - base (02:45) PASSed on "no presents": its 6 layers were leftover start-animation leashes + Bounds/Background
    containers, the game's BLAST SurfaceView was cut by head -6. Now: FAIL, exit 1 - no presents is never a PASS.
  - env:FEX_TSOENABLED=0 (02:48) / env:WINE_CPU_TOPOLOGY=4:0,1,2,7 (02:53): the BLAST layer's presents are the
    game's (~38 fps); a mode dir with ':' and ',' in its name no longer breaks the parse (int('') from ffprobe).
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


def run_main(modes):
    """bf-frames.py main() over the fixtures (no rec.mp4 there, so no docker): (rc, last line)."""
    out = subprocess.run([sys.executable, os.path.join(VER, "bf-frames.py"), FIX] + modes, capture_output=True,
                         text=True)
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
