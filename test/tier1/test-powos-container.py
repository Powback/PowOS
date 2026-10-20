#!/usr/bin/env python3
"""
Tests for lib/apps/powos-container - PowOS's container runtime with hard limits in Android's cgroups
(docs/PHONE-KERNEL-CONTAINERS.md section 12).

The phone part can only really run on the phone (scripted there: targets/android/kernel/phone-test.sh containers).
What can go wrong without a phone is tested here, against fake cgroup trees in a temp dir:
- parse_run(): our limit flags are taken out, podman's own pass through, the image is found past value flags,
  --memory-swap defaults to 2x --memory, bad values are refused
- apply(): every limit lands in its file, the init pid in every group's cgroup.procs
- degrade: a kernel without CFS bandwidth gets cpu.shares (and a warning), one without pids gets no v2 group (and a
  warning) - never a refusal
- hook(): the OCI hook applies the annotation's limits, ignores containers that aren't ours, fails closed when a
  write fails
- powos-runtime's container mode: the budget becomes the limits, the data dir is bound at its own path, the app's
  uid, PowOS's own / read-only when the manifest names no image
"""

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest.mock import patch

_PATH = Path(__file__).parent.parent.parent / "lib" / "apps" / "powos-container"
_loader = SourceFileLoader("powos_container", str(_PATH))
pc = module_from_spec(spec_from_loader("powos_container", _loader))
_loader.exec_module(pc)


class FakeCgroups:
    """The four hierarchies in a temp dir, with the root files caps() looks for."""

    def __init__(self, cfs=True, pids=True):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.memcg, self.cpuctl, self.cpuset, self.v2 = (f"{t}/memcg", f"{t}/cpuctl", f"{t}/cpuset", f"{t}/v2")
        for d in (self.memcg, self.cpuctl, self.cpuset, self.v2):
            os.makedirs(d)
        self.put(self.memcg, "memory.limit_in_bytes", "9223372036854771712")
        self.put(self.memcg, "memory.memsw.limit_in_bytes", "9223372036854771712")
        self.put(self.cpuctl, "cpu.shares", "1024")
        if cfs:
            self.put(self.cpuctl, "cpu.cfs_quota_us", "-1")
        self.put(self.cpuset, "cpus", "0-7")
        self.put(self.cpuset, "mems", "0")
        self.put(self.v2, "cgroup.controllers", "pids" if pids else "")
        self.put(self.v2, "cgroup.subtree_control", "")
        self.patches = [patch.object(pc, "MEMCG", self.memcg), patch.object(pc, "CPUCTL", self.cpuctl),
                        patch.object(pc, "CPUSET", self.cpuset), patch.object(pc, "V2", self.v2)]

    @staticmethod
    def put(d, f, v):
        with open(f"{d}/{f}", "w") as fh:
            fh.write(v)

    @staticmethod
    def get(d, f):
        with open(f"{d}/{f}") as fh:
            return fh.read().strip()

    def __enter__(self):
        for p in self.patches:
            p.start()
        return self

    def __exit__(self, *a):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()


class ParseRun(unittest.TestCase):
    def test_limits_out_podman_flags_through(self):
        name, lim, rest, net = pc.parse_run(["--name", "web", "--memory", "64m", "--cpus=0.5", "--pids-limit", "32",
                                             "-d", "--rm", "-e", "A=1", "-v", "/a:/b", "-it", "alpine", "sh", "-c",
                                             "echo --memory 1g"])
        self.assertEqual(name, "web")
        self.assertEqual(lim, {"mem": 64 << 20, "memsw": 128 << 20, "cpus": "0.5", "pids": "32"})
        # The image is found past -e/-v values; the command's own "--memory" is the command's.
        self.assertEqual(rest, ["-d", "--rm", "-e", "A=1", "-v", "/a:/b", "-it", "alpine", "sh", "-c",
                                "echo --memory 1g"])
        self.assertIsNone(net)

    def test_swap_explicit_and_unlimited(self):
        self.assertEqual(pc.parse_run(["--memory", "1g", "--memory-swap", "1g", "img"])[1]["memsw"], 1 << 30)
        self.assertEqual(pc.parse_run(["-m", "1g", "--memory-swap=-1", "img"])[1]["memsw"], -1)

    def test_network_value_and_default_name(self):
        name, _, rest, net = pc.parse_run(["--network", "none", "img"])
        self.assertEqual(net, "none")
        self.assertTrue(name.startswith("powos-"))
        self.assertEqual(rest, ["--network", "none", "img"])

    def test_refusals(self):
        for bad in (["--memory", "64m", "--memory-swap", "32m", "img"], ["--memory-swap", "1g", "img"],
                    ["--cpus", "0", "img"], ["--pids-limit", "x", "img"], ["--cpuset-cpus", "a", "img"],
                    ["--name", "bad name", "img"], ["--memory", "64m"]):
            with self.subTest(bad=bad), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                pc.parse_run(bad)

    def test_sizes(self):
        self.assertEqual(pc.size("512k"), 512 << 10)
        self.assertEqual(pc.size("2G"), 2 << 30)
        self.assertEqual(pc.size("100"), 100)
        self.assertEqual(pc.size("-1"), -1)

    def test_annotation_roundtrip(self):
        lim = {"name": "a", "mem": 1, "cpus": "0.5"}
        self.assertEqual(pc.decode(pc.encode(lim)), {k: str(v) for k, v in lim.items()})


