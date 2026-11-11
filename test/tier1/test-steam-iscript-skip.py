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

    def key(self, with_version=False):
        h = hashlib.sha256()
        for a in self.evaluator_argv()[3:]:
            h.update(a.encode() + b"\0")
        h.update(self.script.read_bytes())
        if with_version:
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

    def test_proton_update_still_skips(self):
        # 11-11: Valve's Proton Experimental update re-ran the evaluator at each game's next tap (+20 s); the marks it
        # checks live in the prefix, which the update keeps.
        self.record()
        (self.proton / "version").write_text("1794360000 experimental-11.0-next\n")
        r = self.run_chain(self.chain())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("CHAIN STARTED", r.stdout)

    def test_old_record_with_version_honoured_and_rewritten(self):
        self.record(self.key(with_version=True))
        r = self.run_chain(self.chain())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("CHAIN STARTED", r.stdout)
        self.assertEqual((self.data / "powos-iscript.done").read_text().strip(), self.key())

    def test_runs_when_prefix_replaced(self):
        self.record()
        shutil.rmtree(self.data / "pfx")
        (self.data / "pfx").mkdir()
        (self.data / "pfx/creation_sync_guard").touch()
        r = self.run_chain(self.chain())
        self.assertEqual(r.returncode, 7)

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
        self.assertIn("skipped: script and prefix", self.log())


class Arm64Gate(IscriptSkip):
    """arm64-gate-entry: the compat tool "powos-proton-arm64" Steam runs instead of Valve's chain for ARM64 Proton."""

    def setUp(self):
        super().setUp()
        self.proton = self.steam / "steamapps/common/Proton Experimental (ARM64)"
        self.proton.mkdir(parents=True)
        (self.proton / "version").write_text("1793301884 experimental-11.0-arm64\n")
        shutil.copy(PKG / "user_settings.py", self.proton / "user_settings.py")
        slr = self.steam / "steamapps/common/SteamLinuxRuntime_4-arm64"
        slr.mkdir(parents=True)
        # Stand-in for Valve's _v2-entry-point: prints what it was given, as the container chain would start.
        self.entry = slr / "_v2-entry-point"
        self.entry.write_text("#!/bin/sh\necho CHAIN STARTED \"$@\"\necho TOOLS=$STEAM_COMPAT_TOOL_PATHS\nexit 7\n")
        self.entry.chmod(0o755)
        self.gate = PKG / "arm64-gate-entry"
        self.env["STEAM_COMPAT_TOOL_PATHS"] = str(self.steam / "compatibilitytools.d/powos-proton-arm64")

    def chain(self, verb="run", inner=None):
        return [sys.executable, str(self.gate), verb] + (inner or self.evaluator_argv())[2:]

    def test_game_launch_untouched(self):
        self.record()
        r = self.run_chain(self.chain("waitforexitandrun", ["proton", "waitforexitandrun", "S:\\Broforce.exe"]))
        self.assertEqual(r.returncode, 7)
        self.assertIn("CHAIN STARTED --verb=waitforexitandrun -- %s waitforexitandrun S:\\Broforce.exe"
                      % (self.proton / "proton"), r.stdout)
        self.assertIn("TOOLS=%s:%s" % (self.proton, self.entry.parent), r.stdout)

    def test_proton_import_still_skips_and_records(self):
        pass  # Proton's own import: covered by IscriptSkip


