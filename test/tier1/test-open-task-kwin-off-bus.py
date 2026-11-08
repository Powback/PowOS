#!/usr/bin/env python3
"""powos-open-task: a KWin that runs but isn't on the session bus (the bus restarted under it - the phone 11-08 16:10)
never comes onto it. The helper must start COMMAND at once (KWin still exports the window itself, so it becomes home's
web window), not say "desktop" and wait 30 s (every launch then brought the Plasma desktop up and the window opened in
it: "it just opens the version on the Plasma desktop instead of as an app natively")."""
import importlib.machinery
import importlib.util
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2] / "targets/android/session/powos-open-task"


def load(run):
    os.environ["XDG_RUNTIME_DIR"] = run
    loader = importlib.machinery.SourceFileLoader("powos_open_task", str(SOURCE))
    spec = importlib.util.spec_from_loader("powos_open_task", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class KWinOffBus(unittest.TestCase):
    def test_kwin_running_since_finds_our_kwin_by_age(self):
        with tempfile.TemporaryDirectory() as run:
            mod = load(run)
            fake = os.path.join(run, "kwin_wayland")
            shutil.copy(shutil.which("sleep"), fake)
            p = subprocess.Popen([fake, "30"])
            try:
                time.sleep(0.3)
                self.assertEqual(mod.kwin_running_since(0), p.pid)
                # A KWin that just started (still registering on the bus) doesn't count as one off the bus.
                self.assertIsNone(mod.kwin_running_since(10 ** 9))
            finally:
                p.kill()
                p.wait()

    def test_begin_starts_the_command_when_kwin_is_off_the_bus(self):
        src = SOURCE.read_text()
        begin = src[src.index("    def begin():"):src.index("    begin()\n")]
        lost = begin.index("kwin_off_bus()")
        # Checked before the "KWin isn't up yet" wait, and it starts COMMAND then and there.
        self.assertLess(lost, begin.index("KWin isn't up yet"))
        self.assertIn("start_command()", begin[lost:begin.index("KWin isn't up yet")])
        self.assertIn('"NameHasOwner"', src)


if __name__ == "__main__":
    unittest.main()
