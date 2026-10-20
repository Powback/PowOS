#!/usr/bin/env python3
"""
Tests for lib/apps/powos-autosleep and lib/apps/powos-sleep-common - idle containers sleep and wake on demand
(docs/PHONE-KERNEL-CONTAINERS.md section 13).

Sleeping and waking for real (the cgroup freezer, pidfd_getfd, the stop-mode proxy) only happens on the phone
(the test there is in section 13.5). Here, without one:
- the shared rule surface: durations, the manifest key, the never-sleep list, label round trips
- run flags: --rm containers only pause, hibernate pauses (no CRIU on the phone), never
- which rule a container gets: never list > autosleep set > its label > the default (phone on, desktop off)
- powos-runtime's container mode turns the manifest key into run flags; parse_run carries the flags to cmd_run
- the watcher's decision: busy (cpu, a connection, an exec session) resets the idle clock; idle long enough sleeps;
  a device trigger shortens the idle time
- /proc/net/tcp addresses become bindable hosts for the stop-mode proxy
"""

import os
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest.mock import patch

_APPS = Path(__file__).parent.parent.parent / "lib" / "apps"


def _load(name, file):
    loader = SourceFileLoader(name, str(_APPS / file))
    m = module_from_spec(spec_from_loader(name, loader))
    sys.modules[name] = m  # powos-container hands itself to powos-autosleep through sys.modules
    loader.exec_module(m)
    return m


pc = _load("powos_container", "powos-container")
asl = pc.autosleep()
common = asl.common
rt = _load("powos_runtime", "powos-runtime")


class Common(unittest.TestCase):
    def test_durations(self):
        self.assertEqual([common.seconds(x) for x in ("30s", "5m", "6h", "1d", "90")], [30, 300, 21600, 86400, 90])
        with self.assertRaises(ValueError):
            common.seconds("soon")
        self.assertEqual([common.fmt(x) for x in (30, 300, 21600, 90)], ["30s", "5m", "6h", "90s"])

    def test_manifest_key(self):
        self.assertIsNone(common.from_manifest(None))
        self.assertEqual(common.from_manifest("never"), {"never": True})
        self.assertEqual(common.from_manifest(False), {"never": True})
        self.assertEqual(common.from_manifest({"idle": "10m", "mode": "hibernate", "stop": "6h"}),
                         {"idle": 600, "mode": "hibernate", "stop": 21600})
        self.assertEqual(common.from_manifest({}), common.DEFAULT)
        with self.assertRaises(ValueError):
            common.from_manifest({"mode": "nap"})

    def test_never_list(self):
        for n in ("spacetimedb", "powos-app-dev.powos.spacetimedb", "comms", "agentsd", "my-comms-relay"):
            self.assertTrue(common.is_never(n), n)
        for n in ("sleeptest", "communicator", "powos-app-dev.powos.counter"):
            self.assertFalse(common.is_never(n), n)

    def test_label_round_trip(self):
        for r in ({"never": True}, {"idle": 20, "mode": "stop", "stop": 0}, {"idle": 300, "mode": "pause", "stop": 9}):
            self.assertEqual(common.decode(common.encode(r)), r)
        self.assertIsNone(common.decode(""))


class Flags(unittest.TestCase):
    def test_rule_from_flags(self):
        self.assertIsNone(asl.rule_from_flags({}))
        self.assertEqual(asl.rule_from_flags({"as_idle": "never"}), {"never": True})
        self.assertEqual(asl.rule_from_flags({"as_idle": "20s", "as_mode": "stop"}),
                         {"idle": 20, "mode": "stop", "stop": 0})
        with patch.object(pc, "warn") as w:
            self.assertEqual(asl.rule_from_flags({"as_idle": "1m", "as_mode": "stop", "as_stop": "1h"}, rm=True),
                             {"idle": 60, "mode": "pause", "stop": 0})
            self.assertEqual(asl.rule_from_flags({"as_mode": "hibernate"})["mode"], "pause")
        self.assertEqual(w.call_count, 2)

    def test_parse_run_carries_them(self):
        name, lim, rest, _ = pc.parse_run(["--name", "x", "--autosleep", "5m", "--sleep-mode=stop", "-d", "alpine"])
        self.assertEqual((lim.get("as_idle"), lim.get("as_mode")), ("5m", "stop"))
        self.assertEqual(rest, ["-d", "alpine"])

    def test_runtime_container_mode(self):
        m = {"id": "dev.powos.t", "backend": {"exec": ["/usr/bin/x"]}, "needs": {},
             "budget": {"default": {"memMB": 64}}, "autosleep": {"idle": "30s", "mode": "pause"}}
        pw = type("pw", (), {"pw_uid": 1000, "pw_gid": 1000, "pw_name": "powos"})
        with patch.object(rt, "device", return_value="desktop"), \
                patch.object(rt, "CONTAINER", str(_APPS / "powos-container")):
            s = " ".join(rt.container_argv(m, "/d", ["/usr/bin/x"], {}, pw))
            self.assertIn("--autosleep 30 --sleep-mode pause", s)
            m["autosleep"] = "never"
            self.assertIn("--autosleep never", " ".join(rt.container_argv(m, "/d", ["/usr/bin/x"], {}, pw)))
            del m["autosleep"]
            self.assertNotIn("--autosleep", " ".join(rt.container_argv(m, "/d", ["/usr/bin/x"], {}, pw)))


