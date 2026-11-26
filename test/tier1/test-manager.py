#!/usr/bin/env python3
"""Tier-1 tests for the PowOS Manager broker (lib/ai/manager/manager.py).

Hermetic: a fake `claude` stub speaks the same stream-json protocol, so the
broker's real logic — session capture/resume, per-dir memory, two-writer
serialization, and LIVE comms-inbox injection — is exercised with no real
`claude`, no network, no desktop.
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BROKER = os.path.join(REPO, "lib", "ai", "manager", "manager.py")

# A stand-in for `claude -p --input-format stream-json ...`: emits system/init,
# then for every user event echoes the text back as an assistant turn + result.
STUB = textwrap.dedent("""
    import sys, json, os, argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--resume')
    a, _ = ap.parse_known_args()
    rec = os.environ.get('STUB_ARGV_FILE')
    if rec:
        open(rec, 'w').write(' '.join(sys.argv[1:]))
    sid = a.resume or 'stub-session-0001'
    def emit(o):
        sys.stdout.write(json.dumps(o) + '\\n'); sys.stdout.flush()
    emit({'type': 'system', 'subtype': 'init', 'session_id': sid,
          'tools': [], 'mcp_servers': []})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if os.environ.get('STUB_STALE_RESULT') and not os.environ.get('_stale_done'):
            # A resumed session's stale <task-notification> turn: a result with no assistant event (10-31 13:03).
            os.environ['_stale_done'] = '1'
            emit({'type': 'result', 'subtype': 'success', 'session_id': sid, 'total_cost_usd': 0.0})
            import time; time.sleep(1.0)   # the real turn is still being answered (the API call takes a while)
        text = ''
        for b in ev.get('message', {}).get('content', []):
            if b.get('type') == 'text':
                text = b['text']
        ctx = int(os.environ.get('STUB_CTX', '0'))
        emit({'type': 'assistant',
              'message': {'content': [{'type': 'tool_use', 'id': 'tu1', 'name': 'Bash', 'input': {'command': 'true'}}],
                          'usage': {'input_tokens': 10, 'cache_read_input_tokens': ctx}}})
        emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'tu1', 'content': 'ok'}]}})
        emit({'type': 'assistant',
              'message': {'content': [{'type': 'text', 'text': 'echo: ' + text[:80]}],
                          'usage': {'input_tokens': 10, 'cache_read_input_tokens': ctx}}})
        emit({'type': 'result', 'subtype': 'success', 'num_turns': 2, 'duration_api_ms': 1200,
              'session_id': sid, 'total_cost_usd': 0.0})