class Arm64GateOverlay(Arm64Gate):
    """arm64-gate-entry OVERLAY: our kernelbase.dll goes into exactly the Valve Proton build it was made from."""

    VALVE, OURS = b"valve kernelbase", b"powos kernelbase, longer"

    def setUp(self):
        super().setUp()
        self.dll = self.proton / "files/lib/wine/aarch64-windows/kernelbase.dll"
        self.dll.parent.mkdir(parents=True)
        self.dll.write_bytes(self.VALVE)
        tool = self.steam / "compatibilitytools.d/powos-proton-arm64"
        tool.mkdir(parents=True)
        (tool / "overlay-kernelbase.dll").write_bytes(self.OURS)
        # The overlay table lives in powos_steam_tools.py (next to the gate): its first row's hashes -> the fixture's.
        src = (PKG / "powos_steam_tools.py").read_text()
        for old, new in zip(Arm64GateOverlay.shas_in(src), (self.VALVE, self.OURS)):
            src = src.replace(old, hashlib.sha256(new).hexdigest())
        (tool / "powos_steam_tools.py").write_text(src)
        self.gate = tool / "powos-entry"
        shutil.copy(PKG / "arm64-gate-entry", self.gate)
        self.env["XDG_CACHE_HOME"] = str(self.steam.parent / "cache")

    @staticmethod
    def shas_in(src):
        block = src[src.index("OVERLAYS = ["):]
        return [w.strip('",()') for w in block.split() if len(w.strip('",()')) == 64][:2]

    def launch(self):
        return self.run_chain(self.chain("waitforexitandrun", ["proton", "waitforexitandrun", "S:\\Broforce.exe"]))

    def test_valve_build_gets_ours(self):
        r = self.launch()
        self.assertEqual(r.returncode, 7)
        self.assertEqual(self.dll.read_bytes(), self.OURS)
        self.assertEqual(Path(str(self.dll) + ".valve").read_bytes(), self.VALVE)
        self.launch()  # in place: left alone
        self.assertEqual(self.dll.read_bytes(), self.OURS)

    def test_other_proton_build_untouched(self):
        self.dll.write_bytes(b"a newer Valve build")
        r = self.launch()
        self.assertEqual(r.returncode, 7)
        self.assertEqual(self.dll.read_bytes(), b"a newer Valve build")
        self.assertFalse(Path(str(self.dll) + ".valve").exists())


class MonoAnonCache(unittest.TestCase):
    """user_settings.py: FEX's anonymous-code disk cache off for Mono games only."""

    def settings(self, layout, key="FEX_DISKCACHEANONCACHING", override=None):
        t = Path(tempfile.mkdtemp())
        try:
            for f in layout:
                (t / f).parent.mkdir(parents=True, exist_ok=True)
                (t / f).write_text("x")
            if override is not None:
                (t / ".config/powos").mkdir(parents=True)
                (t / ".config/powos/proton-settings.json").write_text(override)
            code = "import runpy; print(runpy.run_path(%r)['user_settings'].get(%r))" % (str(PKG / "user_settings.py"), key)
            r = subprocess.run([sys.executable, "-c", code], env=dict(os.environ, STEAM_COMPAT_INSTALL_PATH=str(t), HOME=str(t)),
                               capture_output=True, text=True, timeout=30)
            return r.stdout.strip()
        finally:
            shutil.rmtree(t)

    def test_unity_mono(self):
        self.assertEqual(self.settings(["Broforce_beta_Data/Mono/EmbedRuntime/mono.dll"]), "0")
        self.assertEqual(self.settings(["MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll"]), "0")

    def test_other_games_keep_fex_default(self):
        self.assertEqual(self.settings(["Game.exe", "GameAssembly.dll"]), "None")
        self.assertEqual(self.settings(["Game.exe", "GameAssembly.dll"], "FEX_TSOENABLED"), "None")

    def test_mono_main_thread_tso_off(self):
        """The Mono game's main thread without FEX's TSO barriers (15-23 % fewer cycles per frame, 11-05 A/B)."""
        self.assertEqual(self.settings(["Broforce_beta_Data/Mono/EmbedRuntime/mono.dll"], "FEX_TSOENABLED"), "0")
        self.assertEqual(self.settings(["MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll"], "FEX_TSOENABLED"), "0")

    def test_tso_back_on_per_check(self):
        """proton-settings.json still wins: a check (or the user) turns TSO back on for one run."""
        self.assertEqual(self.settings(["Broforce_beta_Data/Mono/EmbedRuntime/mono.dll"], "FEX_TSOENABLED",
                                       '{"FEX_TSOENABLED": "1"}'), "1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
