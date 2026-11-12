#!/usr/bin/env python3
"""
Tests for the pre-booted Wine session (targets/android/pkgs/steam/powos_preboot.py + arm64-gate-entry's join;
docs/research/broforce-engine-init.md lever 1).

A fake Steam tree: the ARM64 runtime's _v2-entry-point records its --verb and execs the rest; the fake Proton's
`runinprefix` boots a fake session (a "wineserver" whose cwd is the prefix's server dir, a "services.exe" with the
prefix's WINEPREFIX, the holder reading stdin), `run` records whether a session was up when the game started, and
`waitforexitandrun` waits for any session first (wineserver -w), as Proton's do.

Covers:
- switch off (default): `start` boots nothing; the game's launch is Proton `waitforexitandrun` as before
- switch on (global POWOS_WINE_PREBOOT=1, or per game steam-compat.json preboot=on; per-game off beats global on):
  `start` boots the session, the launch claims it and runs Proton `run` inside it (container verb unchanged), the
  gate exits only after the session ended (Steam's reaper sees the end after the wineserver), with the game's rc
- the gate's env snapshot is written by every launch; no snapshot -> `start` boots nothing
- a session the launch can't join (environment differs) is ended and the launch falls back to waitforexitandrun
- an unclaimed session ends by itself after the idle timeout; a game not on powos-proton-arm64 is never pre-booted
- the holder outlives pressure-vessel's /dev/null stdin (its FIFO is opened inside the container)
- `early` (PowOS on screen, before the tap): boots the last-played game's session only with the switch on, a lit
  display, Steam running and one early boot per gap; ends when the screen goes dark or Steam exits; a launch joins it
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG = REPO / "targets/android/pkgs/steam"
APP = "274190"

# As pressure-vessel-wrap: the command's stdin is /dev/null (wrap.c, unless --terminal=tty) - the pre-boot's holder
# can't wait on a stdin given from outside the container (11-12: it read EOF and the session ended ~1 s after booting).
ENTRY = r"""#!/bin/sh
v=${1#--verb=}; shift; [ "$1" = -- ] && shift
echo "$v" >> "$POWOS_TEST_LOG.entry"
exec "$@" </dev/null
"""

# Fake Proton: CURRENT_PREFIX_VERSION as Valve's script has it (powos_preboot.prefix_current reads it).
PROTON = r'''#!/usr/bin/env python3
CURRENT_PREFIX_VERSION="11.0-100"
import os, subprocess, sys, time
log = os.environ["POWOS_TEST_LOG"]
pfx = os.path.join(os.environ["STEAM_COMPAT_DATA_PATH"], "pfx")
st = os.stat(pfx)
sd = os.path.join(os.environ["POWOS_WINE_SERVER_ROOT"], ".wine-%d" % os.getuid(), "server-%x-%x" % (st.st_dev, st.st_ino))

def server_pids():
    out = []
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if os.readlink("/proc/%s/cwd" % p) == sd:
                    out.append(int(p))
            except OSError:
                pass
    return out

def note(s):
    with open(log, "a") as f:
        f.write(s + "\n")

verb = sys.argv[1]
if verb == "runinprefix":
    os.makedirs(sd, exist_ok=True)
    holder = os.getpid()
    # wineserver + services: alive while the holder (a user process) is; then the session ends ~0.3 s later.
    keep = "import os,time,sys\nwhile os.path.exists('/proc/%d'): time.sleep(0.05)\ntime.sleep(0.3)\n" % holder
    subprocess.Popen([sys.executable, "-c", keep], cwd=sd, start_new_session=True)
    env = dict(os.environ, WINEPREFIX=pfx)
    subprocess.Popen([sys.executable, "-c", keep, "C:\\windows\\system32\\services.exe"], env=env, start_new_session=True)
    note("boot " + " ".join(sys.argv[2:]))
    sys.stdin.read()  # the holder: cmd's `set /p`, until the keeper closes the pipe
    note("holder exit")
elif verb == "run":
    note("run session=%s cmd=%s" % ("up" if server_pids() else "none", " ".join(sys.argv[2:])))
    time.sleep(0.2)
    sys.exit(7)
elif verb == "waitforexitandrun":
    t = time.time()
    while server_pids() and time.time() - t < 20:
        time.sleep(0.05)
    note("waitforexitandrun waited=%d cmd=%s" % (time.time() - t > 0.1, " ".join(sys.argv[2:])))
    sys.exit(0)
'''

CONFIG = """"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"%s"
					{
						"name"		"%s"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
"""


class WinePreboot(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.steam = self.t / ".local/share/Steam"
        common = self.steam / "steamapps/common"
        self.proton = common / "Proton Experimental (ARM64)"
        self.slr = common / "SteamLinuxRuntime_4-arm64"
        self.cd = self.steam / "steamapps/compatdata" / APP
        for d in (self.proton / "files/lib/wine/aarch64-windows", self.slr, self.cd / "pfx", self.steam / "config",
                  self.t / "srv"):
            d.mkdir(parents=True)
        (self.cd / "version").write_text("11.0-100\n")
        (self.proton / "version").write_text("1 experimental-11.0-test-arm64\n")
        (self.proton / "proton").write_text(PROTON)
        (self.slr / "_v2-entry-point").write_text(ENTRY)
        for f in (self.proton / "proton", self.slr / "_v2-entry-point"):
            f.chmod(0o755)
        self.map_tool("powos-proton-arm64")
        self.log = self.t / "log"
        self.state = self.t / "steam-compat.json"
        self.env = dict(os.environ, HOME=str(self.t), XDG_CACHE_HOME=str(self.t / "cache"),
                        STEAM_COMPAT_CLIENT_INSTALL_PATH=str(self.steam), STEAM_COMPAT_DATA_PATH=str(self.cd),
                        STEAM_COMPAT_APP_ID=APP, SteamAppId=APP, POWOS_WINE_SERVER_ROOT=str(self.t / "srv"),
                        POWOS_TEST_LOG=str(self.log), POWOS_STEAM_COMPAT_STATE=str(self.state),
                        POWOS_STEAM_PY=str(PKG), WINEDLLOVERRIDES="steam.exe=b")
        self.env.pop("POWOS_WINE_PREBOOT", None)
        self.keepers = []
        self.backlight = self.t / "backlight"
        self.backlight.write_text("120\n")
        self.steam_proc = subprocess.Popen(["sleep", "60"])  # the Steam client (~/.steam/steam.pid)
        (self.t / "steam.pid").write_text("%d\n" % self.steam_proc.pid)
        self.env.update(POWOS_BACKLIGHT_GLOB=str(self.backlight), POWOS_STEAM_PIDFILE=str(self.t / "steam.pid"))

    def tearDown(self):
        self.steam_proc.kill()
        self.steam_proc.wait()
        for k in self.keepers:
            if k.poll() is None:
                k.kill()
                k.wait()
        time.sleep(0.5)  # fake session processes end with their holder
        shutil.rmtree(self.t, ignore_errors=True)

    def map_tool(self, name):
        (self.steam / "config/config.vdf").write_text(CONFIG % (APP, name))

    def lines(self, suffix=""):
        p = Path(str(self.log) + suffix)
        return p.read_text().splitlines() if p.exists() else []

    def gate(self, env=None):
        return subprocess.run([sys.executable, str(PKG / "arm64-gate-entry"), "waitforexitandrun", "game.exe"],
                              env=env or self.env, capture_output=True, text=True, timeout=60)

    def start(self, env=None):
        k = subprocess.Popen([sys.executable, str(PKG / "powos_preboot.py"), "start", APP], env=env or self.env)
        self.keepers.append(k)
        return k

    def early(self, env=None):
        k = subprocess.Popen([sys.executable, str(PKG / "powos_preboot.py"), "early"], env=env or self.env)
        self.keepers.append(k)
        return k

    def session(self):
        try:
            return json.loads((self.cd / "powos-preboot/session.json").read_text())
        except (OSError, ValueError):
            return None

    def wait_state(self, want, timeout=10):
        t = time.time()
        while time.time() - t < timeout:
            s = self.session()
            if s and s.get("state") == want:
                return s
            time.sleep(0.05)
        self.fail("session never %s (now %s); log: %s" % (want, self.session(), self.preboot_log()))

    def preboot_log(self):
        p = self.cd / "powos-preboot/log"
        return p.read_text() if p.exists() else ""

    def first_launch(self):
        """A launch through the gate before any pre-boot: writes the environment snapshot."""
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.cd / "powos-preboot/env.json").exists(), "the gate wrote no environment snapshot")
        self.log.unlink()
        Path(str(self.log) + ".entry").unlink()

    def test_off_by_default(self):
        self.first_launch()
        k = self.start()
        self.assertEqual(k.wait(10), 0)
        self.assertIsNone(self.session())
        self.assertEqual(self.lines(), [])  # nothing booted
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lines(".entry"), ["waitforexitandrun"])
        self.assertTrue(self.lines()[0].startswith("waitforexitandrun waited=0 cmd=game.exe"), self.lines())

    def test_on_join_run_and_end_after_session(self):
        self.first_launch()
        env = dict(self.env, POWOS_WINE_PREBOOT="1")
        k = self.start(env)
        s = self.wait_state("up")
        self.assertIsNotNone(s["up_ms"])
        t = time.time()
        r = self.gate()  # the game's launch: Steam's env has no POWOS_WINE_PREBOOT (the switch is the trigger's)
        self.assertEqual(r.returncode, 7, r.stderr)  # Proton run's rc passed through
        self.assertEqual(self.lines(".entry"), ["run", "waitforexitandrun"],
                         "pre-boot runs the container as `run`; the game's container keeps waitforexitandrun")
        ls = self.lines()
        self.assertTrue(ls[0].startswith("boot cmd.exe /c set /p POWOS_WINE_PREBOOT_HOLD="), ls)
        self.assertIn("run session=up cmd=game.exe", ls, "the game ran Proton `run` into the live session")
        self.assertIn("holder exit", ls)
        # the gate returned only after the session (its wineserver) ended: the keeper is gone, no session left
        self.assertEqual(k.wait(5), 0)
        self.assertIsNone(self.session())
        self.assertFalse(any(l.startswith("waitforexitandrun") for l in ls), ls)
        self.assertGreater(time.time() - t, 0.4)  # run 0.2 s + session end 0.3 s
        self.assertIn("claimed by the game's launch (booted", self.preboot_log())

    def test_per_game_switch(self):
        self.first_launch()
        self.state.write_text(json.dumps({"apps": {APP: {"preboot": "off"}}}))
        k = self.start(dict(self.env, POWOS_WINE_PREBOOT="1"))
        self.assertEqual(k.wait(10), 0)
        self.assertIsNone(self.session())
        self.state.write_text(json.dumps({"apps": {APP: {"preboot": "on"}}}))
        self.start()
        self.wait_state("up")

    def test_no_snapshot_no_preboot(self):
        k = self.start(dict(self.env, POWOS_WINE_PREBOOT="1"))
        self.assertEqual(k.wait(10), 0)
        self.assertIsNone(self.session())
        self.assertIn("no launch environment yet", self.preboot_log())

    def test_other_tool_never_preboots(self):
        self.first_launch()
        self.map_tool("proton_experimental")
        k = self.start(dict(self.env, POWOS_WINE_PREBOOT="1"))
        self.assertEqual(k.wait(10), 0)
        self.assertIsNone(self.session())
        self.assertIn("not powos-proton-arm64", self.preboot_log())

    def test_env_mismatch_falls_back(self):
        self.first_launch()
        k = self.start(dict(self.env, POWOS_WINE_PREBOOT="1"))
        self.wait_state("up")
        r = self.gate(dict(self.env, WINEDLLOVERRIDES="steam.exe=b;d3d11=n"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lines(".entry"), ["run", "waitforexitandrun"])
        ls = self.lines()
        self.assertTrue(any(l.startswith("waitforexitandrun waited=1") for l in ls),
                        "the launch must wait for the refused session to end: %s" % ls)
        self.assertEqual(k.wait(5), 0)
        self.assertIn("environment differs: WINEDLLOVERRIDES", self.preboot_log())

    def test_idle_timeout(self):
        self.first_launch()
        k = self.start(dict(self.env, POWOS_WINE_PREBOOT="1", POWOS_WINE_PREBOOT_IDLE_S="1"))
        self.wait_state("up")
        self.assertEqual(k.wait(10), 0)
        self.assertIsNone(self.session())
        self.assertIn("holder exit", self.lines())
        self.assertIn("not claimed in 1 s", self.preboot_log())

    def test_holder_survives_pv_stdin(self):
        """The session stays up while unclaimed: the holder's stdin is not pressure-vessel's /dev/null."""
        self.first_launch()
        k = self.start(dict(self.env, POWOS_WINE_PREBOOT="1"))
        self.wait_state("up")
        time.sleep(2)
        self.assertIsNone(k.poll(), "keeper ended: %s" % self.preboot_log())
        self.assertEqual(self.session()["state"], "up")
        self.assertNotIn("holder exit", self.lines())
        self.assertNotIn("holder exited", self.preboot_log())

    def test_early_boots_last_played_and_launch_joins(self):
        self.first_launch()
        k = self.early(dict(self.env, POWOS_WINE_PREBOOT="1"))
        s = self.wait_state("up")
        self.assertTrue(s["early"])
        self.assertIn("early: before the tap", self.preboot_log())
        # the tap's own start finds it and leaves it alone
        self.assertEqual(self.start(dict(self.env, POWOS_WINE_PREBOOT="1")).wait(10), 0)
        r = self.gate()
        self.assertEqual(r.returncode, 7, r.stderr)
        self.assertIn("run session=up cmd=game.exe", self.lines())
        self.assertEqual(k.wait(5), 0)
        self.assertIsNone(self.session())

    def test_early_off_by_default(self):
        self.first_launch()
        self.assertEqual(self.early().wait(10), 0)
        self.assertIsNone(self.session())
        self.assertEqual(self.lines(), [])

    def test_early_needs_screen_and_steam(self):
        self.first_launch()
        env = dict(self.env, POWOS_WINE_PREBOOT="1")
        self.backlight.write_text("0\n")
        self.assertEqual(self.early(env).wait(10), 0)
        self.assertIn("early: skipped, the screen is off", self.preboot_log())
        self.backlight.write_text("80\n")
        self.assertEqual(self.early(dict(env, POWOS_STEAM_PIDFILE=str(self.t / "none.pid"))).wait(10), 0)
        self.assertIn("early: skipped, Steam is not running", self.preboot_log())
        self.assertIsNone(self.session())
        self.assertEqual(self.lines(), [])

    def test_early_ends_when_screen_off(self):
        self.first_launch()
        k = self.early(dict(self.env, POWOS_WINE_PREBOOT="1"))
        self.wait_state("up")
        self.backlight.write_text("0\n")
        self.assertEqual(k.wait(10), 0)
        self.assertIsNone(self.session())
        self.assertIn("the screen went off", self.preboot_log())
        self.assertIn("holder exit", self.lines())

    def test_early_ends_when_steam_exits_and_gap(self):
        self.first_launch()
        env = dict(self.env, POWOS_WINE_PREBOOT="1")
        k = self.early(env)
        self.wait_state("up")
        self.steam_proc.kill()
        self.steam_proc.wait()
        self.assertEqual(k.wait(10), 0)
        self.assertIn("Steam exited", self.preboot_log())
        self.steam_proc = subprocess.Popen(["sleep", "60"])
        (self.t / "steam.pid").write_text("%d\n" % self.steam_proc.pid)
        self.assertEqual(self.early(env).wait(10), 0)  # screen on again at once: one early boot per gap
        self.assertIn("early: skipped, an early pre-boot", self.preboot_log())
        self.assertIsNone(self.session())


class MappedTool(unittest.TestCase):
    """config.vdf's CompatToolMapping: the game's entry is found wherever it sits in the block (11-12: Broforce after
    346010/294100 read as None - a lazy regex stopped at the first app's closing brace)."""

    def test_app_after_others(self):
        sys.path.insert(0, str(PKG))
        import powos_preboot
        d = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(d, "config"))
            vdf = ('"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n'
                   '\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n'
                   '\t\t\t\t\t"346010"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"proton_experimental"\n\t\t\t\t\t}\n'
                   '\t\t\t\t\t"294100"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"proton_9"\n\t\t\t\t\t}\n'
                   '\t\t\t\t\t"274190"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"powos-proton-arm64"\n\t\t\t\t\t}\n'
                   '\t\t\t\t}\n\t\t\t\t"ShaderCacheSize"\n\t\t\t\t{\n\t\t\t\t\t"274190"\n\t\t\t\t\t{\n'
                   '\t\t\t\t\t\t"name"\t\t"wrong-block"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n')
            Path(d, "config/config.vdf").write_text(vdf)
            self.assertEqual(powos_preboot.mapped_tool(APP, d), "powos-proton-arm64")
            self.assertEqual(powos_preboot.mapped_tool("346010", d), "proton_experimental")
            self.assertIsNone(powos_preboot.mapped_tool("999", d))
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main(verbosity=2)
