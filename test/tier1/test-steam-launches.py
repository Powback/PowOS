#!/usr/bin/env python3
"""powos-sleep-gui's SteamLaunches (SL1, the user 11-07: "if steam is launching a game why arent we seeing the
splashscreen app placeholder window thing we made?"): every game launch Steam runs - PowOS's tap and Steam's own UI
alike - announced to the phone shell the moment it starts, from Steam's console_log, as RUN/running/launches.json with
its phases; a launch that ends before its window says so; an old log is not replayed."""
from importlib.machinery import SourceFileLoader
import importlib.util
from pathlib import Path
import json
import sys
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[2]
TIMERS = []


def load():
    dbus = types.ModuleType("dbus")
    dbus.service = types.ModuleType("dbus.service")
    dbus.service.Object = object
    dbus.service.method = lambda *a, **k: (lambda f: f)
    dbus.service.signal = lambda *a, **k: (lambda f: f)
    dbus.DBusException = Exception
    glib = types.ModuleType("dbus.mainloop.glib")
    glib.DBusGMainLoop = lambda **k: None
    gi = types.ModuleType("gi")
    gi.repository = types.ModuleType("gi.repository")
    gi.repository.GLib = types.SimpleNamespace(timeout_add_seconds=lambda s, f, *a: TIMERS.append((s, f, a)) or 0,
                                               io_add_watch=lambda *a: 0, PRIORITY_DEFAULT=0, IO_IN=1)
    sys.modules.update({"dbus": dbus, "dbus.service": dbus.service, "dbus.mainloop": types.ModuleType("dbus.mainloop"),
                        "dbus.mainloop.glib": glib, "gi": gi, "gi.repository": gi.repository})
    if not hasattr(SourceFileLoader, "load_module"):
        def load_module(self, name=None):
            m = importlib.util.module_from_spec(importlib.util.spec_from_loader(self.name, self))
            self.exec_module(m)
            return m
        SourceFileLoader.load_module = load_module
    return SourceFileLoader("powos_sleep_gui", str(ROOT / "lib/apps/powos-sleep-gui")).load_module()


GUI = load()
A = "[2026-11-07 03:34:37] GameAction [AppID 384190, ActionID 20] : LaunchApp "
CMD = ('"/home/powos/.local/share/Steam/steamrtarm64/reaper SteamLaunch AppId=384190 -- /home/powos/.local/share/Steam/'
       "steamapps/common/Proton - Experimental'/proton waitforexitandrun '/x/Game.exe'\"")
# A real launch from Steam's UI (the phone, 11-07 03:34): no ExecuteSteamURL - Steam's library started it.
LAUNCH = [A + 'changed task to CheckShaderDepotManifest with ""', A + 'changed task to SynchronizingCloud with ""',
          A + 'changed task to ShowInterstitials with ""', A + 'waiting for user response to ShowInterstitials ""',
          A + 'continues with user response "ShowInterstitials"', A + 'changed task to CreatingProcess with ""']
ADDED = "[2026-11-07 03:34:39] Game process added : AppID 384190 " + CMD
UPDATED = "[2026-11-07 03:34:45] Game process updated : AppID 384190 " + CMD
DONE = [A + 'changed task to WaitingGameWindow with ""', A + 'changed task to Completed with ""']
REMOVED = "[2026-11-07 03:35:44] Game process removed: AppID 384190 " + CMD


