#!/usr/bin/env python3
"""Tier-1 tests for the manager's TypeScript sandbox (lib/ai/sandbox, ported from SpaceTimeAI's code mode).

Hermetic: every capability's backend is a stub (POWOS_SANDBOX_{COMMS,AGENTS,QUEUE,PHONE}), so no comms, board or
phone is touched. What they pin:
  - the launcher: in-app deps only, fail closed without them, the MCP config it hands the manager;
  - the manager's wiring (manager.sh): the sandbox server in its --mcp-config, merged with comms, --no-sandbox;
  - the engine: values + console, args, a call to an ungranted function is a type error before anything runs, the
    ceiling, input checks before a command runs, the limits (deadline, heap, host calls, phone reads), no
    process/require in the VM, the audit log;
  - the MCP server: initialize, tools/list, tools/call eval.
The engine tests need bun or node >= 22.18 and the deps (`powos sandbox setup`, run here when npm is available);
without them they skip, the launcher and wiring tests still run.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SANDBOX_DIR = os.path.join(REPO, "lib", "ai", "sandbox")
SANDBOX = os.path.join(SANDBOX_DIR, "sandbox.sh")
MANAGER_SH = os.path.join(REPO, "lib", "ai", "manager", "manager.sh")

# A backend stand-in: records argv + stdin as one JSON line, answers per command.
STUB = textwrap.dedent("""
    import json, os, sys
    kind, argv = sys.argv[1], sys.argv[2:]
    data = sys.stdin.read()
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write(json.dumps({"kind": kind, "argv": argv, "stdin": data}) + "\\n")
    if kind == "comms" and argv[:1] == ["inbox"]:
        print(json.dumps({"from": "coder", "body": "one"})); print(json.dumps({"from": "health", "body": "two"}))
    elif kind == "agents" and argv[:2] == ["task", "list"]:
        print(json.dumps([{"id": "t1", "title": "stalled thing", "state": "stalled"}]))
    elif kind == "phone":
        print(json.dumps({"view": argv}))
    else:
        print("ok")
