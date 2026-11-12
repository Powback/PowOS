#!/usr/bin/env python3
"""powos-sleep-gui's Screen: PowOS is on screen only while some surface has BOTH its consumer (an Activity showing it)
and its producer (KWin's export). A window task whose window closed keeps its consumer with nothing on it - counted,
it held PowOS "on screen" all session and a game left for home was never frozen (2026-11-05, bf-return 11:47)."""
from importlib.machinery import SourceFileLoader
import importlib.util
from pathlib import Path
import json
import sys
import time
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load():
    # The module imports dbus and GLib at the top; the Screen logic needs neither.
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
    gi.repository.GLib = types.SimpleNamespace(timeout_add_seconds=lambda *a: 0, io_add_watch=lambda *a: 0)
    sys.modules.update({"dbus": dbus, "dbus.service": dbus.service, "dbus.mainloop": types.ModuleType("dbus.mainloop"),
                        "dbus.mainloop.glib": glib, "gi": gi, "gi.repository": gi.repository})
    if not hasattr(SourceFileLoader, "load_module"):  # gone in Python 3.13 (the module loads its common file so)
        def load_module(self, name=None):
            m = importlib.util.module_from_spec(importlib.util.spec_from_loader(self.name, self))
            self.exec_module(m)
            return m
        SourceFileLoader.load_module = load_module
    return SourceFileLoader("powos_sleep_gui", str(ROOT / "lib/apps/powos-sleep-gui")).load_module()


GUI = load()


