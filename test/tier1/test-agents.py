#!/usr/bin/env python3
"""The Agents view's reporter (lib/ai/agents): hook -> queue -> powos-agentsd -> spool, hermetic.

Events go through the real hook script (so its queue choice and header are covered), then `powos-agentsd --once`
folds them; the spool's rows are checked against docs/AGENTS-VIEW-DESIGN.md §3: ids, states, coalescing, subagents,
tasks, the secret scrub, comms messages, and install-hooks.py keeping a settings file's other hooks.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AGENTS = os.path.normpath(os.path.join(HERE, "..", "..", "lib", "ai", "agents"))
HOOK = os.path.join(AGENTS, "powos-agent-hook")
AGENTSD = os.path.join(AGENTS, "powos-agentsd")


class AgentsSpoolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agents-test-")
        self.env = dict(
            os.environ,
            POWOS_AGENTS_DIR=os.path.join(self.tmp, "spool"),
            POWOS_AGENTS_QUEUE=os.path.join(self.tmp, "q"),
            POWOS_AGENTS_HOST="mac",
            POWOS_AGENTS_ROLE="coder",
            # The hook starts agentsd when none runs: a stand-in here, the test folds with --once itself.
            PATH=self.stub_path(),
        )
        self.env.pop("COMMS_AGENT_ID", None)
        self.env.pop("COMMS_PARENT_ID", None)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def stub_path(self):
        d = os.path.join(self.tmp, "bin")
        os.makedirs(d)
        with open(os.path.join(d, "python3"), "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(os.path.join(d, "python3"), 0o755)
        return d + os.pathsep + os.environ["PATH"]

    def hook(self, **rec):
        rec.setdefault("session_id", "S1")
        rec.setdefault("cwd", "/home/u/Projects/PowOS")
        subprocess.run([HOOK], input=json.dumps(rec).encode(), env=self.env, check=True)

    def fold(self):
        env = dict(self.env, PATH=os.environ["PATH"])
        subprocess.run([sys.executable, AGENTSD, "--once"], env=env, check=True)
        with open(os.path.join(self.tmp, "spool", "state.json")) as f:
            return json.load(f)

    def ring(self, agent):
        name = agent.replace(":", "_").replace("/", "_")
        with open(os.path.join(self.tmp, "spool", "events", name + ".json")) as f:
            return json.load(f)["events"]

    def test_a_turn(self):
        self.hook(hook_event_name="SessionStart")
        self.hook(hook_event_name="UserPromptSubmit", prompt="ship the agents view\nand more")
        for i in range(3):
            inp = {"file_path": f"/src/ui/grid{i}.tsx"}
            self.hook(hook_event_name="PreToolUse", tool_name="Read", tool_use_id=f"r{i}", tool_input=inp)
            self.hook(hook_event_name="PostToolUse", tool_name="Read", tool_use_id=f"r{i}", tool_input=inp, tool_response={"x": "y"})
        s = self.fold()
        a = {r["id"]: r for r in s["agents"]}["mac:S1"]
        self.assertEqual((a["role"], a["host"], a["state"], a["cwd"]), ("coder", "mac", "working", "PowOS"))
        self.assertEqual(a["title"], "ship the agents view")
        tools = [e for e in self.ring("mac:S1") if e["kind"] == "tool"]
        self.assertEqual(len(tools), 1, "same tool within 10 s is one row")
        self.assertEqual((tools[0]["name"], tools[0]["n"], tools[0]["hint"], tools[0]["ok"]), ("Read", 3, "grid2.tsx", True))
        self.hook(hook_event_name="Stop", last_assistant_message="done: widget on home")
        s = self.fold()
        a = s["agents"][0]
        self.assertEqual((a["state"], a["report"]), ("idle", "done: widget on home"))

    def test_subagents_and_tasks(self):
        self.hook(hook_event_name="UserPromptSubmit", prompt="go")
        self.hook(hook_event_name="PreToolUse", tool_name="Agent", tool_use_id="g", tool_input={"description": "survey SpaceTimeAI"})
        self.hook(hook_event_name="SubagentStart", agent_id="A1", agent_type="Explore")
        self.hook(hook_event_name="PreToolUse", agent_id="A1", agent_type="Explore", tool_name="Grep", tool_use_id="x", tool_input={"pattern": "p"})
        self.hook(
            hook_event_name="PostToolUse",
            tool_name="TodoWrite",
            tool_input={"todos": [{"content": "read", "status": "completed"}, {"content": "write", "status": "in_progress"}]},
        )
        s = self.fold()
        rows = {r["id"]: r for r in s["agents"]}
        sub = rows["mac:S1/A1"]
        self.assertEqual((sub["parent"], sub["role"], sub["title"], sub["state"]), ("mac:S1", "Explore", "survey SpaceTimeAI", "working"))
        self.assertEqual(rows["mac:S1"]["subs"], 1)
        self.assertEqual(rows["mac:S1"]["title"], "write", "the in-progress task is the title")
        self.assertEqual([(t["subject"], t["status"]) for t in s["tasks"]], [("read", "done"), ("write", "in_progress")])
        self.hook(hook_event_name="SubagentStop", agent_id="A1", agent_type="Explore", last_assistant_message="found 3")
        self.hook(hook_event_name="Stop")
        s = self.fold()
        rows = {r["id"]: r for r in s["agents"]}
        self.assertEqual((rows["mac:S1/A1"]["state"], rows["mac:S1"]["subs"], rows["mac:S1"]["state"]), ("gone", 0, "idle"))

    def test_secrets_and_whitelist(self):
        self.hook(hook_event_name="PreToolUse", tool_name="Bash", tool_use_id="b", tool_input={"command": "GH_TOKEN=ghp_abcdefgh12345678 git push | tee log"})
        self.hook(hook_event_name="PostToolUseFailure", tool_name="Bash", tool_use_id="b", tool_input={"command": "GH_TOKEN=ghp_abcdefgh12345678 git push | tee log"}, error="x")
        self.hook(hook_event_name="PostToolUse", tool_name="Write", tool_use_id="w", tool_input={"file_path": "/a/secret.txt", "content": "sk-ant-verysecretvalue"})
        self.fold()
        text = json.dumps(self.ring("mac:S1"))
        self.assertNotIn("ghp_", text)
        self.assertNotIn("sk-ant", text)
        self.assertNotIn("tee", text, "Bash's hint stops at the first |")
        self.assertIn("secret.txt", text)

    def test_board_task_held(self):
        """`work`: the board task the agent's own step/progress calls name; assigning claims nothing; done/queued lets go."""
        bash = lambda c: self.hook(hook_event_name="PreToolUse", agent_id="A1", agent_type="powos-comms", tool_name="Bash", tool_use_id=c[:8], tool_input={"command": c})
        work = lambda: {r["id"]: r for r in self.fold()["agents"]}["mac:S1/A1"]["work"]
        bash("powos agents task set other --owner switcher --note 'yours'")
        self.assertEqual(work(), "")
        bash('cd x && powos agents task set board-live --step "derive state" && git push')
        self.assertEqual(work(), "board-live")
        bash("tools/phone/verify/queue.sh add --close --name 'a b' board-live check.sh")
        self.assertEqual(work(), "")
        bash("powos agents task set t2 --progress=1/3\npowos agents task done t2")
        self.assertEqual(work(), "")

    def test_three_failures_block(self):
        for i in range(3):
            self.hook(hook_event_name="PostToolUseFailure", tool_name=f"T{i}", tool_use_id=str(i), error="no")
        self.assertEqual(self.fold()["agents"][0]["state"], "blocked")

    def test_comms_message(self):
        q = os.path.join(self.tmp, "q")
        os.makedirs(q)
        with open(os.path.join(q, "m1.ev"), "w") as f:
            json.dump({"powos_agents": "message", "id": "m1", "from": "coder", "to": "manager", "kind": "message", "priority": "normal", "ts": 5, "body": "report: done"}, f)
        self.hook(hook_event_name="SessionStart")
        self.fold()
        with open(os.path.join(self.tmp, "spool", "messages.json")) as f:
            m = json.load(f)["messages"]
        self.assertEqual([(x["from"], x["to"], x["body"]) for x in m], [("coder", "manager", "report: done")])

    def ask(self, timeout, answer=None):
        """powos-agent-ask once, answered by a stand-in for the app ([answer]) or not; its stdout."""
        asks = os.path.join(self.tmp, "spool", "asks")
        os.makedirs(asks, exist_ok=True)
        # Its agentsd is the stand-in (PATH): the test folds with --once itself.
        env = dict(self.env, POWOS_AGENTS_ASK_TIMEOUT=str(timeout))
        p = subprocess.Popen([sys.executable, os.path.join(AGENTS, "powos-agent-ask")], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        p.stdin.write(json.dumps({"session_id": "S1", "tool_name": "Bash", "tool_input": {"command": "rm -rf out/"}}).encode())
        p.stdin.close()
        if answer:
            import time
            for _ in range(100):
                q = os.path.join(self.tmp, "q")
                raised = [n for n in os.listdir(q) if n.endswith(".ev")] if os.path.isdir(q) else []
                if raised:
                    break
                time.sleep(0.05)
            with open(os.path.join(q, raised[0])) as f:
                ask = json.loads(f.read().split("\n", 1)[1])["ask_id"]
            with open(os.path.join(asks, ask + ".json"), "w") as f:
                json.dump(answer, f)
        out = p.stdout.read().decode()
        p.wait(timeout=30)
        return out

    def test_ask_answered(self):
        out = self.ask(20, {"answer": "deny", "reason": "not now"})
        d = json.loads(out)["hookSpecificOutput"]
        self.assertEqual((d["hookEventName"], d["decision"]["behavior"], d["decision"]["message"]), ("PermissionRequest", "deny", "not now"))

    def test_ask_expires_to_the_terminal(self):
        self.assertEqual(self.ask(1), "", "no decision: Claude asks at its terminal")
        s = self.fold()
        self.assertEqual(s["asks"], [])
        self.assertEqual(s["agents"][0]["state"], "needs_you")
        self.assertEqual([e["name"] for e in self.ring("mac:S1")], ["ask", "expired"])

    def test_install_hooks_keeps_the_rest(self):
        path = os.path.join(self.tmp, "settings.json")
        mine = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "br-gate.py"}]}]}, "tui": "x"}
        with open(path, "w") as f:
            json.dump(mine, f)
        tool = os.path.join(AGENTS, "install-hooks.py")
        for _ in range(2):  # idempotent
            subprocess.run([sys.executable, tool, path, "--command", "X=1 /p/powos-agent-hook"], check=True, stdout=subprocess.DEVNULL)
        with open(path) as f:
            s = json.load(f)
        self.assertEqual(s["tui"], "x")
        pre = s["hooks"]["PreToolUse"]
        self.assertEqual(len(pre), 2)
        self.assertEqual(pre[0]["hooks"][0]["command"], "br-gate.py")
        self.assertTrue(all(g["hooks"][0].get("async") for e, gs in s["hooks"].items() for g in gs if "powos-agent-hook" in g["hooks"][0]["command"]))
        self.assertNotIn("PermissionRequest", s["hooks"], "phase 1 never blocks: no permission hook")
        subprocess.run([sys.executable, tool, path, "--remove"], check=True, stdout=subprocess.DEVNULL)
        with open(path) as f:
            self.assertEqual(json.load(f), mine)


if __name__ == "__main__":
    unittest.main()