""")


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = os.path.join(self.tmp, "store")
        self.comms = os.path.join(self.tmp, "comms")
        self.stub = os.path.join(self.tmp, "stub.py")
        with open(self.stub, "w") as f:
            f.write(STUB)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self, stdin_lines, env_extra=None, hold=0.0, inbox_msgs=None,
             cwd=None):
        """Run the broker with the stub; optionally drop inbox files mid-run."""
        env = dict(os.environ,
                   MANAGER_CLAUDE_CMD=f"{sys.executable} {self.stub}",
                   COMMS_ROOT=self.comms,
                   POWOS_MANAGER_SAFE="1",   # no --dangerously-skip-permissions
                   NO_COLOR="1")
        if env_extra:
            env.update(env_extra)
        p = subprocess.Popen(
            [sys.executable, BROKER, "--agent-id", "manager",
             "--session-store", self.store],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, env=env, cwd=cwd or self.tmp)
        # feed user lines
        for line in stdin_lines:
            p.stdin.write(line + "\n")
            p.stdin.flush()
            time.sleep(0.1)
        # optionally deliver inbox mail while the session is live
        if inbox_msgs:
            inbox = os.path.join(self.comms, "agents", "manager", "inbox")
            os.makedirs(inbox, exist_ok=True)
            import json as _json
            for i, m in enumerate(inbox_msgs):
                with open(os.path.join(inbox, f"00-{i}.json"), "w") as f:
                    _json.dump(m, f)
            time.sleep(1.6)  # inbox poller runs on a 1s tick
        if hold:
            time.sleep(hold)
        out, _ = p.communicate(timeout=60)
        return out

    def test_echo_roundtrip(self):
        out = self._run(["hello there"])
        self.assertIn("echo: hello there", out)

    def test_two_turns_serialized(self):
        out = self._run(["first", "second"])
        self.assertIn("echo: first", out)
        self.assertIn("echo: second", out)
        self.assertLess(out.index("echo: first"), out.index("echo: second"))

    def test_session_persisted_per_dir(self):
        self._run(["hi"])
        sess_dir = os.path.join(self.store, "sessions")
        files = os.listdir(sess_dir)
        self.assertEqual(len(files), 1)
        with open(os.path.join(sess_dir, files[0])) as f:
            self.assertEqual(f.read().strip(), "stub-session-0001")

    def test_resume_passes_stored_session(self):
        argv_file = os.path.join(self.tmp, "argv.txt")
        # first run creates the session file
        self._run(["one"])
        # second run must resume it — the stub records its argv
        self._run(["two"], env_extra={"STUB_ARGV_FILE": argv_file})
        with open(argv_file) as f:
            argv = f.read()
        self.assertIn("--resume stub-session-0001", argv)

    def test_inbox_message_injected_live(self):
        # No typed input at all — mail alone should drive a turn.
        out = self._run([], inbox_msgs=[
            {"from": "coder", "priority": "high", "body": "build failed on stage C"},
        ])
        self.assertIn("inbox message from agent 'coder'", out)
        self.assertIn("build failed on stage C", out)  # rendered ✉ line
        self.assertIn("echo: [inbox message from agent 'coder'", out)  # reached model

    def test_inbox_with_result_field(self):
        out = self._run([], inbox_msgs=[
            {"from": "health", "priority": "urgent",
             "body": "disk critical", "result": "/, 96% used"},
        ])
        self.assertIn("disk critical", out)
        self.assertIn("/, 96% used", out)


class OnceModeTests(unittest.TestCase):
    """The widget path: one turn, normalized JSONL events, per-dir cwd."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = os.path.join(self.tmp, "store")
        self.stub = os.path.join(self.tmp, "stub.py")
        with open(self.stub, "w") as f:
            f.write(STUB)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _once(self, text, cwd=None, extra=None):
        env = dict(os.environ,
                   MANAGER_CLAUDE_CMD=f"{sys.executable} {self.stub}",
                   POWOS_MANAGER_SAFE="1", NO_COLOR="1")
        args = [sys.executable, BROKER, "--agent-id", "manager",
                "--session-store", self.store, "--json-events",
                "--once", text]
        if cwd:
            args += ["--cwd", cwd]
        if extra:
            args += extra
        p = subprocess.run(args, capture_output=True, text=True, env=env,
                           cwd=self.tmp, timeout=60)
        events = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
        return events

    def test_json_events_shape(self):
        evs = self._once("hello widget")
        kinds = [e["kind"] for e in evs]
        self.assertIn("session", kinds)
        self.assertIn("user", kinds)         # the user's own turn echoed
        self.assertIn("assistant", kinds)
        self.assertIn("turn_done", kinds)
        user = next(e for e in evs if e["kind"] == "user")
        self.assertEqual(user["text"], "hello widget")
        asst = next(e for e in evs if e["kind"] == "assistant")
        self.assertIn("echo: hello widget", asst["text"])

    def test_once_exits_after_one_turn(self):
        # exactly one turn_done — once() must not hang waiting for more.
        evs = self._once("just one")
        self.assertEqual(sum(1 for e in evs if e["kind"] == "turn_done"), 1)

    def test_once_waits_past_an_empty_result(self):
        # A stale housekeeping result (no assistant event) must not end once() before the real answer arrives.
        os.environ['STUB_STALE_RESULT'] = '1'
        try:
            evs = self._once("answer me")
        finally:
            del os.environ['STUB_STALE_RESULT']
        texts = [e.get("text", "") for e in evs if e["kind"] == "assistant"]
        self.assertTrue(any("echo: answer me" in t for t in texts), evs)

    def _turns(self):
        with open(os.path.join(self.store, "turns.jsonl")) as f:
            return [json.loads(l) for l in f if l.strip()]

    def test_turn_log_measures_each_turn(self):
        os.environ["STUB_CTX"] = "5000"
        try:
            self._once("measure me")
        finally:
            del os.environ["STUB_CTX"]
        r = self._turns()[-1]
        self.assertEqual((r["calls"], r["tools"], r["ctx_last"], r["api_s"], r["num_turns"]),
                         (2, {"Bash": 1}, 5010, 1.2, 2), r)
        self.assertGreaterEqual(r["wall_s"], r["startup_s"])
        self.assertIsNone(r["rolled_from"])

    def test_big_session_rolls_over_with_a_handoff(self):
        # A session past POWOS_MANAGER_CTX_MAX isn't resumed: the next turn is a fresh session whose first message is a
        # bounded note of what was said, and the log says which session it rolled from.
        os.environ["STUB_CTX"] = "200000"
        try:
            self._once("first, big")
        finally:
            del os.environ["STUB_CTX"]
        old = self._turns()[-1]["session"]
        argv = os.path.join(self.tmp, "argv")
        os.environ["STUB_ARGV_FILE"] = argv
        try:
            evs = self._once("second")
        finally:
            del os.environ["STUB_ARGV_FILE"]
        self.assertNotIn("--resume", open(argv).read())
        said = " ".join(e.get("text", "") for e in evs if e["kind"] == "assistant")
        self.assertIn("echo: [context: this chat continues in a fresh session", said)
        self.assertEqual(self._turns()[-1]["rolled_from"], old)
        user = next(e for e in evs if e["kind"] == "user")
        self.assertEqual(user["text"], "second")      # the chat shows the user's words, not the note

    def test_cwd_gives_separate_thread(self):
        d1 = os.path.join(self.tmp, "projA"); os.makedirs(d1)
        d2 = os.path.join(self.tmp, "projB"); os.makedirs(d2)
        self._once("hi", cwd=d1)
        self._once("hi", cwd=d2)
        sess = os.path.join(self.store, "sessions")
        files = os.listdir(sess)
        # one session file per distinct working directory
        self.assertEqual(len(files), 2)
        self.assertTrue(any("projA" in f for f in files))
        self.assertTrue(any("projB" in f for f in files))


