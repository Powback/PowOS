#!/usr/bin/env python3
"""powos-open-task: COMMAND's output goes to its own log, never the caller's pipe (Broforce 2026-11-03: a Steam client
cold-started through it kept the PowOS app's pipe; after the app's update restart nobody read it and every game Steam
launched next ended ~10 s in). The relay still hands the output to the caller while the helper runs."""
import importlib.machinery
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2] / "targets/android/session/powos-open-task"


def load(run):
    os.environ["XDG_RUNTIME_DIR"] = run
    loader = importlib.machinery.SourceFileLoader("powos_open_task", str(SOURCE))
    spec = importlib.util.spec_from_loader("powos_open_task", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class OpenTaskOutput(unittest.TestCase):
    def test_child_outlives_a_dead_caller_pipe(self):
        with tempfile.TemporaryDirectory() as run:
            mod = load(run)
            fd, path = mod.output_log("steam_app_274190")
            self.assertEqual(path, os.path.join(run, "open-task", "steam_app_274190.log"))
            # The caller's pipe, its reader gone (the app restarted): the child must not write to it.
            r, w = os.pipe()
            os.close(r)
            child = subprocess.Popen(["/bin/bash", "-c", "sleep 0.2; for i in 1 2 3; do echo line$i; done; echo err >&2"],
                                     stdout=fd, stderr=fd, start_new_session=True, pass_fds=(w,))
            os.close(fd)
            self.assertEqual(child.wait(5), 0)
            self.assertEqual(pathlib.Path(path).read_text(), "line1\nline2\nline3\nerr\n")

    def test_relay_forwards_only_this_launch_and_append_keeps_old_writers(self):
        with tempfile.TemporaryDirectory() as run:
            mod = load(run)
            fd, path = mod.output_log("x")
            os.write(fd, b"earlier launch\n")
            relay = mod.OutputRelay(path)
            fd2, _ = mod.output_log("x")
            os.write(fd2, b"this launch\n")
            os.write(fd, b"old steam still writing\n")  # O_APPEND: no overwrite, no hole
            r, w = os.pipe()
            saved = os.dup(1)
            os.dup2(w, 1)
            try:
                relay.pump()
            finally:
                sys.stdout.flush()
                os.dup2(saved, 1)
                os.close(w)
            self.assertEqual(os.read(r, 4096), b"this launch\nold steam still writing\n")
            self.assertIn(b"earlier launch\nthis launch\nold steam", pathlib.Path(path).read_bytes())

    def test_big_log_restarts(self):
        with tempfile.TemporaryDirectory() as run:
            mod = load(run)
            fd, path = mod.output_log("y")
            os.write(fd, b"x" * (mod.OUTPUT_KEEP + 1))
            os.close(fd)
            fd, _ = mod.output_log("y")
            os.close(fd)
            self.assertEqual(os.path.getsize(path), 0)


if __name__ == "__main__":
    unittest.main()
