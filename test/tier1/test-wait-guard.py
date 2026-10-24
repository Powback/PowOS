#!/usr/bin/env python3
"""Tier-1 tests for .claude/hooks/wait-guard.py (AGENT-HANDBOOK.md, Efficiency: never hand-roll a wait
loop - put the long-running thing in the background and let agent-notices.py deliver the result).

Hermetic: drives the real hook script as a subprocess, fake PreToolUse JSON in, stdout JSON (or nothing)
out. No filesystem state, no HOME isolation needed - the hook only reads its stdin JSON.
"""

import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
HOOK = os.path.join(REPO, ".claude", "hooks", "wait-guard.py")

SUB_TRANSCRIPT = "/home/user/.claude/projects/foo/sess-1/subagents/agent-xyz.jsonl"
MAIN_TRANSCRIPT = "/home/user/.claude/projects/foo/sess-1.jsonl"


class WaitGuardTests(unittest.TestCase):
    def run_hook(self, command, transcript_path=SUB_TRANSCRIPT, run_in_background=None, tool_name="Bash"):
        tool_input = {"command": command}
        if run_in_background is not None:
            tool_input["run_in_background"] = run_in_background
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": tool_name,
            "tool_input": tool_input,
            "transcript_path": transcript_path,
            "cwd": "/home/user/pw/some-worktree",
            "session_id": "sess-1",
        }
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10)
        self.assertEqual(p.returncode, 0, f"hook must always exit 0 (fail-silent): {p.stderr}")
        self.assertEqual(p.stderr, "", f"hook must never write to stderr: {p.stderr}")
        return p.stdout.strip()

    def assertDenied(self, out, needle=None):
        self.assertNotEqual(out, "", "expected a deny decision, got no output")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["hookEventName"], "PreToolUse")
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertTrue(decision["permissionDecisionReason"], "deny must carry a reason")
        if needle:
            self.assertIn(needle, decision["permissionDecisionReason"])
        return decision

    def assertAllowed(self, out):
        self.assertEqual(out, "", "expected no decision (defer/allow), got a deny")

    # -- the two denied shapes --------------------------------------------------------------------
    def test_busy_spin_loop_is_denied(self):
        out = self.run_hook("while pgrep -f some-job >/dev/null; do :; done")
        self.assertDenied(out, "run_in_background")

    def test_busy_spin_loop_true_variant_is_denied(self):
        out = self.run_hook("until curl -sf http://x/ready; do true; done")
        self.assertDenied(out, "run_in_background")

    def test_spin_loop_denied_even_if_backgrounded(self):
        # A no-op spin never does anything useful, backgrounded or not - still denied.
        out = self.run_hook("while pgrep -f some-job >/dev/null; do :; done", run_in_background=True)
        self.assertDenied(out)

    def test_sleep_wait_loop_not_backgrounded_is_denied(self):
        out = self.run_hook("until [ -f /tmp/done ]; do sleep 5; done")
        self.assertDenied(out, "run_in_background")

    def test_sleep_wait_loop_multiline_not_backgrounded_is_denied(self):
        out = self.run_hook("while ! curl -sf http://x/health; do\n  sleep 10\ndone")
        self.assertDenied(out)

    # -- the allowed shapes ------------------------------------------------------------------------
    def test_sleep_wait_loop_backgrounded_is_allowed(self):
        out = self.run_hook("until [ -f /tmp/done ]; do sleep 5; done", run_in_background=True)
        self.assertAllowed(out)

    def test_plain_command_is_allowed(self):
        out = self.run_hook("git status")
        self.assertAllowed(out)

    def test_loop_with_real_work_and_sleep_backoff_is_allowed_when_backgrounded(self):
        out = self.run_hook("for f in a b c; do process \"$f\"; done", run_in_background=True)
        self.assertAllowed(out)

    # -- scoping: subagents only, Bash only ---------------------------------------------------------
    def test_main_session_is_allowed_even_for_a_spin_loop(self):
        out = self.run_hook("while pgrep -f some-job >/dev/null; do :; done", transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)

    def test_main_session_is_allowed_for_a_blocking_sleep_loop(self):
        out = self.run_hook("until [ -f /tmp/done ]; do sleep 5; done", transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)

    def test_non_bash_tool_is_ignored(self):
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": {"file_path": "/tmp/x"},
            "transcript_path": SUB_TRANSCRIPT,
            "cwd": "/home/user/pw/some-worktree",
            "session_id": "sess-1",
        }
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")

    def test_malformed_stdin_fails_silent(self):
        p = subprocess.run([sys.executable, HOOK], input="not json", capture_output=True, text=True,
                            timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")
        self.assertEqual(p.stderr, "")


if __name__ == "__main__":
    unittest.main()