class SteamLaunches(unittest.TestCase):
    def setUp(self):
        TIMERS.clear()
        self.dir = tempfile.TemporaryDirectory()
        d = Path(self.dir.name)
        (d / "Steam/logs").mkdir(parents=True)
        (d / "Steam/steamapps").mkdir()
        (d / "lib/steamapps").mkdir(parents=True)
        (d / "Steam/steamapps/libraryfolders.vdf").write_text(f'"libraryfolders"\n{{\n\t"1"\n\t{{\n\t\t"path"\t\t"{d}/lib"\n\t}}\n}}\n')
        (d / "lib/steamapps/appmanifest_384190.acf").write_text('"AppState"\n{\n\t"appid"\t\t"384190"\n\t"name"\t\t"Tails of Iron"\n}\n')
        (d / "running").mkdir()
        self.log, self.out = d / "Steam/logs/console_log.txt", d / "running/launches.json"
        self.log.write_text(A.replace("ActionID 20", "ActionID 3") + 'changed task to CreatingProcess with ""\n')
        s = object.__new__(GUI.SteamLaunches)
        s.out_dir, s.steam, s.launches, s.written, s.skip = str(d / "running"), str(d / "Steam"), {}, None, True
        s.path, s.pos, s.ino, s.known, s.started = str(self.log), 0, None, False, True
        self.s = s
        s.read()  # the first look: the old log is skipped

    def tearDown(self):
        self.dir.cleanup()

    def write(self, *lines):
        with self.log.open("a") as f:
            f.write("".join(l + "\n" for l in lines))
        self.s.read()
        return json.loads(self.out.read_text())["launches"] if self.out.exists() else {}

    def test_old_log_not_replayed(self):
        self.assertFalse(self.out.exists(), "a launch from before the watcher started must not show a placeholder")

    def test_steam_ui_launch_announced_at_its_first_step(self):
        out = self.write(LAUNCH[0])
        l = out["384190"]
        self.assertEqual((l["state"], l["phase"], l["name"]), ("launching", "Getting ready", "Tails of Iron"))
        self.assertTrue(l["since"] > 0)
        self.assertEqual(self.write(LAUNCH[1])["384190"]["phase"], "Syncing saves")

    def test_phases_to_the_game_process(self):
        self.write(*LAUNCH)
        out = self.write(ADDED, *DONE)
        self.assertEqual((out["384190"]["state"], out["384190"]["phase"]), ("running", "Starting Proton"))
        self.assertEqual(self.write(UPDATED)["384190"]["phase"], "Loading")

    def test_a_quick_answer_is_no_question(self):
        self.write(*LAUNCH[:4])
        s, f, a = TIMERS[-1]
        self.write(LAUNCH[4])
        f(*a)
        self.assertEqual(json.loads(self.out.read_text())["launches"]["384190"]["state"], "launching")

    def test_a_question_left_waiting_is_asking(self):
        self.write(*LAUNCH[:4])
        s, f, a = TIMERS[-1]
        self.assertEqual(s, GUI.SteamLaunches.ASK_S)
        f(*a)
        self.assertEqual(json.loads(self.out.read_text())["launches"]["384190"]["state"], "asking")
        self.assertEqual(self.write(LAUNCH[4])["384190"]["state"], "launching")

    def test_closed_before_its_window(self):
        self.write(*LAUNCH, ADDED)
        l = self.write(REMOVED)["384190"]
        self.assertEqual(l["state"], "ended")
        self.assertIn("closed before", l["reason"])

    def test_steam_failure_says_why(self):
        l = self.write(LAUNCH[0], A + 'failed with AppError_19 with ""', A + 'changed task to Failed with ""')["384190"]
        self.assertEqual(l["state"], "ended")
        self.assertIn("AppError_19", l["reason"])

    def test_ended_dropped_later(self):
        self.write(*LAUNCH, ADDED, REMOVED)
        self.s.publish(now=self.s.launches["384190"]["ended"] + GUI.SteamLaunches.ENDED_S + 1)
        self.assertEqual(json.loads(self.out.read_text())["launches"], {})

    def test_rotated_log_read_from_its_start(self):
        self.log.unlink()
        self.log.write_text(LAUNCH[0] + "\n")
        self.s.ino = None  # LogTail.event on IN_DELETE_SELF / IN_MOVE_SELF (the inode number may come back)
        self.s.read()
        self.assertEqual(json.loads(self.out.read_text())["launches"]["384190"]["state"], "launching")

    def test_native_game(self):
        out = self.write(LAUNCH[0], "[x] Game process added : AppID 384190 \"/r/reaper SteamLaunch AppId=384190 -- /g/game.x86_64\"")
        self.assertEqual(out["384190"]["phase"], "Starting")


if __name__ == "__main__":
    unittest.main()