class Rules(unittest.TestCase):
    def test_precedence(self):
        with patch.object(pc, "PHONE", True):
            self.assertTrue(asl.effective_rule("comms", "idle=5,mode=pause,stop=0", {})[0]["never"])
            r, why = asl.effective_rule("a", "idle=5,mode=pause,stop=0", {"a": {"never": True}})
            self.assertEqual((r, why), ({"never": True}, "autosleep set"))
            self.assertEqual(asl.effective_rule("a", "idle=5,mode=stop,stop=0", {})[0]["idle"], 5)
            self.assertEqual(asl.effective_rule("a", "", {}), (common.DEFAULT, "default"))
        with patch.object(pc, "PHONE", False):
            self.assertTrue(asl.effective_rule("a", "", {})[0]["never"])  # desktop: only with --autosleep


class Decision(unittest.TestCase):
    """Watcher.check() with the process table, sockets and sleeping stubbed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.patches = [patch.object(asl, "STATE", f"{self.tmp.name}/state.json"), patch.object(pc, "PHONE", True),
                        patch.object(asl, "frozen", return_value=False)]
        for p in self.patches:
            p.start()
        self.w = asl.Watcher(base=["podman"])
        self.slept = []
        self.w.sleep = lambda name, c, rule, table, why, now: self.slept.append((name, why)) or True
        self.w.conns = lambda init, pids: self.n_conns
        self.n_conns = 0
        self.rule = {"idle": 60, "mode": "pause", "stop": 0}
        self.c = {"pid": 10, "label": "", "rm": False}

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def run_at(self, now, ticks, trig=()):
        table = {10: (1, ticks, "ns1"), 11: (10, 0, "ns1")}
        with patch.object(asl, "members", return_value={10, 11}):
            return self.w.check("app", self.c, self.rule, "its rule", list(trig), table, now)

    def test_idle_then_sleep(self):
        self.assertEqual(self.run_at(0, 100)["activity"], "first look")
        self.run_at(30, 100)
        self.assertEqual(self.slept, [])
        self.run_at(91, 100)  # idle since the first look at 0
        self.assertEqual(self.slept, [("app", "idle 91s")])

    def test_busy_resets(self):
        self.run_at(0, 100)
        self.run_at(30, 100)
        self.assertIn("cpu", self.run_at(60, 100 + 30 * asl.CLK)["activity"])  # a whole core
        self.n_conns = 1
        self.assertEqual(self.run_at(200, 100 + 30 * asl.CLK)["activity"], "1 connection(s)")
        self.assertEqual(self.slept, [])

    def test_trigger_shortens(self):
        self.rule["idle"] = 3600
        self.run_at(0, 5)
        self.run_at(30, 5, ["screen off 3m"])
        self.run_at(95, 5, ["screen off 4m"])
        self.assertEqual(len(self.slept), 1)
        self.assertIn("screen off", self.slept[0][1])

    def test_never(self):
        self.rule = {"never": True}
        for t in (0, 1000, 5000):
            self.assertEqual(self.run_at(t, 1)["state"], "awake")
        self.assertEqual(self.slept, [])


class Addresses(unittest.TestCase):
    def test_ip_of(self):
        self.assertEqual(asl.ip_of("0100007F"), "127.0.0.1")
        self.assertEqual(asl.ip_of("00000000"), "")
        self.assertEqual(asl.ip_of("00000000000000000000000000000000"), "")
        self.assertEqual(asl.ip_of("0000000000000000FFFF00000100007F"), "127.0.0.1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
