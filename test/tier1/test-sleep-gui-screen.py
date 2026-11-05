#!/usr/bin/env python3
"""powos-sleep-gui's Screen: PowOS is on screen only while some surface has BOTH its consumer (an Activity showing it)
and its producer (KWin's export). A window task whose window closed keeps its consumer with nothing on it - counted,
it held PowOS "on screen" all session and a game left for home was never frozen (2026-11-05, bf-return 11:47)."""
from importlib.machinery import SourceFileLoader
import importlib.util
from pathlib import Path
import sys
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


if __name__ == "__main__":
    unittest.main()