# A claude that starts answering, then hangs mid-turn (a long reply) - with a child of its own (a tool command), whose
# pid it writes to STUB_CHILD_PID so the test can check it was stopped too.
HANG_STUB = textwrap.dedent("""
    import sys, json, os, subprocess, time
    def emit(o):
        sys.stdout.write(json.dumps(o) + '\\n'); sys.stdout.flush()
    emit({'type': 'system', 'subtype': 'init', 'session_id': 'stub-hang', 'tools': [], 'mcp_servers': []})
    for line in sys.stdin:
        if not line.strip():
            continue
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
        open(os.environ['STUB_CHILD_PID'], 'w').write(str(child.pid))
        emit({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'partial answer'}]}})
        time.sleep(120)
""")


class StopTests(unittest.TestCase):
    """The chat's stop button: `manager.py --stop` ends the one-shot turn under way, end to end."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = os.path.join(self.tmp, "store")
        os.makedirs(self.store)
        self.stub = os.path.join(self.tmp, "hang.py")
        with open(self.stub, "w") as f:
            f.write(HANG_STUB)
        self.child_pid = os.path.join(self.tmp, "child.pid")

    def tearDown(self):
        import shutil
        import signal
        try:   # without /proc (macOS) the broker can't find claude's child: never leave it behind
            os.kill(int(open(self.child_pid).read()), signal.SIGKILL)
        except (OSError, ValueError):
            pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _stop(self):
        return subprocess.run([sys.executable, BROKER, "--session-store", self.store, "--stop"],
                              capture_output=True, text=True, timeout=20)

    def test_stop_ends_the_turn_keeps_the_partial_reply(self):
        env = dict(os.environ, MANAGER_CLAUDE_CMD=f"{sys.executable} {self.stub}", POWOS_MANAGER_SAFE="1",
                   POWOS_MANAGER_ASKS="0", NO_COLOR="1", STUB_CHILD_PID=self.child_pid)
        p = subprocess.Popen([sys.executable, BROKER, "--agent-id", "manager", "--session-store", self.store,
                              "--json-events", "--once", "write me a long essay"],
                             stdout=subprocess.PIPE, text=True, env=env, cwd=self.tmp)
        try:
            # The reply has begun: the partial answer is out.
            first = []
            for line in p.stdout:
                first.append(json.loads(line))
                if first[-1]["kind"] == "assistant":
                    break
            self.assertTrue(os.path.exists(os.path.join(self.store, "turn.pid")))
            t0 = time.time()
            r = self._stop()
            self.assertEqual(r.stdout.strip(), "stopped")
            self.assertEqual(r.returncode, 0)
            rest = [json.loads(l) for l in p.stdout if l.strip()]
            rc = p.wait(timeout=15)
            self.assertLess(time.time() - t0, 8, "the stop took too long")
        finally:
            if p.poll() is None:
                p.kill()
            p.stdout.close()
        self.assertEqual(rc, 5)
        self.assertIn("partial answer", [e.get("text") for e in first])
        self.assertEqual([e["kind"] for e in rest][-1:], ["stopped"])
        self.assertFalse(os.path.exists(os.path.join(self.store, "turn.pid")))
        # claude's own child (a tool command) was stopped too, where /proc lets the broker find it.
        if os.path.isdir("/proc"):
            pid = int(open(self.child_pid).read())
            time.sleep(0.5)
            try:
                with open(f"/proc/{pid}/stat") as f:
                    state = f.read().rsplit(")", 1)[1].split()[0]
            except OSError:
                state = "gone"
            self.assertIn(state, ("gone", "Z"))
        # Nothing running now: a second stop says so.
        r = self._stop()
        self.assertEqual((r.stdout.strip(), r.returncode), ("idle", 1))

    def test_stop_with_nothing_running_or_a_stale_pid(self):
        self.assertEqual(self._stop().stdout.strip(), "idle")
        with open(os.path.join(self.store, "turn.pid"), "w") as f:
            f.write("999999")
        r = self._stop()
        self.assertEqual((r.stdout.strip(), r.returncode), ("idle", 1))


class ListJsonTests(unittest.TestCase):
    """Sidebar data feed for the widget."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = os.path.join(self.tmp, "store")
        self.projects = os.path.join(self.tmp, "Projects")
        self.comms = os.path.join(self.tmp, "comms")
        for p in ("Alpha", "Beta"):
            os.makedirs(os.path.join(self.projects, p))
        os.makedirs(os.path.join(self.comms, "agents", "coder", "inbox"))
        with open(os.path.join(self.comms, "agents", "coder", "inbox", "m.json"), "w") as f:
            f.write("{}")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _list(self):
        env = dict(os.environ, POWOS_PROJECTS_DIR=self.projects,
                   COMMS_ROOT=self.comms)
        p = subprocess.run(
            [sys.executable, BROKER, "--session-store", self.store, "--list-json"],
            capture_output=True, text=True, env=env, timeout=30)
        return json.loads(p.stdout)

    def test_lists_projects_and_agents(self):
        data = self._list()
        names = [p["name"] for p in data["projects"]]
        self.assertEqual(names, ["Alpha", "Beta"])
        agents = {a["name"]: a["pending"] for a in data["agents"]}
        # known roster present even with no inbox…
        self.assertIn("manager", agents)
        self.assertIn("devops", agents)
        # …and real inbox depth is reflected
        self.assertEqual(agents["coder"], 1)

    def test_hassession_reflects_store(self):
        # give Alpha a session, Beta none
        SESS = os.path.join(self.store, "sessions")
        os.makedirs(SESS, exist_ok=True)
        alpha = os.path.join(self.projects, "Alpha").replace("/", "-").strip("-")
        with open(os.path.join(SESS, alpha + ".session"), "w") as f:
            f.write("sess-xyz")
        data = self._list()
        byname = {p["name"]: p["hasSession"] for p in data["projects"]}
        self.assertTrue(byname["Alpha"])
        self.assertFalse(byname["Beta"])



