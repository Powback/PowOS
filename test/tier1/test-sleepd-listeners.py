#!/usr/bin/env python3
"""
powos-sleepd gives back a backend's listening socket when a sleep fails (lib/apps/powos-sleepd sleep_service).

pause/hibernate borrow the backend's listeners (pidfd_getfd) before freezing it. When the freeze fails - on the phone
every native service whose processes powos-runtime put in Android's cgroups ("nothing movable") - the borrowed copies
used to stay open in powos-sleepd, one more per failed attempt. After the backend exited (a system-tier restart) the
port stayed LISTEN in powos-sleepd: the new backend failed to bind (EADDRINUSE) and every client hung in a backlog
nobody accepted (App API on 127.0.0.1:3411, 2026-10-23). Here: a real listening socket stands in for the backend's,
the borrow and the freeze are faked; after the failed sleep the port binds again.
"""

import os
import selectors
import socket
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest.mock import patch

_APPS = Path(__file__).parent.parent.parent / "lib" / "apps"


def _load():
    loader = SourceFileLoader("powos_sleepd", str(_APPS / "powos-sleepd"))
    mod = module_from_spec(spec_from_loader("powos_sleepd", loader))
    loader.exec_module(mod)
    return mod


sleepd = _load()


class FailedSleepReleasesPort(unittest.TestCase):
    def setUp(self):
        self.backend = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.backend.bind(("127.0.0.1", 0))
        self.backend.listen(5)
        self.port = self.backend.getsockname()[1]
        d = object.__new__(sleepd.Daemon)
        d.sel = selectors.DefaultSelector()
        d.publish = lambda: None
        self.d = d
        self.svc = sleepd.Service({"id": "app-api", "backend": {}, "needs": {"listen": [f"127.0.0.1:{self.port}"]}})

    def tearDown(self):
        self.d.sel.close()

    def fail_sleep(self):
        borrowed = lambda _pid, _ports: [os.dup(self.backend.fileno())]  # noqa: E731 - pidfd_getfd's copy
        nothing = OSError("nothing movable (its processes are in Android's cgroups)")
        with patch.object(sleepd, "borrow_listeners", borrowed), \
                patch.object(sleepd.Frozen, "freeze", side_effect=nothing), \
                patch.object(sleepd.Frozen, "thaw", lambda self: None), \
                patch.object(sleepd, "log", lambda _m: None):
            self.d.sleep_service(self.svc, os.getpid(), "idle 5m")

    def test_port_free_after_failed_sleeps_and_backend_exit(self):
        for _ in range(4):  # the phone's count: four failed attempts before the restart
            self.fail_sleep()
        self.assertEqual(self.svc.fds, [])
        self.assertEqual(self.svc.state, "awake")
        self.assertIn("couldn't sleep", self.svc.why)
        self.backend.close()  # the supervisor stops the backend
        again = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            again.bind(("127.0.0.1", self.port))  # its next start: EADDRINUSE before the fix
            again.listen(5)
        finally:
            again.close()

    def test_wake_releases_too(self):
        self.svc.fds = [os.dup(self.backend.fileno())]
        self.d.sel.register(self.svc.fds[0], selectors.EVENT_READ, ("listener", self.svc.id))
        self.d.kick_supervisor = lambda: None
        with patch.object(sleepd, "log", lambda _m: None), patch.object(sleepd, "STOPPED", "/nonexistent-powos-test"):
            self.d.wake_service(self.svc, "a connection")
        self.assertEqual(self.svc.fds, [])
        self.assertEqual(len(self.d.sel.get_map()), 0)


if __name__ == "__main__":
    unittest.main()
