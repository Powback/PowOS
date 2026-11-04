#!/usr/bin/env python3
"""
Tests for targets/android/pkgs/steam/sitecustomize.py + user_settings.py: the install script evaluator skip before
the Steam Runtime container (in Valve's FEX compat tool's own Python, via steam-env's PYTHONPATH).

Covers:
- the evaluator's chain (fex-compat-tool run -- _v2-entry-point --verb=run -- proton run iscriptevaluator.exe ...)
  with input as at its last good run: exits 0 at once, logs "skipped before the container"
- input changed (script bytes) / no record / user's own user_settings.py: falls through (the chain runs as before)
- the game's own launch (waitforexitandrun) and any other Python: untouched
- Proton's own import (module name user_settings) still skips + records as before; loading it under another name
  (what sitecustomize does) runs nothing
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG = REPO / "targets/android/pkgs/steam"


class IscriptSkip(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.steam = self.t / "Steam"
        self.proton = self.steam / "steamapps/common/Proton - Experimental"
        self.data = self.steam / "steamapps/compatdata/274190"
        self.fex = self.steam / "steamapps/common/FEX-Emu"
        for d in (self.proton, self.data / "pfx", self.fex, self.steam / "legacycompat"):
            d.mkdir(parents=True)
        (self.data / "pfx/creation_sync_guard").touch()
        (self.proton / "version").write_text("1793301796 experimental-11.0\n")
        shutil.copy(PKG / "user_settings.py", self.proton / "user_settings.py")
        (self.steam / "legacycompat/iscriptevaluator.exe").write_text("exe")
        self.script = self.steam / "legacycompat/evaluatorscript_274190.vdf"
        self.script.write_text('"evaluatorscript" {}')
        self.py = self.t / "py"
        self.py.mkdir()
        shutil.copy(PKG / "sitecustomize.py", self.py / "sitecustomize.py")
        # A stand-in for Valve's fex-compat-tool: reaching its body = the container chain would have started.
        self.tool = self.fex / "fex-compat-tool"
        self.tool.write_text("import sys\nprint('CHAIN STARTED')\nsys.exit(7)\n")
        self.env = dict(os.environ, PYTHONPATH=str(self.py), STEAM_COMPAT_DATA_PATH=str(self.data),
                        STEAM_COMPAT_CLIENT_INSTALL_PATH=str(self.steam), HOME=str(self.t))

    def tearDown(self):
        shutil.rmtree(self.t)

    def evaluator_argv(self):
        return [str(self.proton / "proton"), "run", str(self.steam / "legacycompat/iscriptevaluator.exe"),
                "legacycompat\\evaluatorscript_274190.vdf"]

    def chain(self, verb="run", inner=None):
        return [sys.executable, str(self.tool), verb, "--", str(self.steam / "steamapps/common/SteamLinuxRuntime_4/_v2-entry-point"),
                "--verb=" + verb, "--"] + (inner or self.evaluator_argv())

    def key(self):
        h = hashlib.sha256()
        for a in self.evaluator_argv()[3:]:
            h.update(a.encode() + b"\0")
        h.update(self.script.read_bytes())
        h.update((self.proton / "version").read_bytes())
        st = os.stat(self.data / "pfx")
        h.update(("%d:%d" % (st.st_dev, st.st_ino)).encode())
        return h.hexdigest()

    def record(self, key=None):
        (self.data / "powos-iscript.done").write_text((key or self.key()) + "\n")

    def run_chain(self, argv, cwd=None):
        return subprocess.run(argv, env=self.env, cwd=cwd or self.t, capture_output=True, text=True, timeout=60)

    def log(self):
        p = self.data / "powos-iscript.log"
        return p.read_text() if p.exists() else ""

    def test_skips_before_container_when_recorded(self):
        self.record()
        r = self.run_chain(self.chain())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("CHAIN STARTED", r.stdout)
        self.assertIn("skipped before the container", self.log())

    def test_runs_when_script_changed(self):
        self.record()
        self.script.write_text('"evaluatorscript" { "new" }')
        r = self.run_chain(self.chain())
        self.assertEqual(r.returncode, 7)
        self.assertIn("CHAIN STARTED", r.stdout)

    def test_runs_without_record(self):
        r = self.run_chain(self.chain())
        self.assertEqual(r.returncode, 7)
        self.assertEqual(self.log(), "")

    def test_users_own_user_settings_left_alone(self):
        self.record()
        (self.proton / "user_settings.py").write_text("user_settings = {}\n")
        r = self.run_chain(self.chain())
        self.assertEqual(r.returncode, 7)

    def test_game_launch_untouched(self):
        self.record()
        game = [str(self.proton / "proton"), "waitforexitandrun", "S:\\Broforce.exe"]
        r = self.run_chain(self.chain("waitforexitandrun", game))
        self.assertEqual(r.returncode, 7)
        r = subprocess.run([sys.executable, "-c", "print('other')"], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.stdout.strip(), "other")

    def test_proton_import_still_skips_and_records(self):
        # Inside Proton: sys.argv = proton's, `import user_settings` from its dir.
        # sys.argv[0] must be the proton script (its dir holds "version"): a stand-in named proton.
        prot = self.proton / "proton"
        prot.write_text("import sys\nsys.path.insert(0, %r)\nimport user_settings\nsys.exit(0)\n" % str(self.proton))
        argv = [sys.executable, str(prot)] + self.evaluator_argv()[1:]
        r = self.run_chain(argv)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.data / "powos-iscript.done").read_text().strip(), self.key())
        self.assertIn("exited 0, recorded", self.log())
        r = self.run_chain(argv)
        self.assertIn("skipped: script, Proton and prefix", self.log())


if __name__ == "__main__":
    unittest.main(verbosity=2)
