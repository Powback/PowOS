#!/usr/bin/env python3
"""powos-open-task: Steam's dialogs are told by what they are, not their "Steam Dialog" caption (gone since 11-07: every
steamwebhelper window is nameless), and a launch Steam already holds waiting on the user is found in its console_log -
ABZU 11-07 15:44: the cloud sync question ("syncfailed") stayed behind home and four later taps showed nothing.
The window props below are the phone's, recorded 11-07 22:42 with xprop while that question was up."""
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
import time
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2] / "targets/android/session/powos-open-task"


def load():
    loader = importlib.machinery.SourceFileLoader("powos_open_task_dialog", str(SOURCE))
    spec = importlib.util.spec_from_loader("powos_open_task_dialog", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


mod = load()

# (caption, resourceName, resourceClass, fixed = min size == max size, transient) as KWin's report script sends them.
MAIN = ("", "steamwebhelper", "steam", "0", "0")  # WM_NORMAL_HINTS min 2268x1350, no max; RESIZE allowed
SYNC_QUESTION = ("", "steamwebhelper", "steam", "1", "0")  # min = max 1364x646, nameless, no transient-for
SYNC_PROGRESS = ("", "steamwebhelper", "steam", "1", "0")  # min = max 1350x644
TRANSIENT = ("", "steamwebhelper", "steam", "0", "1")
OLD_CAPTION = ("Steam Dialog", "steamwebhelper", "steam", "0", "0")  # before 11-07
GAME = ("ABZU", "abzugame-win64-shipping.exe", "steam_app_384190", "1", "0")  # a fixed-size game window
UPDATER = ("Steam", "steam", "steam", "1", "0")  # the client's bootstrap, not its web UI


class SteamDialog(unittest.TestCase):
    def test_nameless_fixed_size_webhelper_is_a_dialog(self):
        self.assertTrue(mod.steam_dialog(*SYNC_QUESTION))
        self.assertTrue(mod.steam_dialog(*SYNC_PROGRESS))
        self.assertTrue(mod.steam_dialog(*TRANSIENT))
        self.assertTrue(mod.steam_dialog(*OLD_CAPTION))

    def test_main_window_and_other_windows_are_not(self):
        self.assertFalse(mod.steam_dialog(*MAIN))
        self.assertFalse(mod.steam_dialog(*GAME))
        self.assertFalse(mod.steam_dialog(*UPDATER))

    def test_report_script_sends_fixed_and_transient(self):
        self.assertIn("w.minSize", mod.REPORT_SCRIPT)
        self.assertIn("w.transient", mod.REPORT_SCRIPT)


LOG_HELD = b"""[2026-11-07 15:43:59] GameAction [AppID 384190, ActionID 3] : LaunchApp changed task to ProcessingInstallScript with ""
[2026-11-07 15:43:59] GameAction [AppID 274190, ActionID 2] : LaunchApp changed task to Completed with ""
[2026-11-07 15:43:59] GameAction [AppID 384190, ActionID 3] : LaunchApp changed task to SynchronizingCloud with ""
[2026-11-07 15:44:19] GameAction [AppID 384190, ActionID 3] : LaunchApp waiting for user response to SynchronizingCloud "syncfailed"\r
[2026-11-07 15:50:00] something else
"""
LOG_ANSWERED = LOG_HELD + b"""[2026-11-07 15:51:00] GameAction [AppID 384190, ActionID 3] : LaunchApp continues with user response "SynchronizingCloud"
[2026-11-07 15:51:00] GameAction [AppID 384190, ActionID 3] : LaunchApp changed task to CreatingProcess with ""
"""


class HeldAsk(unittest.TestCase):
    def held(self, data, game="384190", since=None):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "console_log.txt")
            pathlib.Path(p).write_bytes(data)
            return mod.held_ask(game, p, since)

    def test_held_launch_found(self):
        self.assertEqual(self.held(LOG_HELD), ("3", 'SynchronizingCloud "syncfailed"'))

    def test_answered_or_other_game_is_not_held(self):
        self.assertIsNone(self.held(LOG_ANSWERED))
        self.assertIsNone(self.held(LOG_HELD, game="274190"))
        self.assertIsNone(self.held(LOG_HELD, game="1"))

    def test_line_from_before_this_steam_started_is_stale(self):
        t = time.mktime(time.strptime("2026-11-07 15:44:19", "%Y-%m-%d %H:%M:%S"))
        self.assertIsNotNone(self.held(LOG_HELD, since=t - 60))
        self.assertIsNone(self.held(LOG_HELD, since=t + 600))

    def test_young_wait_is_not_held_yet(self):
        # An ordinary launch's own "waiting for user response to ShowInterstitials/CreatingProcess" is continued within
        # the second, and Steam's "Launching..." popup (nameless, fixed 1350x644, Broforce 11-08 02:29) is up meanwhile:
        # no question until the wait is ASK_HELD_S old.
        t = time.mktime(time.strptime("2026-11-07 15:44:19", "%Y-%m-%d %H:%M:%S"))
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "console_log.txt")
            pathlib.Path(p).write_bytes(LOG_HELD)
            self.assertIsNone(mod.held_ask("384190", p, min_age=mod.ASK_HELD_S, now=t + 1))
            self.assertEqual(mod.held_ask("384190", p, min_age=mod.ASK_HELD_S, now=t + 3)[0], "3")

    def test_nameless_dialog_waits_for_a_held_launch(self):
        src = SOURCE.read_text()
        self.assertIn("watch_ask()", src)
        self.assertIn("min_age=ASK_HELD_S", src)

    def test_no_log(self):
        self.assertIsNone(mod.held_ask("384190", "/nonexistent/console_log.txt"))


if __name__ == "__main__":
    unittest.main()