class Apply(unittest.TestCase):
    LIM = {"mem": 64 << 20, "memsw": 64 << 20, "cpus": "0.2", "cpuset": "0-2", "pids": "10"}

    def test_every_limit_and_the_pid(self):
        with FakeCgroups() as f:
            done = pc.apply("web", dict(self.LIM), pid=4242)
            g = pc.groups("web")
            self.assertEqual(f.get(g["memory"], "memory.limit_in_bytes"), str(64 << 20))
            self.assertEqual(f.get(g["memory"], "memory.memsw.limit_in_bytes"), str(64 << 20))
            self.assertEqual(f.get(g["cpu"], "cpu.cfs_quota_us"), "20000")
            self.assertEqual(f.get(g["cpu"], "cpu.cfs_period_us"), "100000")
            self.assertEqual(f.get(g["cpuset"], "cpus"), "0-2")
            self.assertEqual(f.get(f"{f.cpuset}/powos", "cpus"), "0-7")  # the parent: the whole phone's
            self.assertEqual(f.get(g["pids"], "pids.max"), "10")
            self.assertIn("+pids", f.get(f.v2, "cgroup.subtree_control"))
            for d in g.values():
                self.assertEqual(f.get(d, "cgroup.procs"), "4242")
            self.assertEqual(len(done), 4)

    def test_old_kernel_degrades(self):
        with FakeCgroups(cfs=False, pids=False) as f:
            pc.apply("web", dict(self.LIM), pid=7)
            g = pc.groups("web")
            self.assertEqual(f.get(g["cpu"], "cpu.shares"), "204")
            self.assertFalse(os.path.exists(f"{g['cpu']}/cpu.cfs_quota_us"))
            self.assertFalse(os.path.isdir(g["pids"]))
            notes = pc.degrade_notes(self.LIM, pc.caps())
            self.assertEqual(len(notes), 2)
            self.assertTrue(any(n.startswith("--cpus") and "cpu.shares=204" in n for n in notes))
            self.assertTrue(any(n.startswith("--pids-limit") for n in notes))

    def test_full_kernel_no_notes(self):
        with FakeCgroups():
            self.assertEqual(pc.degrade_notes(self.LIM, pc.caps()), [])

    def test_gc_removes_empty_groups_only(self):
        with FakeCgroups():
            pc.apply("idle", {"mem": 1 << 20}, pid=None)
            pc.apply("busy", {"mem": 1 << 20}, pid=99)
            # A fake dir isn't cgroupfs: rmdir needs it empty, so take the files out of the idle one first.
            d = pc.groups("idle")["memory"]
            for fn in os.listdir(d):
                os.unlink(f"{d}/{fn}")
            pc.gc()
            self.assertFalse(os.path.isdir(d))
            self.assertTrue(os.path.isdir(pc.groups("busy")["memory"]))


class Hook(unittest.TestCase):
    def run_hook(self, state, stage="create"):
        with patch("sys.stdin", io.StringIO(json.dumps(state))), patch.object(pc, "log"):
            pc.hook(stage)

    def test_applies_annotation(self):
        with FakeCgroups() as f:
            self.run_hook({"pid": 11, "annotations": {pc.ANNOT: "name=web,mem=1048576,memsw=-1,pids=5"}})
            self.assertEqual(f.get(pc.groups("web")["memory"], "memory.limit_in_bytes"), "1048576")
            self.assertEqual(f.get(pc.groups("web")["pids"], "cgroup.procs"), "11")

    def test_not_ours(self):
        with FakeCgroups() as f:
            self.run_hook({"pid": 11, "annotations": {"other": "x"}})
            self.assertFalse(os.path.isdir(f"{f.memcg}/powos"))

    def test_fails_closed(self):
        with FakeCgroups(), patch.object(pc, "wr", side_effect=OSError(22, "Invalid argument")):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.run_hook({"pid": 11, "annotations": {pc.ANNOT: "name=web,mem=1048576,memsw=-1"}})


class Help(unittest.TestCase):
    def test_every_verb_in_help_dispatches(self):
        doc = pc.__doc__.replace("stop|start|restart", "stop powos containers start powos containers restart")
        src = _PATH.read_text()
        for verb in ("run", "ps", "exec", "stop", "start", "restart", "rm", "limits", "check", "podman"):
            self.assertIn(f"powos containers {verb} ", doc)
            self.assertIn(f'"{verb}"', src)


class RuntimeContainerMode(unittest.TestCase):
    def test_container_argv(self):
        p = _PATH.parent / "powos-runtime"
        ld = SourceFileLoader("powos_runtime", str(p))
        rt = module_from_spec(spec_from_loader("powos_runtime", ld))
        ld.exec_module(rt)
        m = {"id": "dev.powos.x", "backend": {"exec": ["/usr/bin/x"]}, "needs": {"network": "none", "write": ["/w"]},
             "budget": {"default": {"memMB": 64, "cpuPct": 25, "pids": 32}}}
        pw = type("pw", (), {"pw_uid": 1000, "pw_gid": 1000, "pw_name": "powos"})
        with patch.object(rt, "device", return_value="desktop"):
            a = rt.container_argv(m, "/d", ["/usr/bin/x"], {"K": "v"}, pw)
        s = " ".join(a)
        for want in ("--memory 64m", "--cpus 0.25", "--pids-limit 32", "--user 1000:1000", "-v /d:/d", "-v /w:/w",
                     "--network none", "-e K=v", "--init", "--read-only --rootfs / /usr/bin/x"):
            self.assertIn(want, s)
        m["backend"]["container"] = {"image": "alpine"}
        with patch.object(rt, "device", return_value="desktop"):
            self.assertEqual(rt.container_argv(m, "/d", ["/usr/bin/x"], {}, pw)[-2:], ["alpine", "/usr/bin/x"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
