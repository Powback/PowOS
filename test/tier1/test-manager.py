#!/usr/bin/env python3
"""Tier-1 tests for the PowOS Manager broker (lib/ai/manager/manager.py).

Hermetic: a fake `claude` stub speaks the same stream-json protocol, so the
broker's real logic — session capture/resume, per-dir memory, two-writer
serialization, and LIVE comms-inbox injection — is exercised with no real
`claude`, no network, no desktop.
"""

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
        text = ''
        for b in ev.get('message', {}).get('content', []):
            if b.get('type') == 'text':
                text = b['text']
        emit({'type': 'assistant',
              'message': {'content': [{'type': 'text', 'text': 'echo: ' + text[:80]}]}})
        emit({'type': 'result', 'subtype': 'success',
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
        enc = os.getcwd  # not used; encode cwd like the broker does
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
