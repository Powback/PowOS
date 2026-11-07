#!/usr/bin/env python3
"""
Tests for the version-proof gaming fixes (docs/research/version-proof-gaming.md): every PowOS fix that goes into
Valve's Steam tools, Proton, FEX or Turnip keeps working - or says clearly that it doesn't - across upstream versions.

Covers, each against two upstream "versions" (fixtures):
- powos_steam_tools: ARM64 Proton found by capability (aarch64-windows Wine), the preferred name first, a renamed
  one still found, x86 Proton and our own gate never; the newest SteamLinuxRuntime_<n>-arm64; wine tag from a version
- arm64-gate-entry: the kernelbase overlay goes into Valve build A; Steam updates Proton to build B (no overlay row):
  Valve's file stays, the launch still runs, "fix kernelbase-wow32 not applied" names B and the rebuild command;
  a row for B: it goes back in on the next launch by itself, .valve refreshed to B
- powos-steam-fixes: FEX_* options from steam-env checked against two Valve FEX binaries (one reads FEX_THUNKCONFIG,
  one doesn't); TU_DEBUG flags against two Turnip builds; Steam putting Valve's FEX back over the futex_waitv build;
  a fex-compat-tool that stopped being Python
- fex-options-check.py: our FEX config against two FEX source trees (an option renamed in the second -> build fails)
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG = REPO / "targets/android/pkgs/steam"
FEXPKG = REPO / "targets/android/pkgs/fex-emu"


def sha(b):
    return hashlib.sha256(b).hexdigest()


def load_tools():
    import importlib.util
    spec = importlib.util.spec_from_file_location("powos_steam_tools_t", PKG / "powos_steam_tools.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Base(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.S = self.t / "Steam"
        self.common = self.S / "steamapps/common"
        self.common.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def proton(self, name, arm64=True, version="1 experimental-11.0-20261027b-arm64", base=None):
        d = (base or self.common) / name
        (d / ("files/lib/wine/aarch64-windows" if arm64 else "files/lib/wine/x86_64-windows")).mkdir(parents=True)
        (d / "proton").write_text("#!/bin/sh\n")
        (d / "version").write_text(version + "\n")
        return d

    def runtime(self, n):
        d = self.common / ("SteamLinuxRuntime_%d-arm64" % n)
        d.mkdir(parents=True)
        e = d / "_v2-entry-point"
        e.write_text("#!/bin/sh\necho \"ENTRY $0\"; echo ENTRY \"$@\"\n")
        e.chmod(0o755)
        return d


class Discovery(Base):
    def test_arm64_proton_by_capability(self):
        T = load_tools()
        self.assertIsNone(T.arm64_proton(str(self.S)))
        self.proton("Proton 10.0", arm64=False)
        self.assertIsNone(T.arm64_proton(str(self.S)), "an x86 Proton is never the ARM64 one")
        r = self.proton("Proton 12.0 (ARM64)")
        self.assertEqual(T.arm64_proton(str(self.S)), str(r), "a renamed ARM64 Proton is still found")
        e = self.proton("Proton Experimental (ARM64)")
        self.assertEqual(T.arm64_proton(str(self.S)), str(e), "Valve's Experimental (ARM64) by name first")
        (self.S / "compatibilitytools.d").mkdir()
        g = self.proton("powos-proton-arm64", base=self.S / "compatibilitytools.d")
        self.assertNotIn(str(g), T.arm64_protons(str(self.S)), "our own gate is never a Proton")

    def test_runtime_newest(self):
        T = load_tools()
        self.assertIsNone(T.arm64_runtime(str(self.S)))
        self.runtime(4)
        self.assertTrue(T.arm64_runtime(str(self.S)).endswith("SteamLinuxRuntime_4-arm64"))
        self.runtime(5)
        (self.common / "SteamLinuxRuntime_6-arm64").mkdir()  # no entry point: not a runtime
        self.assertTrue(T.arm64_runtime(str(self.S)).endswith("SteamLinuxRuntime_5-arm64"))

    def test_wine_tag(self):
        T = load_tools()
        self.assertEqual(T.wine_tag("experimental-11.0-20261027b-arm64"), "experimental-wine-11.0-20261027b")
        self.assertEqual(T.wine_tag("experimental-12.0-20270115-arm64"), "experimental-wine-12.0-20270115")
        self.assertIsNone(T.wine_tag("proton-10.0-3"))


class Overlay(Base):
    """The gate (arm64-gate-entry) against Valve build A, then a Proton update to build B."""

    def setUp(self):
        super().setUp()
        self.A, self.B, self.OURS_A, self.OURS_B = b"valve-A" * 100, b"valve-B" * 100, b"ours-A" * 100, b"ours-B" * 100
        self.gate = self.S / "compatibilitytools.d/powos-proton-arm64"
        self.gate.mkdir(parents=True)
        shutil.copy(PKG / "arm64-gate-entry", self.gate / "powos-entry")
        (self.gate / "overlay-kernelbase.dll").write_bytes(self.OURS_A)
        self.rows = [("files/lib/wine/aarch64-windows/kernelbase.dll", sha(self.A), sha(self.OURS_A),
                      "overlay-kernelbase.dll", "experimental-11.0-20261027b-arm64")]
        self.write_tools()
        self.p = self.proton("Proton Experimental (ARM64)")
        self.dll = self.p / "files/lib/wine/aarch64-windows/kernelbase.dll"
        self.dll.write_bytes(self.A)
        self.runtime(4)

    def write_tools(self):
        src = (PKG / "powos_steam_tools.py").read_text()
        (self.gate / "powos_steam_tools.py").write_text(src + "\nOVERLAYS = %r\n" % (self.rows,))

    def launch(self):
        env = dict(os.environ, STEAM_COMPAT_CLIENT_INSTALL_PATH=str(self.S), XDG_CACHE_HOME=str(self.t / "cache"))
        env.pop("POWOS_ARM64_PROTON", None)
        env.pop("POWOS_ARM64_RUNTIME", None)
        return subprocess.run([sys.executable, str(self.gate / "powos-entry"), "waitforexitandrun", "game.exe"],
                              env=env, capture_output=True, text=True, timeout=60)

    def status(self):
        return (self.t / "cache/powos/steam-fixes/kernelbase-wow32.txt").read_text().strip()

    def test_two_valve_builds(self):
        r = self.launch()
        self.assertIn("ENTRY --verb=waitforexitandrun -- %s/proton waitforexitandrun game.exe" % self.p, r.stdout)
        self.assertEqual(self.dll.read_bytes(), self.OURS_A, "build A: ours goes in")
        self.assertEqual((self.p / "files/lib/wine/aarch64-windows/kernelbase.dll.valve").read_bytes(), self.A)
        self.assertTrue(self.status().startswith("fix kernelbase-wow32 applied"), self.status())
        self.assertIn("applied", r.stderr)
        r = self.launch()
        self.assertEqual(r.stderr, "", "said once, not on every launch")
        # Steam updates Proton: Valve's build B (a new file, as Steam's update writes it), a new version, no row for it.
        self.dll.unlink()
        self.dll.write_bytes(self.B)
        (self.p / "version").write_text("2 experimental-12.0-20270115-arm64\n")
        r = self.launch()
        self.assertIn("ENTRY", r.stdout, "the game still launches (stock)")
        self.assertEqual(self.dll.read_bytes(), self.B, "Valve's B stays")
        self.assertIn("fix kernelbase-wow32 not applied", r.stderr)
        self.assertIn("PROTON_VERSION=experimental-12.0-20270115-arm64", self.status())
        # A row for B (the overlay rebuilt for it): the next launch puts it in by itself.
        (self.gate / "overlay-kernelbase.dll").write_bytes(self.OURS_B)
        self.rows.append((self.rows[0][0], sha(self.B), sha(self.OURS_B), "overlay-kernelbase.dll",
                          "experimental-12.0-20270115-arm64"))
        self.write_tools()
        self.launch()
        self.assertEqual(self.dll.read_bytes(), self.OURS_B, "build B: ours goes back in after the update")
        self.assertEqual((self.p / "files/lib/wine/aarch64-windows/kernelbase.dll.valve").read_bytes(), self.B,
                         ".valve is the build it replaced")

    def test_renamed_proton_and_runtime(self):
        shutil.move(str(self.p), str(self.common / "Proton 12.0 (ARM64)"))
        shutil.move(str(self.common / "SteamLinuxRuntime_4-arm64"), str(self.common / "SteamLinuxRuntime_5-arm64"))
        r = self.launch()
        self.assertIn("ENTRY %s/_v2-entry-point" % (self.common / "SteamLinuxRuntime_5-arm64"), r.stdout)
        self.assertIn("ENTRY --verb=waitforexitandrun -- %s/proton" % (self.common / "Proton 12.0 (ARM64)"), r.stdout)


class FixesReport(Base):
    def setUp(self):
        super().setUp()
        self.fex = self.common / "FEX-Emu"
        (self.fex / "usr/bin").mkdir(parents=True)
        (self.fex / "fex-compat-tool").write_text("#!/usr/bin/env python3\n")
        (self.fex / "VERSIONS.txt").write_text("describe: FEX-2607-76-g37265b1\n")
        self.env = self.t / "steam-env"
        self.env.write_text("FEX_THUNKCONFIG=/x\nTU_DEBUG=noubwc\nPYTHONPATH=/usr/lib/powos-steam/py\n")
        self.lib = self.t / "libvulkan_freedreno.so"

    def report(self):
        env = dict(os.environ, POWOS_STEAM_DIR=str(self.S), POWOS_STEAM_ENV_FILES=str(self.env),
                   POWOS_TURNIP_LIB=str(self.lib), XDG_CACHE_HOME=str(self.t / "cache"))
        r = subprocess.run([sys.executable, str(PKG / "powos-steam-fixes"), "--json"], env=env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return {x["fix"]: x for x in json.loads(r.stdout)}

    def test_fex_env_two_fex_versions(self):
        (self.fex / "usr/bin/FEX").write_bytes(b"\0FEX_THUNKCONFIG\0FEX_TSOENABLED\0")
        self.assertTrue(self.report()["fex-env FEX_THUNKCONFIG"]["applied"])
        (self.fex / "usr/bin/FEX").write_bytes(b"\0FEX_THUNKCONFIGFILE\0")  # a FEX that renamed the option
        r = self.report()["fex-env FEX_THUNKCONFIG"]
        self.assertFalse(r["applied"])
        self.assertIn("doesn't know FEX_THUNKCONFIG", r["why"])

    def test_turnip_flag_from_user_settings(self):
        # 11-07: noubwc moved from steam-env into user_settings.py's default (Proton's env beat proton-settings.json).
        self.env.write_text("FEX_THUNKCONFIG=/x\n")
        us = self.t / "user_settings.py"
        us.write_text('user_settings = {}\nuser_settings["TU_DEBUG"] = "noubwc"\n')
        self.lib.write_bytes(b"\0syncdraw\0noubwc\0")
        env = dict(os.environ, POWOS_STEAM_DIR=str(self.S), POWOS_STEAM_ENV_FILES=str(self.env), POWOS_USER_SETTINGS=str(us),
                   POWOS_TURNIP_LIB=str(self.lib), XDG_CACHE_HOME=str(self.t / "cache"))
        r = subprocess.run([sys.executable, str(PKG / "powos-steam-fixes"), "--json"], env=env, capture_output=True,
                           text=True, timeout=60)
        rep = {x["fix"]: x for x in json.loads(r.stdout)}
        self.assertTrue(rep["turnip TU_DEBUG=noubwc"]["applied"])

    def test_turnip_flag_two_builds(self):
        self.lib.write_bytes(b"\0syncdraw\0noubwc\0flushall\0")
        self.assertTrue(self.report()["turnip TU_DEBUG=noubwc"]["applied"])
        self.lib.write_bytes(b"\0syncdraw\0flushall\0")
        self.assertFalse(self.report()["turnip TU_DEBUG=noubwc"]["applied"])

    def test_futex_build_put_back_by_steam(self):
        (self.fex / "usr/bin/FEX.valve").write_bytes(b"valve")
        (self.fex / "usr/bin/FEX").write_bytes(b"powos")
        self.assertTrue(self.report()["fex-futex-waitv"]["applied"])
        (self.fex / "usr/bin/FEX").write_bytes(b"valve")
        r = self.report()["fex-futex-waitv"]
        self.assertFalse(r["applied"])
        self.assertIn("FEX-2607-76-g37265b1", r["why"])

    def test_fex_compat_tool_not_python(self):
        (self.fex / "usr/bin/FEX").write_bytes(b"")
        self.assertTrue(self.report()["iscript-early-x86"]["applied"])
        (self.fex / "fex-compat-tool").write_bytes(b"\x7fELF\x02\x01")
        self.assertFalse(self.report()["iscript-early-x86"]["applied"])

    def test_no_arm64_proton_said(self):
        self.proton("Proton 10.0", arm64=False)
        r = self.report()
        self.assertFalse(r["arm64-gate"]["applied"])
        self.assertIn("no ARM64 Proton", r["arm64-gate"]["why"])


class FexOptions(unittest.TestCase):
    def tree(self, d, options, libs):
        (d / "FEXCore/Source/Interface/Config").mkdir(parents=True)
        (d / "Data").mkdir()
        (d / "FEXCore/Source/Interface/Config/Config.json.in").write_text(
            json.dumps({"Options": {"Misc": {o: {"Type": "str"} for o in options}}}))
        (d / "Data/ThunksDB.json").write_text(json.dumps({"DB": {l: {} for l in libs}}))

    def test_two_fex_trees(self):
        t = Path(tempfile.mkdtemp())
        try:
            good, bad = t / "FEX-a", t / "FEX-b"
            opts = ["RootFS", "ThunkHostLibs", "ThunkGuestLibs", "ThunkConfig"]
            libs = ["GL", "Vulkan", "drm", "WaylandClient", "asound"]
            self.tree(good, opts, libs)
            self.tree(bad, ["RootFS", "ThunkHostLibs", "ThunkGuestLibs", "ThunkConfigFile"], libs)
            files = [str(FEXPKG / "Config.json"), str(FEXPKG / "thunks.json")]
            r = subprocess.run([sys.executable, str(FEXPKG / "fex-options-check.py"), "--fex", str(good)] + files,
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            r = subprocess.run([sys.executable, str(FEXPKG / "fex-options-check.py"), "--fex", str(bad)] + files,
                               capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 1)
            self.assertIn("fex option ThunkConfig (Config.json) not in FEX-b", r.stderr)
        finally:
            shutil.rmtree(t, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
