#!/usr/bin/env python3
"""Tier-1 tests for the context-budget half of .claude/hooks/agent-notices.py (AGENT-HANDBOOK.md,
Efficiency: hand back by 120k, never resume an agent past 150k - made mechanical instead of self-policed).

Hermetic: drives the real hook script as a subprocess, stdin JSON in, stdout JSON out, against a fake
transcript file (a JSONL file with one assistant-message line carrying a given `usage`) and an isolated
HOME (so a real ~/.cache/powos-agent-notices or comms/verify/ship state never leaks in or out).
"""

import datetime
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
    # Real "now", not a fixed past date: these transcripts exist only to test the CONTEXT budget, and
    # with the wall-clock budget hook reading real elapsed time, a stale timestamp would spuriously
    # trip the time notice (the 4/5-min budget) on every one of these.
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return json.dumps({
        "type": "assistant",
        "timestamp": now,
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

    def write_aged_transcript(self, name, minutes_ago, ctx_tokens=10_000):
        """A transcript whose FIRST entry's timestamp is `minutes_ago` minutes before real now (the
        wall-clock budget is measured from that first entry) - a second, later line is low on context
        so only the time budget notice can fire, never the context one."""
        path = os.path.join(self.tmp, name)
        first_ts = (datetime.datetime.now(datetime.timezone.utc)
                    - datetime.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        with open(path, "w") as f:
            f.write(json.dumps({"type": "user", "timestamp": first_ts, "message": {}}) + "\n")
            line = json.loads(usage_line(ctx_tokens))
            line["timestamp"] = first_ts
            f.write(json.dumps(line) + "\n")
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

    # -- wall-clock budget (the user: "aim for max 5 min per agent per task"), measured from the
    # transcript's first entry timestamp - a separate axis from context size. --------------------------
    def test_under_4min_is_silent(self):
        t = self.write_aged_transcript("w3.jsonl", 3)
        self.assertEqual(self.run_hook(t, session_id="sess-w3"), "", "no time notice under 4 min")

    def test_over_4min_under_5min_reminds_once(self):
        t = self.write_aged_transcript("w4_5.jsonl", 4.5)
        out = self.run_hook(t, session_id="sess-w4")
        text = self.notice_text(out)
        self.assertIn("[time]", text)
        self.assertIn("4 min", text)
        self.assertIn("land what works now", text)
        self.assertIn("tools/agents/land.sh", text)
        self.assertIn("Friction & missing info", text)
        # same session, called again still between 4 and 5 min -> deduped, no repeat.
        out2 = self.run_hook(t, session_id="sess-w4")
        self.assertEqual(out2, "", "the 4-min notice is reported only once per session")
        # a DIFFERENT session re-reads the head and starts its own count -> reminded again.
        out3 = self.run_hook(t, session_id="sess-w4b")
        self.assertIn("4 min", self.notice_text(out3))

    def test_over_5min_fires_every_call(self):
        t = self.write_aged_transcript("w6.jsonl", 6)
        for _ in range(3):
            text = self.notice_text(self.run_hook(t, session_id="sess-w6"))
            self.assertIn("[time]", text)
            self.assertIn("past 5 min", text)
            self.assertIn("land and hand back NOW", text)

    def test_time_budget_caches_first_timestamp_per_session(self):
        """The hook reads the transcript HEAD once per session (cached to disk - every hook call is a
        fresh process) - appending more lines after the first read must not move the cached start time."""
        t = self.write_aged_transcript("wcache.jsonl", 4.5)
        first = self.notice_text(self.run_hook(t, session_id="sess-cache"))
        self.assertIn("4 min", first)
        # Append a line as if the transcript grew; the FIRST entry (what the cache keyed off) is unchanged,
        # so a second call in the same 4-5min bucket for this session is still deduped, not re-triggered.
        with open(t, "a") as f:
            f.write(usage_line(10_000) + "\n")
        self.assertEqual(self.run_hook(t, session_id="sess-cache"), "")

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
