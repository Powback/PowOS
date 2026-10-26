#!/usr/bin/env python3
"""f199/f170: the Mac's `powos agents`/`powos friction` (lib/ai/agents/powos-agents-cli) parses its own argv
locally, then - whenever the local powos-agents module is unreachable (always true off the phone, remote()'s
own HACK) - re-runs that SAME argv against whatever copy of this script is installed on the phone, over adb
(handle_down() -> _remote_run()). A flag the Mac already accepts (e.g. `friction list --id`, added by f96)
can still be rejected there if the phone's copy predates it: "unknown option --id" comes back indistinguishable
from a real bug.

Hermetic repro: a stub `docker` on PATH stands in for a PHONE CLI that is older than this one - it rejects
`--id` exactly like this script's own die() would, and also doesn't know the `__cli_version__` probe this fix
introduces. Asserts the Mac turns that into a clear "phone CLI is older ... run rooted.sh deploy" message
instead of passing the confusing parse error through, and that a non-stale phone (knows --id, answers
__cli_version__) is left alone - no false positive.
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


class StalePhoneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agents-stale-phone-test-")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)

        # Stub adb.sh: phone_reachable() only looks at --vpn-state; keep it "up" throughout.
        adb = os.path.join(self.bin, "adb.sh")
        with open(adb, "w") as f:
            f.write("#!/bin/sh\nif [ \"$1\" = --vpn-state ]; then echo vpn=up; exit 0; fi\nexit 0\n")
        os.chmod(adb, os.stat(adb).st_mode | stat.S_IEXEC)
        self.adb = adb

        self.env = dict(
            os.environ,
            PATH=self.bin + os.pathsep + os.environ["PATH"],
            POWOS_AGENTS_ADB=self.adb,
            POWOS_AGENTS_OUTBOX=os.path.join(self.tmp, "outbox"),
            POWOS_STDB="http://127.0.0.1:1",  # nothing listens here: Down is raised at once, every time
        )

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_docker_stub(self, body):
        docker = os.path.join(self.bin, "docker")
        with open(docker, "w") as f:
            f.write("#!/usr/bin/env python3\n" + body)
        os.chmod(docker, os.stat(docker).st_mode | stat.S_IEXEC)

    def run_cli(self, *args):
        return subprocess.run([sys.executable, CLI, *args], env=self.env, capture_output=True, text=True)

    def test_older_phone_cli_gives_clear_message_not_raw_parse_error(self):
        # An older phone copy: rejects --id (predates f96) AND doesn't know __cli_version__ (predates this fix).
        self.write_docker_stub(
            "import base64, json, re, sys\n"
            "m = re.search(r\"--argv-b64 (\\S+?)'\", ' '.join(sys.argv))\n"
            "argv = json.loads(base64.b64decode(m.group(1))) if m else []\n"
            "def die(msg):\n"
            "    sys.stderr.write(f'powos agents: {msg}\\n')\n"
            "    sys.exit(1)\n"
            "if argv == ['__cli_version__']:\n"
            "    die(\"unknown: __cli_version__ (powos agents help)\")\n"
            "if argv[:2] == ['friction', 'list'] and '--id' in argv:\n"
            "    die('unknown option --id (powos agents help)')\n"
            "print('ok')\n"
        )
        r = self.run_cli("friction", "list", "--id", "f1")
        self.assertNotEqual(r.returncode, 0)
        combined = r.stdout + r.stderr
        self.assertIn("phone CLI is older", combined)
        self.assertIn("rooted.sh deploy", combined)
        self.assertNotIn("unknown option --id", combined, "the confusing raw parse error must not leak through")

    def test_current_phone_cli_is_left_alone(self):
        # A phone copy that's current: knows --id, and answers __cli_version__ with this very CLI_VERSION.
        with open(CLI) as f:
            cli_src = f.read()
        m = __import__("re").search(r"^CLI_VERSION = (\d+)", cli_src, __import__("re").M)
        version = m.group(1)
        self.write_docker_stub(
            "import base64, json, re, sys\n"
            "m = re.search(r\"--argv-b64 (\\S+?)'\", ' '.join(sys.argv))\n"
            "argv = json.loads(base64.b64decode(m.group(1))) if m else []\n"
            "if argv == ['__cli_version__']:\n"
            f"    print({version})\n"
            "elif argv[:2] == ['friction', 'list']:\n"
            "    print('f1    x1   [board/broken-tool] fine')\n"
            "else:\n"
            "    print('ok')\n"
        )
        r = self.run_cli("friction", "list", "--id", "f1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("f1", r.stdout)
        self.assertNotIn("phone CLI is older", r.stdout + r.stderr, "no false positive against a current phone")


if __name__ == "__main__":
    unittest.main()