class RichBlockTests(unittest.TestCase):
    """present / present_choices calls become fenced blocks in the assistant's text (what the chat renders)."""

    @classmethod
    def setUpClass(cls):
        import importlib.util
        spec = importlib.util.spec_from_file_location("powos_manager", BROKER)
        cls.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.m)
        cls.M = next(v for v in vars(cls.m).values() if isinstance(v, type) and hasattr(v, "_rich_block"))

    def block(self, name, inp):
        text = self.M._rich_block(name, inp)
        if text is None:
            return None, None
        head, body, tail = text.split("\n")
        self.assertEqual(tail, "```")
        return head, json.loads(body)

    def test_choices(self):
        head, data = self.block("mcp__comms__present_choices", {"question": "Which?", "options": ["a", " ", "b"], "multi": True})
        self.assertEqual(head, "```choices")
        self.assertEqual(data["options"], ["a", "b"])
        self.assertTrue(data["multi"])

    def test_present_html_and_md(self):
        head, data = self.block("mcp__comms__present", {"title": "Plan", "format": "html", "body": "<h1>x</h1>"})
        self.assertEqual((head, data["format"], data["title"]), ("```present", "html", "Plan"))
        self.assertEqual(self.block("mcp__comms__present", {"title": "T", "body": "# x"})[1]["format"], "md")

    def test_try_keeps_items_with_an_id_and_a_line(self):
        head, data = self.block("mcp__comms__present_try", {"title": "2 things ready", "items": [
            {"id": "overlap", "line": "Tap the window behind"}, {"id": "plug", "line": "Plug it in", "do": True},
            {"id": "", "line": "no id"}, {"id": "x", "line": " "}]})
        self.assertEqual(head, "```try")
        self.assertEqual(data["items"], [{"id": "overlap", "line": "Tap the window behind"}, {"id": "plug", "line": "Plug it in", "do": True}])
        self.assertEqual(self.block("mcp__comms__present_try", {"items": []}), (None, None))

    def test_other_tools_and_empty_bodies_show_nothing(self):
        self.assertEqual(self.block("Bash", {"command": "ls"}), (None, None))
        self.assertEqual(self.block("mcp__comms__present", {"title": "T", "body": "  "}), (None, None))

    def test_result_out_keeps_lines(self):
        self.assertEqual(self.M._result_out([{"type": "text", "text": "a\nb"}]), "a\nb")
        self.assertTrue(self.M._result_out("x" * 3000).endswith("…"))

if __name__ == "__main__":
    unittest.main(verbosity=2)