class Screen(unittest.TestCase):
    def screen(self, path):
        s = object.__new__(GUI.Screen)
        s.path, s.changes = str(path), []
        s.on_change = s.changes.append
        s.pos, s.ino, s.known, s.started = 0, None, False, True
        s.clear()
        return s

    def test_window_task_without_its_window_is_off_screen(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "andromarchy.log"
            log.write_text("daemon: listening on @powos.display\n"
                           "daemon: surface 0: producer connected\n"
                           "daemon: surface 53: producer connected\n"
                           "daemon: surface 53: consumer connected, 5 fds\n")
            s = self.screen(log)
            s.read()
            self.assertTrue(s.on)
            # The window closed: its task's consumer stays connected, showing nothing.
            with log.open("a") as f:
                f.write("daemon: surface 53: producer disconnected\n")
            s.read()
            self.assertFalse(s.on, "a task with no window must not hold PowOS on screen")
            # The game's own task: on screen, then home (its consumer goes) -> off screen, so the game can sleep.
            with log.open("a") as f:
                f.write("daemon: surface 62: producer connected\ndaemon: surface 62: consumer connected, 5 fds\n")
            s.read()
            self.assertTrue(s.on)
            with log.open("a") as f:
                f.write("daemon: surface 62: consumer disconnected\n")
            s.read()
            self.assertFalse(s.on)
            self.assertEqual(s.changes, [False, True, False])

    def test_desktop_shown_is_on_screen(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "andromarchy.log"
            log.write_text("daemon: listening on @powos.display\ndaemon: surface 0: producer connected\n"
                           "daemon: surface 0: consumer connected, 5 fds\n")
            s = self.screen(log)
            s.read()
            self.assertEqual(s.surfaces, {0})

    def test_new_daemon_forgets_old_surfaces(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "andromarchy.log"
            log.write_text("daemon: surface 5: producer connected\ndaemon: surface 5: consumer connected, 5 fds\n"
                           "daemon: listening on @powos.display\n")
            s = self.screen(log)
            s.read()
            self.assertFalse(s.on)


class LaunchHold(unittest.TestCase):
    """A launch path's Wake keeps the launcher awake LAUNCH_HOLD_S, also when it was awake already (Steam frozen 8 s
    into a launch that waited on its logon lost the forward, 2026-11-05 12:10), and a pending rungameid forward outside
    the client's tree refuses the freeze."""

    def gui(self):
        g = object.__new__(GUI.Gui)
        g.frozen, g.refused, g.idle_since, g.wins, g.tracked = {}, {}, {}, {}, {100: "steam"}
        g.schedule = lambda: None
        g.unit_of = lambda pid: {"id": "steam"} if pid == 100 else None
        return g

    def test_wake_of_an_awake_launcher_holds_it(self):
        g = self.gui()
        out = json.loads(g.Wake("steam"))
        self.assertTrue(out["awake"])
        until, why = g.refused[100]
        self.assertEqual(why, "launching")
        self.assertGreater(until, time.time() + GUI.LAUNCH_HOLD_S - 5)

    def test_hold_never_shortens_a_longer_refusal(self):
        g = self.gui()
        g.refused[100] = (time.time() + 3600, "never list")
        g.hold(100)
        self.assertGreater(g.refused[100][0], time.time() + 3000)

    def test_pending_launch_refuses_the_freeze(self):
        from unittest import mock
        g = self.gui()
        u = {"id": "steam", "classes": {"steam"}, "pidfile": None, "rule": {},
             "busy": {"games": "pause", "cmdline": "SteamLaunch"}}
        g.unit_of = lambda pid: u
        g.cls = lambda pid: "steam"
        refused = []
        g.refuse = lambda pid, why, retry=None: refused.append(why)
        cmd = {"100": "./steam -silent steam://rungameid/274190", "101": "steamwebhelper",
               "200": "/bin/bash /usr/bin/steam steam://rungameid/274190"}
        with mock.patch.object(GUI, "tree", lambda p: [100, 101]), \
                mock.patch.object(GUI, "cmdline", lambda p: cmd.get(str(p), "")), \
                mock.patch.object(GUI.os, "listdir", lambda d: list(cmd) + ["self"]):
            g.consider(100)
        self.assertTrue(refused and refused[0].startswith("a launch on its way (200"), refused)
        # The client's own command line (its tree) holding the URL is no pending launch.
        refused.clear()
        del cmd["200"]
        with mock.patch.object(GUI, "tree", lambda p: [100, 101]), \
                mock.patch.object(GUI, "cmdline", lambda p: cmd.get(str(p), "")), \
                mock.patch.object(GUI.os, "listdir", lambda d: list(cmd) + ["self"]), \
                mock.patch.object(GUI, "stat", lambda p: {"comm": "steam"}), \
                mock.patch.object(GUI.common, "is_never", lambda *a: True):
            g.consider(100)
        self.assertEqual(refused, ["never list"], "past the pending-launch check")


class LinkWatch(unittest.TestCase):
    """A frozen Steam whose CM link the server dropped (socket out of ESTABLISHED) is thawed to reconnect while PowOS is
    on screen, before the tap - not at the tap (12 s of Steam's reconnect backoff, bf-coldstart 2026-11-05 14:34)."""

    U = {"id": "steam", "classes": {"steam"}, "pidfile": "/x", "rule": {}, "busy": {"games": "pause", "cmdline": "SteamLaunch"}}

    def gui(self, on=True, frozen=True, frozen_for=0.0):
        g = object.__new__(GUI.Gui)
        g.frozen = {100: {"cls": "steam"}} if frozen else {}
        g.screen = types.SimpleNamespace(on=on)
        g.rules = lambda: [self.U]
        g.refused, g.calls = {}, []
        g.pulse_at = {100: time.monotonic() - frozen_for} if frozen else {}
        g.dark_since = None
        g.reconnect = lambda u, why: g.calls.append(("reconnect", why))
        g.thaw = lambda pid, why, quiet=False: (g.frozen.pop(pid, None), g.calls.append(("thaw", why, quiet)))
        g.freeze = lambda pid, cpu, quiet=False: (g.frozen.update({pid: {}}), g.calls.append(("freeze", quiet)))
        g.pid_active = lambda pid: False
        g.schedule = lambda: None
        return g

    def patched(self, link=1, cmd="./steam -silent"):
        from unittest import mock
        import contextlib
        st = contextlib.ExitStack()
        for name, f in (("unit_root", lambda u: 100), ("tree", lambda p: [100, 101]),
                        ("cmdline", lambda p: cmd if p == 100 else "steamwebhelper"), ("steam_link", lambda path: link),
                        ("display_on", lambda: self.lit)):
            st.enter_context(mock.patch.object(GUI, name, f))
        st.enter_context(mock.patch.object(GUI.GLib, "timeout_add", lambda ms, f, *a: self.timers.append((ms, f, a)),
                                           create=True))
        return st

    lit = False

    def run_watch(self, on=True, frozen=True, link=1, cmd="./steam -silent", frozen_for=0.0, lit=False):
        self.timers, self.lit = [], lit
        g = self.gui(on, frozen, frozen_for)
        with self.patched(link, cmd):
            self.assertTrue(g.link_watch())  # the GLib timer keeps running
        return [c[1] for c in g.calls if c[0] == "reconnect"]

    def test_dropped_link_thaws_to_reconnect(self):
        self.assertEqual(self.run_watch(), ["link dropped while frozen"])

    def test_live_link_stays_frozen(self):
        self.assertEqual(self.run_watch(link=0), [])
        self.assertEqual(self.run_watch(link=2), [])  # not trying (offline / logged off)

    def test_off_screen_waits_for_screen_on(self):
        self.assertEqual(self.run_watch(on=False), [])

    def test_android_home_lit_counts(self):  # the games widget on Android's home: PowOS off screen, display on
        self.assertEqual(self.run_watch(on=False, lit=True), ["link dropped while frozen"])

    def test_display_on_reads_the_backlights(self):
        with tempfile.TemporaryDirectory() as d:
            for name, v in (("panel0", "0"), ("panel1", "0")):
                Path(d, name).mkdir(); Path(d, name, "brightness").write_text(v)
            self.assertFalse(GUI.display_on(d + "/*/brightness"))
            Path(d, "panel1", "brightness").write_text("412\n")
            self.assertTrue(GUI.display_on(d + "/*/brightness"))
            self.assertTrue(GUI.display_on(d + "/none/*/brightness"))  # no backlight: a desktop

    def test_awake_or_running_a_game_is_left_alone(self):
        self.assertEqual(self.run_watch(frozen=False), [])
        self.assertEqual(self.run_watch(cmd="reaper SteamLaunch AppId=274190 -- x"), [])

    def test_live_link_pulsed_before_the_server_drops_it(self):
        self.timers = []
        g = self.gui(frozen_for=GUI.LINK_PULSE_S + 1)
        with self.patched(link=0):
            g.link_watch()
            self.assertEqual(g.calls, [("thaw", "link keepalive", True)])
            self.assertEqual([t[0] for t in self.timers], [GUI.LINK_PULSE_MS])
            ms, end, args = self.timers[0]
            with __import__("unittest").mock.patch.object(GUI.os.path, "isdir", lambda p: True):
                end(*args)
        self.assertEqual(g.calls[-1], ("freeze", True))
        self.assertIn(100, g.frozen)

    def test_pulse_left_awake_by_a_launch(self):
        self.timers = []
        g = self.gui(frozen_for=GUI.LINK_PULSE_S + 1)
        with self.patched(link=0):
            g.link_watch()
            g.refused[100] = (time.time() + 60, "launching")  # a launch's Wake during the pulse
            ms, end, args = self.timers[0]
            with __import__("unittest").mock.patch.object(GUI.os.path, "isdir", lambda p: True):
                end(*args)
        self.assertNotIn(100, g.frozen)

    def test_no_pulse_before_its_time(self):
        self.timers = []
        g = self.gui(frozen_for=5)
        with self.patched(link=0):
            g.link_watch()
        self.assertEqual(g.calls, [])

    def test_dark_screen_keeps_the_link_for_a_while(self):
        """Screen off, phone woken and a game tapped seconds later (bf-coldstart 11-11 23:28: Steam frozen 95 s in the
        dark, link dropped, the tap waited Steam's reconnect: handoff 9.6 s, frame 30.0 s vs 21.4 s live): the
        keepalive pulse runs in the dark too, within LINK_DARK_S of the screen going dark."""
        self.timers, self.lit = [], False
        g = self.gui(on=False, frozen_for=GUI.LINK_PULSE_S + 1)
        with self.patched(link=0):
            g.link_watch()
        self.assertEqual(g.calls, [("thaw", "link keepalive", True)])
        self.assertIsNotNone(g.dark_since)

    def test_dark_screen_past_its_window_costs_nothing(self):
        self.timers, self.lit = [], False
        g = self.gui(on=False, frozen_for=GUI.LINK_PULSE_S + 1)
        g.dark_since = time.time() - GUI.LINK_DARK_S - 1
        with self.patched(link=0):
            g.link_watch()
        self.assertEqual(g.calls, [])

    def test_lit_screen_restarts_the_dark_window(self):
        self.timers, self.lit = [], True
        g = self.gui(on=False, frozen_for=5)
        g.dark_since = time.time() - GUI.LINK_DARK_S - 1
        with self.patched(link=0):
            g.link_watch()
        self.assertIsNone(g.dark_since)



class PrebootAhead(unittest.TestCase):
    """PowOS on screen with Steam running asks powos_preboot.py `early` (the last-played game's Wine session booted
    before the tap; the keeper bounds it); no Steam / no keeper installed -> nothing spawned."""

    U = LinkWatch.U

    def run_ahead(self, root=100, installed=True):
        from unittest import mock
        g = object.__new__(GUI.Gui)
        g.rules = lambda: [self.U]
        spawned = []
        with mock.patch.object(GUI, "unit_root", lambda u: root), \
                mock.patch.object(GUI.os.path, "isfile", lambda p: installed), \
                mock.patch.object(GUI.subprocess, "Popen", lambda argv, **kw: spawned.append(argv) or
                                  types.SimpleNamespace(pid=1)), \
                mock.patch.object(GUI.GLib, "child_watch_add", lambda *a: None, create=True), \
                mock.patch.object(GUI.GLib, "PRIORITY_DEFAULT", 0, create=True):
            g.preboot_ahead()
        return spawned

    def test_steam_running_asks_early(self):
        self.assertEqual([a[1:] for a in self.run_ahead()], [[GUI.PREBOOT, "early"]])

    def test_no_steam_or_not_installed_spawns_nothing(self):
        self.assertEqual(self.run_ahead(root=None), [])
        self.assertEqual(self.run_ahead(installed=False), [])


if __name__ == "__main__":
    unittest.main()
