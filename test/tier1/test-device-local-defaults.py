#!/usr/bin/env python3
"""A fresh device runs on its own (GitHub issue #1, "Fresh phone install is wired to the owner's OnePlus + Mac"), hermetic.

Pinned: with no owner config and no powos-agents module, `powos agents` / `powos friction` keep THIS device's board in
a local file (never "queued (offline)" for the owner's phone) with the module's rules (the done rule included); a
device that runs the module itself and can't reach it gets an error, not a second board; phone_reachable() is False
with no linked host; the owner's hosts are no code default (powos-rootsh, powos terms, powos transcribe, self push
--ship) and the owner config turns each back on; `powos app services` without a system tier says so.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CLI = os.path.join(ROOT, "lib", "ai", "agents", "powos-agents-cli")


def load(name, path):
    m = module_from_spec(spec_from_loader(name, SourceFileLoader(name, path)))
    m.__loader__.exec_module(m)
    return m


class Fresh(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fresh-device-")
        self.own = os.path.join(self.tmp, "owner.conf")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("POWOS_")}
        self.env.update(HOME=self.tmp, XDG_STATE_HOME=os.path.join(self.tmp, "state"), POWOS_OWNER_CONF=self.own,
                        POWOS_STDB="http://127.0.0.1:1", POWOS_AGENTS_OUTBOX=os.path.join(self.tmp, "outbox"),
                        POWOS_AGENTS_ADB=os.path.join(self.tmp, "no-adb.sh"), GIT_CONFIG_GLOBAL="/dev/null")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cli(self, *args, stdin=None):
        return subprocess.run([sys.executable, CLI, *args], env=self.env, capture_output=True, text=True, input=stdin,
                              cwd=self.tmp, timeout=60)

    def test_board_is_local(self):
        r = self.cli("task", "add", "Local board works", "--owner", "coder")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("queued (offline)", r.stdout)
        self.assertEqual(self.cli("task", "set", "local-board-works", "--plan", "a; b", "--step", "a").returncode, 0)
        rows = json.loads(self.cli("task", "list", "--json").stdout)
        w = next(x for x in rows if x["id"] == "local-board-works")
        self.assertEqual((w["owner"], w["step"]), ("coder", "a"))
        r = self.cli("task", "done", "local-board-works", "--no-check", "tier-1 tested")
        self.assertNotEqual(r.returncode, 0, "planned step b still open: the module's done rule holds here too")
        self.assertIn("planned step", r.stderr)
        self.assertEqual(self.cli("task", "set", "local-board-works", "--plan", "").returncode, 0)
        r = self.cli("task", "done", "local-board-works", "--no-check", "tier-1 tested")
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.cli("friction", "add", "--area", "tools", "--kind", "slow", "--repro", "none: test", "it was slow")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.cli("friction", "add", "--area", "tools", "--kind", "slow", "--repro", "none: test", "it was slow")
        fr = json.loads(self.cli("friction", "list", "--json").stdout)
        self.assertEqual([(f["id"], f["count"]) for f in fr], [("f1", 2)])
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "outbox", "pending")), "nothing queued for anyone")
        self.assertTrue(os.path.exists(os.path.join(self.tmp, "state", "powos", "agents-board.json")))

    def test_module_device_gets_an_error_not_a_second_board(self):
        cli = load("agents_cli", CLI)
        cli.STDB_DATA = self.tmp   # "this device runs the module" (its data dir exists)
        os.environ["POWOS_OWNER_CONF"] = self.own
        os.environ.pop("POWOS_BOARD_REMOTE", None)
        cli.SERVER = "http://127.0.0.1:1"

        def down():
            raise cli.Down("connection refused")
        with self.assertRaises(SystemExit):
            cli.run_local(["task", "list"], down)
        self.assertFalse(cli.FILE_STORE)
        self.assertFalse(cli.phone_reachable(), "no linked host: nothing to reach, never 'I am the phone'")
        with open(self.own, "w") as f:
            f.write("POWOS_BOARD_REMOTE=true '{cmd}'\n")
        self.assertTrue(cli.phone_reachable())

    def test_no_owner_hosts_by_default(self):
        os.environ["POWOS_OWNER_CONF"] = self.own
        for k in ("POWOS_ROOTSH_SHELL", "POWOS_TERMS_LINKS", "POWOS_STT_URL", "POWOS_TERMS_HOSTS"):
            os.environ.pop(k, None)
        rootsh = load("rootsh", os.path.join(ROOT, "lib", "ai", "agents", "powos-rootsh"))
        self.assertEqual(rootsh.SHELL, "")
        self.assertIn("no root shell configured", rootsh.Session().open())
        os.environ["POWOS_TERMS_HOSTS_CONF"] = os.path.join(self.tmp, "none")
        terms = load("terms", os.path.join(ROOT, "lib", "apps", "powos-terms"))
        self.assertEqual(terms.DEFAULT_LINKS, [])
        tr = load("transcribe", os.path.join(ROOT, "lib", "apps", "powos-transcribe"))
        tr.CONFIG = os.path.join(self.tmp, "none")
        self.assertEqual(tr.server_url(None), "")
        with open(self.own, "w") as f:
            f.write("POWOS_ROOTSH_SHELL=adb shell -T su\nPOWOS_TERMS_LINKS=mac=me@hub\nPOWOS_STT_URL=http://stt.example/\n")
        self.assertEqual(load("rootsh2", os.path.join(ROOT, "lib", "ai", "agents", "powos-rootsh")).SHELL, "adb shell -T su")
        self.assertEqual(load("terms2", os.path.join(ROOT, "lib", "apps", "powos-terms")).DEFAULT_LINKS, [("mac", "me@hub")])
        self.assertEqual(tr.server_url(None), "http://stt.example")

    def test_ship_gate_has_no_default(self):
        sh = (f'eval "$(sed -n "/^self_owner_conf()/,/^}}/p;/^self_ship_conf()/,/^}}/p" {ROOT}/lib/self.sh)"; '
              'self_ship_conf')
        env = dict(self.env, POWOS_SHIP_GATE_CONF=os.path.join(self.tmp, "none"))
        out = subprocess.run(["bash", "-c", sh], env=env, capture_output=True, text=True).stdout
        self.assertTrue(out.startswith("\t"), repr(out))
        with open(self.own, "w") as f:
            f.write("POWOS_SHIP_GATE_URL=http://gate.example:7433\n")
        out = subprocess.run(["bash", "-c", sh], env=env, capture_output=True, text=True).stdout
        self.assertTrue(out.startswith("http://gate.example:7433\t"), repr(out))

    def test_app_services_without_system_tier(self):
        d = os.path.join(self.tmp, "apps")
        os.makedirs(d)
        shutil.copy(os.path.join(ROOT, "lib", "apps", "powos-app"), d)
        r = subprocess.run([sys.executable, os.path.join(d, "powos-app"), "services"], capture_output=True, text=True,
                           env=dict(self.env, PATH="/usr/bin:/bin"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no system tier on this build", r.stdout)
        self.assertNotIn("Traceback", r.stderr)

    def test_device_context_says_which_device(self):
        ctx = os.path.join(ROOT, "lib", "ai", "manager", "powos-device-context")
        env = dict(self.env, POWOS_PLATFORM="phone", POWOS_DEVICE_MODEL="SM-S938B", FAKEROOTKEY="1")
        out = subprocess.run(["sh", ctx], env=env, capture_output=True, text=True).stdout
        self.assertIn("model: SM-S938B", out)
        self.assertIn("no root", out)
        self.assertIn("standalone", out)
        with open(self.own, "w") as f:
            f.write("POWOS_STT_URL=http://stt.example\n")
        env.update(POWOS_ROOTED="yes", POWOS_DEVICE_MODEL="CPH2551")
        out = subprocess.run(["sh", ctx], env=env, capture_output=True, text=True).stdout
        self.assertIn("rooted:", out)
        self.assertIn("one of the owner's devices", out)
        with open(os.path.join(ROOT, "config", "ai", "context", "capabilities.md")) as f:
            caps = f.read()
        self.assertNotIn("Device in use: OnePlus Open", caps)

    def test_owner_json_board_remote_keeps_the_phone_command_whole(self):
        """adb shell re-joins its arguments into the phone's shell line, so the whole `su -c "sh powos-run.sh '...'"`
        must reach adb as ONE argument: unquoted, shlex split it and the phone ran a bare `powos` (its usage text came
        back as the board; 11-09, after the owner.conf move)."""
        import shlex
        with open(os.path.join(ROOT, "tools", "phone", "owner.json")) as f:
            tmpl = json.load(f)["POWOS_BOARD_REMOTE"]
        argv = shlex.split(tmpl.replace("{cmd}", "powos agents --argv-b64 WzFd"))
        self.assertEqual(argv[:5], ["docker", "exec", "powos-vadb", "adb", "shell"])
        self.assertEqual(argv[5:], ["su -c \"sh /data/powos/powos-run.sh 'powos agents --argv-b64 WzFd'\""])


if __name__ == "__main__":
    unittest.main()
