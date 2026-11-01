#!/usr/bin/env python3
"""Tier-1 tests for powos-agentsd's conversation (convo_of): an agent's transcript JSONL folded into the chat's items
(the Agents view's agent page draws them with PowOS AI's chat) - user turns with pasted blocks apart, system reminders /
task notifications / tool results / thinking / sidechains hidden, tool calls as whitelisted hints with ok from their
result - and the spool path: the hook's transcript_path read on each batch, a new turn in it showing up in
events/<agent>.json's "convo" and the mirror bundle. Hermetic: temp dirs only."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
AGENTSD = os.path.join(REPO, "lib", "ai", "agents", "powos-agentsd")


def load():
    loader = importlib.machinery.SourceFileLoader("powos_agentsd", AGENTSD)
    spec = importlib.util.spec_from_loader("powos_agentsd", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


D = load()


def user(content, **kw):
    return dict({"type": "user", "message": {"role": "user", "content": content}}, **kw)


def assistant(*blocks):
    return {"type": "assistant", "message": {"role": "assistant", "content": list(blocks)}}


def tool_use(i, name, inp):
    return {"type": "tool_use", "id": i, "name": name, "input": inp}


def result(i, err=False, text="lots of output"):
    return user([{"type": "tool_result", "tool_use_id": i, "content": text, "is_error": err}])


TURN = [
    {"type": "mode", "mode": "x"},
    user("fix the dock\n<pasted_content id=\"p1\">a\nlong\nlog</pasted_content>\n<system-reminder>be good</system-reminder>"),
    assistant({"type": "thinking", "thinking": "secret thoughts"}, {"type": "text", "text": "Looking at **the dock**."}),
    assistant(tool_use("t1", "Read", {"file_path": "/src/ui/dock.tsx"})),
    result("t1"),
    assistant(tool_use("t2", "Bash", {"command": "npm test", "description": "Run the tests"})),
    result("t2", err=True),
    assistant(tool_use("t3", "Edit", {"file_path": "/src/ui/dock.tsx", "old_string": "x", "new_string": "y"})),
    user("<task-notification><task-id>a1</task-id></task-notification>"),
    user("Caveat: the messages below", isMeta=True),
    assistant({"type": "text", "text": "side"}) | {"isSidechain": True},
    assistant({"type": "text", "text": "Done:\n- one\n- two"}),
]


class ConvoTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agents-convo-")
        self.path = os.path.join(self.tmp, "s.jsonl")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, recs, mode="w"):
        with open(self.path, mode) as f:
            for r in recs:
                f.write(json.dumps(r) + "\n")

    def test_a_turn(self):
        self.write(TURN)
        c = D.convo_of(self.path)
        self.assertEqual([i["kind"] for i in c], ["user", "assistant", "tool", "tool", "tool", "assistant"])
        self.assertEqual(c[0]["text"], "fix the dock")
        self.assertEqual(c[0]["pasted"], ["a\nlong\nlog"])
        self.assertEqual(c[1]["text"], "Looking at **the dock**.")
        self.assertEqual([(i["name"], i["hint"], i["ok"]) for i in c[2:5]],
                         [("Read", "dock.tsx", True), ("Bash", "Run the tests", False), ("Edit", "dock.tsx", None)])
        blob = json.dumps(c)
        for never in ("secret thoughts", "lots of output", "be good", "task-notification", "<pasted", "side", "old_string"):
            self.assertNotIn(never, blob)

    def test_tail_and_limit(self):
        self.write([user(f"ask {i}") for i in range(200)])
        c = D.convo_of(self.path, n=5)
        self.assertEqual([i["text"] for i in c], [f"ask {i}" for i in range(195, 200)])
        self.assertIsNone(D.convo_of(os.path.join(self.tmp, "none.jsonl")))
        self.assertIsNone(D.convo_of(None))

    def test_cut_first_line_and_secret(self):
        old = D.CONVO_TAIL
        D.CONVO_TAIL = 200
        try:
            self.write([user("x" * 500), user("token sk-ant-abcdefghijklmnopqrstuvwxyz0123456789 ok")])
            c = D.convo_of(self.path)
        finally:
            D.CONVO_TAIL = old
        self.assertEqual(len(c), 1)
        self.assertNotIn("abcdefghijklmnop", c[0]["text"])

    def test_spool_and_mirror(self):
        """The hook's transcript_path is read at each batch: a new turn appended shows in the events file and the bundle."""
        spool = os.path.join(self.tmp, "spool")
        os.makedirs(spool)
        s = D.Spool(spool, "mac")
        self.write(TURN[:3])
        hdr = ("coder", "", 0)
        s.fold(hdr, {"hook_event_name": "UserPromptSubmit", "session_id": "S1", "prompt": "fix the dock",
                     "transcript_path": self.path, "cwd": "/p/PowOS"}, 1000)
        s.flush()
        ev = os.path.join(spool, "events", "mac_S1.json")
        with open(ev) as f:
            got = json.load(f)
        self.assertEqual([i["kind"] for i in got["convo"]], ["user", "assistant"])
        self.write([assistant({"type": "text", "text": "and a new turn"})], mode="a")
        s.fold(hdr, {"hook_event_name": "Stop", "session_id": "S1", "transcript_path": self.path}, 2000)
        s.flush()
        with open(ev) as f:
            got = json.load(f)
        self.assertEqual(got["convo"][-1]["text"], "and a new turn")
        self.assertEqual(s.bundle()["convos"]["mac:S1"][-1]["text"], "and a new turn")
        # A restart reads it back (no re-read needed for the view).
        s2 = D.Spool(spool, "mac")
        self.assertEqual(s2.convos["mac:S1"][-1]["text"], "and a new turn")
        # A subagent's own transcript never replaces the session's.
        s.fold(hdr, {"hook_event_name": "PreToolUse", "session_id": "S1", "agent_id": "a1", "tool_name": "Read",
                     "transcript_path": "/x/subagents/agent-a1.jsonl"}, 3000)
        self.assertEqual(s.transcripts["mac:S1"], self.path)

    def test_once_cli(self):
        """Through the real daemon (--once): the events file carries the conversation."""
        self.write(TURN)
        env = dict(os.environ, POWOS_AGENTS_DIR=os.path.join(self.tmp, "sp"), POWOS_AGENTS_QUEUE=os.path.join(self.tmp, "q"),
                   POWOS_AGENTS_HOST="mac", POWOS_AGENTS_STDB="0")
        os.makedirs(env["POWOS_AGENTS_QUEUE"])
        with open(os.path.join(env["POWOS_AGENTS_QUEUE"], "1-1.ev"), "w") as f:
            f.write("#\tcoder\t\t0\n" + json.dumps({"hook_event_name": "Stop", "session_id": "S2", "transcript_path": self.path}))
        subprocess.run([sys.executable, AGENTSD, "--once"], env=env, check=True)
        with open(os.path.join(env["POWOS_AGENTS_DIR"], "events", "mac_S2.json")) as f:
            self.assertEqual(json.load(f)["convo"][-1]["text"], "Done:\n- one\n- two")


if __name__ == "__main__":
    unittest.main()
