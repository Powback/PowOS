#!/usr/bin/env python3
"""Tier-1 tests for the context-budget half of .claude/hooks/agent-notices.py (AGENT-HANDBOOK.md,
Efficiency: hand back by 120k, never resume an agent past 150k - made mechanical instead of self-policed).

Hermetic: drives the real hook script as a subprocess, stdin JSON in, stdout JSON out, against a fake
transcript file (a JSONL file with one assistant-message line carrying a given `usage`) and an isolated
HOME (so a real ~/.cache/powos-agent-notices or comms/verify/ship state never leaks in or out).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
HOOK = os.path.join(REPO, ".claude", "hooks", "agent-notices.py")


def usage_line(input_tokens, cache_read=0, cache_creation=0):
    return json.dumps({
        "type": "assistant",
        "timestamp": "2026-10-24T00:00:00Z",
        "message": {
            "id": "msg_1",
            "usage": {
                "input_tokens": input_tokens,
                "cache_read_input_tokens": cache_read,
                "cache_creation_input_tokens": cache_creation,
                "output_tokens": 12,
            },
        },
    })


class ContextBudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home, exist_ok=True)
        self.cwd = os.path.join(self.tmp, "worktree")
        os.makedirs(self.cwd, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_transcript(self, name, *ctx_tokens):
        """One line per ctx value, in order - the hook must use the LAST one (the latest assistant msg)."""
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            for ctx in ctx_tokens:
                f.write(usage_line(ctx) + "\n")
        return path

    def run_hook(self, transcript_path=None, session_id="sess-1", extra=None):
        payload = {"cwd": self.cwd, "session_id": session_id, "hook_event_name": "PostToolUse",
                   "tool_name": "Bash", "tool_input": {"command": "true"}}
        if transcript_path is not None:
            payload["transcript_path"] = transcript_path
        if extra:
            payload.update(extra)
        env = {k: v for k, v in os.environ.items()
               if k not in ("COMMS_AGENT_ID", "POWOS_AGENTS_ROLE", "XDG_STATE_HOME")}
        env["HOME"] = self.home  # isolate from the real ~/.cache/powos-agent-notices state
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10, env=env)
        self.assertEqual(p.returncode, 0, f"hook must always exit 0 (fail-silent): {p.stderr}")
        self.assertEqual(p.stderr, "", f"hook must never write to stderr: {p.stderr}")
        return p.stdout.strip()

    def notice_text(self, out):
        if not out:
            return ""
        return json.loads(out)["hookSpecificOutput"]["additionalContext"]

    # -- 90k: under the 120k hand-back floor - silent -------------------------------------------------
    def test_under_120k_is_silent(self):
        t = self.write_transcript("t90.jsonl", 90_000)
        out = self.run_hook(t)
        self.assertEqual(out, "", "no notice at all below 120k")

    # -- 130k: over 120k, under 150k - the soft reminder, mentioning the hand-back note contents -------
    def test_over_120k_under_150k_reminds_once(self):
        t = self.write_transcript("t130.jsonl", 130_000)
        out = self.run_hook(t, session_id="sess-a")
        text = self.notice_text(out)
        self.assertIn("[context]", text)
        self.assertIn("130k", text)
        self.assertIn("hand back", text)
        self.assertIn("Friction & missing info", text)
        # same session, same 20k bucket, called again -> deduped, no repeat notice.
        out2 = self.run_hook(t, session_id="sess-a")
        self.assertEqual(out2, "", "the same 20k bucket for the same session is reported only once")
        # a DIFFERENT session at the same context starts its own count -> reminded again.
        out3 = self.run_hook(t, session_id="sess-b")
        self.assertIn("130k", self.notice_text(out3))

    def test_120k_to_150k_buckets_every_20k(self):
        t120 = self.write_transcript("t120.jsonl", 120_000)
        t139 = self.write_transcript("t139.jsonl", 139_000)
        t140 = self.write_transcript("t140.jsonl", 140_000)
        sess = "sess-bucket"
        self.assertIn("120k", self.notice_text(self.run_hook(t120, session_id=sess)))
        # still in the 120k bucket (120k-139999) - no repeat.
        self.assertEqual(self.run_hook(t139, session_id=sess), "")
        # crossed into the 140k bucket - reminds again.
        self.assertIn("140k", self.notice_text(self.run_hook(t140, session_id=sess)))

    # -- 160k: over the 150k hard budget - fires on EVERY call, never deduped --------------------------
    def test_over_150k_fires_every_call(self):
        t = self.write_transcript("t160.jsonl", 160_000)
        for _ in range(3):
            text = self.notice_text(self.run_hook(t, session_id="sess-hard"))
            self.assertIn("160k", text)
            self.assertIn("past the 150k budget", text)
            self.assertIn("hand back NOW", text)
            self.assertIn("Friction & missing info", text)

    # -- uses the LATEST assistant message in the transcript, not an earlier one -----------------------
    def test_uses_latest_assistant_message(self):
        t = self.write_transcript("tmulti.jsonl", 10_000, 160_000, 50_000)
        text = self.notice_text(self.run_hook(t, session_id="sess-latest"))
        self.assertEqual(text, "", "the LAST line (50k) is under budget, so no notice - an earlier 160k line must not leak through")

    # -- fail-silent edges: never a crash, never stderr, exit 0 ----------------------------------------
    def test_no_transcript_path_is_silent(self):
        self.assertEqual(self.run_hook(transcript_path=None), "")

    def test_missing_transcript_file_is_silent(self):
        missing = os.path.join(self.tmp, "does-not-exist.jsonl")
        self.assertEqual(self.run_hook(missing), "")

    def test_garbage_transcript_is_silent(self):
        path = os.path.join(self.tmp, "garbage.jsonl")
        with open(path, "w") as f:
            f.write("not json at all\n{broken\n")
        self.assertEqual(self.run_hook(path), "")

    def test_no_stdin_json_is_silent(self):
        p = subprocess.run([sys.executable, HOOK], input="not json", capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")
        self.assertEqual(p.stderr, "")

    # -- reads only the TAIL, so this stays fast even on a very large transcript -----------------------
    def test_reads_only_the_tail_of_a_huge_transcript(self):
        path = os.path.join(self.tmp, "huge.jsonl")
        with open(path, "w") as f:
            for _ in range(2000):
                f.write(json.dumps({"type": "assistant", "message": {"usage": {
                    "input_tokens": 1000, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}}) + "\n")
            f.write(usage_line(155_000) + "\n")
        import time
        t0 = time.time()
        text = self.notice_text(self.run_hook(path, session_id="sess-huge"))
        self.assertLess(time.time() - t0, 5, "must stay fast on a long transcript (tail read only)")
        self.assertIn("155k", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
