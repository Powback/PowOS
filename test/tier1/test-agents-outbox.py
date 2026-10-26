#!/usr/bin/env python3
"""The Mac-side outbox for `powos agents`/`powos friction` (lib/ai/agents/powos-agents-cli), hermetic.

friction f61/f64: the board and friction live on the phone's SpacetimeDB, reached over the dev channel
(remote(), a HACK) - unreachable, with no recovery, whenever the phone was off the VPN: a write just died, a
read had nothing to fall back to. Exercises the real CLI with a stub `adb.sh` (controls online/offline via its
--vpn-state exit code, as the real one does) and a stub `docker` on PATH (stands in for the phone replying):
offline queues a write and serves a read from the cache; back online, the queued write flushes in order before
the next call, and a fresh read repopulates the cache.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.normpath(os.path.join(HERE, "..", "..", "lib", "ai", "agents", "powos-agents-cli"))


class OutboxTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agents-outbox-test-")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.calls_log = os.path.join(self.tmp, "calls.log")
        self.vpn_state = os.path.join(self.tmp, "vpn-state")  # "up" or "down"
        self.set_online(False)

        # Stub adb.sh: only --vpn-state is used by the CLI's phone_reachable().
        adb = os.path.join(self.bin, "adb.sh")
        with open(adb, "w") as f:
            f.write(
                "#!/bin/sh\n"
                'if [ "$1" = --vpn-state ]; then\n'
                f'  st=$(cat "{self.vpn_state}" 2>/dev/null)\n'
                '  if [ "$st" = up ]; then echo vpn=up; exit 0; else echo vpn=offline; exit 69; fi\n'
                "fi\n"
                "exit 0\n"
            )
        os.chmod(adb, os.stat(adb).st_mode | stat.S_IEXEC)
        self.adb = adb

        # Stub docker: decodes the inner --argv-b64 payload, logs it (so flush order is checkable), and answers.
        # Reads get a fixed marker string so the cache can be checked; writes get "ok".
        docker = os.path.join(self.bin, "docker")
        with open(docker, "w") as f:
            f.write(
                "#!/usr/bin/env python3\n"
                "import base64, json, re, sys\n"
                'm = re.search(r"--argv-b64 (\\S+?)\'", " ".join(sys.argv))\n'
                "argv = json.loads(base64.b64decode(m.group(1))) if m else []\n"
                f'with open({json.dumps(self.calls_log)}, "a") as f:\n'
                '    f.write(json.dumps(argv) + "\\n")\n'
                'if argv[:2] == ["task", "list"]:\n'
                '    print("BOARD-SNAPSHOT: one task")\n'
                "else:\n"
                '    print("ok")\n'
            )
        os.chmod(docker, os.stat(docker).st_mode | stat.S_IEXEC)

        self.env = dict(
            os.environ,
            PATH=self.bin + os.pathsep + os.environ["PATH"],
            POWOS_AGENTS_ADB=self.adb,
            POWOS_AGENTS_OUTBOX=os.path.join(self.tmp, "outbox"),
            POWOS_STDB="http://127.0.0.1:1",  # nothing listens here: Down is raised at once, every time
        )

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_online(self, up):
        with open(self.vpn_state, "w") as f:
            f.write("up" if up else "down")

    def run_cli(self, *args):
        return subprocess.run([sys.executable, CLI, *args], env=self.env, capture_output=True, text=True)

    def pending(self):
        d = os.path.join(self.env["POWOS_AGENTS_OUTBOX"], "pending")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def calls(self):
        if not os.path.exists(self.calls_log):
            return []
        with open(self.calls_log) as f:
            return [json.loads(l) for l in f if l.strip()]

    def test_write_queues_while_offline_then_flushes_in_order(self):
        self.set_online(False)
        r1 = self.run_cli("task", "set", "t1", "--status", "working")
        self.assertEqual(r1.returncode, 0, r1.stderr)
        self.assertIn("queued (offline)", r1.stdout)
        r2 = self.run_cli("friction", "add", "--area", "x", "--kind", "broken-tool", "title", "--repro", "r")
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertEqual(len(self.pending()), 2, "both writes queued while offline")
        self.assertEqual(self.calls(), [], "nothing reached the phone while offline")

        # Back online: the next call (any call) flushes the backlog first, in order, before its own request.
        self.set_online(True)
        r3 = self.run_cli("task", "list")
        self.assertEqual(r3.returncode, 0, r3.stderr)
        self.assertEqual(self.pending(), [], "outbox drained once the phone's reachable")
        sent = self.calls()
        self.assertEqual(len(sent), 3, "the two queued writes, then the live read")
        self.assertEqual(sent[0][:2], ["task", "set"])
        self.assertEqual(sent[1][:2], ["friction", "add"])
        self.assertEqual(sent[2][:2], ["task", "list"])

    def test_read_falls_back_to_cache_while_offline(self):
        self.set_online(True)
        r1 = self.run_cli("task", "list")
        self.assertEqual(r1.returncode, 0, r1.stderr)
        self.assertIn("BOARD-SNAPSHOT", r1.stdout)

        self.set_online(False)
        r2 = self.run_cli("task", "list")
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertIn("BOARD-SNAPSHOT", r2.stdout, "served from the cache, not a live call")
        self.assertIn("(offline, as of ", r2.stdout)

    def test_read_with_no_cache_while_offline_fails_fast(self):
        self.set_online(False)
        r = self.run_cli("task", "list")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("isn't reachable", r.stderr + r.stdout)


if __name__ == "__main__":
    unittest.main()