""")


def sh(script, env=None, timeout=60):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, timeout=timeout)


def runtime_ready():
    """bun or node >= 22.18 and the deps; tries `setup` (in-app npm ci) once when they are missing."""
    if sh(f'source "{SANDBOX}"; sandbox_runtime').returncode != 0:
        return False, "no bun or node >= 22.18"
    if sh(f'source "{SANDBOX}"; sandbox_deps_ok').returncode == 0:
        return True, ""
    if not shutil.which("npm"):
        return False, "no deps and no npm"
    r = sh(f'bash "{SANDBOX}" setup', timeout=300)
    return (r.returncode == 0, f"setup failed: {r.stderr[-300:]}")


READY, WHY = runtime_ready()


class Launcher(unittest.TestCase):
    def test_help_names_every_verb_and_capability(self):
        out = sh(f'bash "{SANDBOX}" help').stdout
        for word in ("run", "caps", "declarations", "setup", "status", "mcp",
                     "comms.read", "comms.send", "board.read", "board.write", "checks.queue", "phone.read"):
            self.assertIn(word, out)

    def test_unknown_verb_fails(self):
        self.assertEqual(sh(f'bash "{SANDBOX}" frobnicate').returncode, 2)

    def test_mcp_config_is_valid_json_with_the_manager_ceiling(self):
        out = sh(f'source "{SANDBOX}"; sandbox_mcp_config_json manager').stdout
        srv = json.loads(out)["mcpServers"]["sandbox"]
        self.assertEqual(srv["args"], [SANDBOX, "mcp"])
        self.assertEqual(set(srv["env"]["POWOS_SANDBOX_CEILING"].split(",")),
                         {"comms.read", "comms.send", "board.read", "board.write", "checks.queue", "phone.read"})
        other = json.loads(sh(f'source "{SANDBOX}"; sandbox_mcp_config_json coder').stdout)
        self.assertNotIn("board.write", other["mcpServers"]["sandbox"]["env"]["POWOS_SANDBOX_CEILING"])

    def test_fails_closed_without_deps(self):
        with tempfile.TemporaryDirectory() as d:
            for f in ("sandbox.sh", "package.json", "package-lock.json"):
                shutil.copy(os.path.join(SANDBOX_DIR, f), d)
            r = sh(f'source "{d}/sandbox.sh"; sandbox_enabled && echo wired || echo off')
            self.assertEqual(r.stdout.strip(), "off")
            r = sh(f'echo 1 | bash "{d}/sandbox.sh" run -')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("powos sandbox setup", r.stderr)

    def test_opt_out(self):
        r = sh(f'POWOS_SANDBOX_ENABLED=0; source "{SANDBOX}"; sandbox_enabled && echo wired || echo off')
        self.assertEqual(r.stdout.strip(), "off")


class ManagerWiring(unittest.TestCase):
    """manager.sh's manager_run with its framework stubbed: what --mcp-config the broker gets."""

    def launch(self, *flags, comms=False, sandbox=SANDBOX):
        with tempfile.TemporaryDirectory() as d:
            broker = os.path.join(d, "broker.py")
            seen = os.path.join(d, "seen.json")
            with open(broker, "w") as f:
                f.write(textwrap.dedent(f"""
                    import json, sys
                    a = sys.argv[1:]
                    cfg = None
                    if "--mcp-config-file" in a:
                        cfg = json.load(open(a[a.index("--mcp-config-file") + 1]))
                    import os
                    json.dump({{"argv": a, "mcp": cfg, "id": os.environ.get("COMMS_AGENT_ID")}}, open({seen!r}, "w"))
                """))
            stubs = ('_ai_ensure_config() { :; }; _ai_load_agent() { AGENT_SYSTEM_PROMPT=persona; }; '
                     'comms_export_identity() { export COMMS_AGENT_ID=$1; }; '
                     'comms_mcp_config_json() { echo \'{"mcpServers":{"comms":{"command":"python3","args":["c.py"]}}}\'; }; ')
            stubs += 'comms_enabled() { return 0; }; ' if comms else 'comms_enabled() { return 1; }; '
            env = dict(os.environ, MANAGER_SERVER=broker, MANAGER_SANDBOX=sandbox, AI_STATE_DIR=d, TMPDIR=d)
            env.pop("POWOS_SANDBOX_ENABLED", None)
            env.pop("COMMS_AGENT_ID", None)
            r = sh(f'{stubs} source "{MANAGER_SH}"; manager_run {" ".join(flags)} --once hi', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(seen) as f:
                out = json.load(f)
            left = [n for n in os.listdir(d) if n.startswith("powos-manager-")]
            self.assertEqual(left, [], "the launcher's temp files are removed")
            return out

    @unittest.skipUnless(READY, WHY)
    def test_sandbox_server_is_wired(self):
        out = self.launch()
        self.assertEqual(list(out["mcp"]["mcpServers"]), ["sandbox"])
        self.assertIn("--once", out["argv"])

    @unittest.skipUnless(READY, WHY)
    def test_merged_with_comms(self):
        out = self.launch(comms=True)
        self.assertEqual(sorted(out["mcp"]["mcpServers"]), ["comms", "sandbox"])
        self.assertEqual(out["id"], "manager", "the identity comms exports reaches the session")

    def test_no_sandbox_flag(self):
        out = self.launch("--no-sandbox", comms=True)
        self.assertEqual(list(out["mcp"]["mcpServers"]), ["comms"])
        self.assertNotIn("--no-sandbox", out["argv"])

    def test_missing_sandbox_starts_without_it(self):
        out = self.launch(sandbox="/nonexistent/sandbox.sh")
        self.assertIsNone(out["mcp"])

    def test_help_names_the_sandbox(self):
        r = sh(f'source "{MANAGER_SH}"; manager_run --help')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sandbox eval", r.stdout)
        self.assertIn("--no-sandbox", r.stdout)


@unittest.skipUnless(READY, WHY)
class Engine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        stub = os.path.join(self.tmp, "stub.py")
        with open(stub, "w") as f:
            f.write(STUB)
        self.log = os.path.join(self.tmp, "calls.jsonl")
        self.env = dict(os.environ, STUB_LOG=self.log, XDG_STATE_HOME=os.path.join(self.tmp, "state"),
                        COMMS_AGENT_ID="manager",
                        POWOS_SANDBOX_COMMS=json.dumps([sys.executable, stub, "comms"]),
                        POWOS_SANDBOX_AGENTS=json.dumps([sys.executable, stub, "agents"]),
                        POWOS_SANDBOX_QUEUE="off",
                        POWOS_SANDBOX_PHONE=json.dumps([sys.executable, stub, "phone"]))
        self.env.pop("POWOS_SANDBOX_CEILING", None)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def job(self, code, *flags, env=None):
        return subprocess.run(["bash", SANDBOX, "run", *flags, "-"], input=code, capture_output=True, text=True,
                              env=env or self.env, timeout=60)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(l) for l in f if l.strip()]

    def test_value_console_and_args(self):
        r = self.job('console.log("hi", args.n); const x: number = args.n as number; x * 2', "--args", '{"n": 21}')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "hi 21\n=> 42")

    def test_ungranted_function_is_a_type_error_before_anything_runs(self):
        r = self.job('await sendMessage({ to: "coder", body: "x" })')
        self.assertEqual(r.returncode, 1)
        self.assertIn("Cannot find name 'sendMessage'", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_granted_functions_reach_their_backend_as_argv(self):
        r = self.job('const m = await commsInbox({ limit: 1 }); await sendMessage({ to: "coder", body: "-rf hi" }); m',
                     "--grant", "comms.read", "--grant", "comms.send")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), [{"from": "coder", "body": "one"}])
        send = [c for c in self.calls() if c["argv"][:1] == ["send"]]
        self.assertEqual(send[0]["argv"], ["send", "--priority", "normal", "--", "coder", "-"])
        self.assertEqual(send[0]["stdin"], "-rf hi\n")

    def test_inputs_are_checked_before_a_command_runs(self):
        r = self.job('await sendMessage({ to: "../etc; rm", body: "x" })', "--grant", "comms.send")
        self.assertEqual(r.returncode, 1)
        self.assertIn("to is not valid", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_ceiling_refuses_a_grant(self):
        env = dict(self.env, POWOS_SANDBOX_CEILING="comms.read")
        r = self.job('1', "--grant", "board.write", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not grantable here: board.write", r.stderr)

    def test_no_backend_no_capability(self):
        r = self.job('1', "--grant", "checks.queue")   # POWOS_SANDBOX_QUEUE=off
        self.assertEqual(r.returncode, 1)
        self.assertIn("not grantable here", r.stderr)

    def test_vm_has_no_process_or_require(self):
        r = self.job('const g = globalThis as any; [typeof g.process, typeof g.require, typeof g.std, typeof g.os]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), ["undefined"] * 4)

    def test_deadline(self):
        r = self.job('while (true) {}', "--timeout", "1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("interrupted", r.stderr)

    def test_heap_cap(self):
        r = self.job('const a: string[] = []; while (true) a.push("x".repeat(4096))', "--memory", "8")
        self.assertEqual(r.returncode, 1)
        self.assertIn("out of memory", r.stderr)

    def test_host_call_cap(self):
        r = self.job('for (let i = 0; i < 5; i++) await boardTasks({}); 1', "--grant", "board.read", "--max-calls", "3")
        self.assertEqual(r.returncode, 1)
        self.assertIn("used its 3 host calls", r.stderr)
        self.assertEqual(len(self.calls()), 3)

    def test_phone_reads_are_capped(self):
        r = self.job('for (let i = 0; i < 6; i++) await phoneState({ what: "status" }); 1', "--grant", "phone.read")
        self.assertEqual(r.returncode, 1)
        self.assertIn("at most 5 phone reads", r.stderr)
        r = self.job('await phoneState({ what: "rm -rf /" })', "--grant", "phone.read")
        self.assertIn("is not assignable", r.stderr)   # the declarations name the views
        r = self.job('await phoneState({ what: "rm -rf /" as any })', "--grant", "phone.read")
        self.assertIn("what is one of", r.stderr)      # and the host checks them again
        self.assertEqual([c for c in self.calls() if c["argv"][:1] == ["rm"]], [])

    def test_jobs_are_audited(self):
        self.job('await boardTasks({ state: "stalled" })', "--grant", "board.read")
        log = os.path.join(self.tmp, "state", "powos", "sandbox", "jobs.jsonl")
        with open(log) as f:
            entry = json.loads(f.read().splitlines()[-1])
        self.assertEqual((entry["agent"], entry["grants"], entry["calls"], entry["ok"]), ("manager", ["board.read"], 1, True))

    def test_mcp_server(self):
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                 "params": {"name": "eval", "arguments": {"code": "(await boardTasks({})).length", "grants": ["board.read"]}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                 "params": {"name": "eval", "arguments": {"code": "await sendMessage({to:'x',body:'y'})"}}}]
        p = subprocess.Popen(["bash", SANDBOX, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, env=dict(self.env, POWOS_SANDBOX_CEILING="board.read"))
        got = {}
        try:
            for m in msgs:
                p.stdin.write(json.dumps(m) + "\n")
            p.stdin.flush()
            while len(got) < 4:
                line = p.stdout.readline()
                self.assertTrue(line, p.stderr.read() if p.poll() is not None else "server closed stdout")
                r = json.loads(line)
                got[r["id"]] = r
        finally:
            p.stdin.close()
            p.wait(timeout=10)
        self.assertEqual(got[1]["result"]["serverInfo"]["name"], "powos-sandbox")
        self.assertEqual([t["name"] for t in got[2]["result"]["tools"]], ["eval", "declarations"])
        self.assertIn("comms.send (not grantable here): sendMessage", got[2]["result"]["tools"][0]["description"])
        self.assertEqual(got[3]["result"]["content"][0]["text"], "1")
        self.assertTrue(got[4]["result"].get("isError"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
