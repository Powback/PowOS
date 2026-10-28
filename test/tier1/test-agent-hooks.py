#!/usr/bin/env python3
"""Tier-1 tests for the context-hygiene rules in .claude/hooks/wait-guard.py (poll guard, sectioned Reads,
output caps) and the once-only agent card in .claude/hooks/agent-notices.py. Hermetic: HOME is a temp dir."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
GUARD = os.path.join(REPO, ".claude", "hooks", "wait-guard.py")
MISTAKE = os.path.join(REPO, ".claude", "hooks", "mistake-guard.py")
NOTICES = os.path.join(REPO, ".claude", "hooks", "agent-notices.py")
SUB = "/h/.claude/projects/p/s/subagents/agent-1.jsonl"


class T(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.env = dict(os.environ, HOME=self.home.name)
        self.big = os.path.join(self.home.name, "big.txt")
        with open(self.big, "w") as f:
            f.write("line\n" * 500)
        self.small = os.path.join(self.home.name, "small.txt")
        with open(self.small, "w") as f:
            f.write("line\n" * 50)
        self.sess = self.id()

    def run_hook(self, hook, tool, tool_input, transcript=SUB):
        p = {"hook_event_name": "x", "tool_name": tool, "tool_input": tool_input, "transcript_path": transcript,
             "cwd": self.home.name, "session_id": self.sess}
        r = subprocess.run([sys.executable, hook], input=json.dumps(p), capture_output=True, text=True,
                           timeout=10, env=self.env)
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        return r.stdout.strip()

    def bash(self, cmd, **kw):
        return self.run_hook(GUARD, "Bash", dict({"command": cmd}, **kw))

    def read(self, **ti):
        return self.run_hook(GUARD, "Read", ti)

    def assertDenied(self, out, needle=""):
        self.assertNotEqual(out, "", "expected deny")
        d = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(d["permissionDecision"], "deny")
        self.assertIn(needle, d["permissionDecisionReason"])

    # -- polls
    def test_repeated_poll_denied(self):
        self.assertEqual(self.bash("tools/phone/verify/queue.sh list"), "")
        self.assertDenied(self.bash("tools/phone/verify/queue.sh  list"), "queue.sh wait")

    def test_poll_after_window_or_background_ok(self):
        self.assertEqual(self.bash("tail -3 ~/.cache/powos-verify-queue/runner.log"), "")
        self.assertEqual(self.bash("tail -3 ~/.cache/powos-verify-queue/runner.log", run_in_background=True), "")
        for i in range(9):
            self.bash(f"echo {i}")
        self.assertEqual(self.bash("tail -3 ~/.cache/powos-verify-queue/runner.log"), "")

    def test_different_commands_and_non_subagent_ok(self):
        self.assertEqual(self.bash("git status"), "")
        self.assertEqual(self.bash("git status"), "")
        self.assertEqual(self.run_hook(GUARD, "Bash", {"command": "queue.sh list"}, transcript="/h/s.jsonl"), "")
        self.assertEqual(self.run_hook(GUARD, "Bash", {"command": "queue.sh list"}, transcript="/h/s.jsonl"), "")

    # -- reads
    def test_whole_big_read_denied(self):
        self.assertDenied(self.read(file_path=self.big), "500 lines")

    def test_read_ok_cases(self):
        self.assertEqual(self.read(file_path=self.big, limit=50), "")
        self.assertEqual(self.read(file_path=self.big, offset=10), "")
        self.assertEqual(self.read(file_path=self.small), "")
        self.assertEqual(self.read(file_path=self.big + ".png"), "")
        self.assertEqual(self.read(file_path="/nonexistent/x"), "")
        self.assertEqual(self.run_hook(GUARD, "Read", {"file_path": self.big}, transcript="/h/s.jsonl"), "")

    # -- bash output caps
    def test_cat(self):
        self.assertDenied(self.bash(f"cat {self.big}"), "grep -n")
        self.assertDenied(self.bash(f"cd {self.home.name} && cat big.txt"), "grep -n")
        self.assertEqual(self.bash(f"cat {self.small}"), "")
        self.assertEqual(self.bash(f"cat {self.big} | head -5"), "")

    def test_grep_recursive(self):
        self.assertDenied(self.bash("grep -rn foo shell/"), "head")
        self.assertDenied(self.bash("grep -R foo ."), "head")
        for ok in ("grep -rn foo shell/ | head -20", "grep -rln foo .", "grep -rc foo .", "grep -rn -m 5 foo .",
                   "grep -n foo file.txt", "git grep -n foo", "grep -rn foo . | wc -l"):
            self.assertEqual(self.bash(ok), "", ok)

    def test_sed_range(self):
        self.assertDenied(self.bash("sed -n '1,400p' f.md"), "cap 150")
        self.assertDenied(self.bash("sed -n '1,200p' f.md"), "cap 150")
        self.assertEqual(self.bash("sed -n '10,100p' f.md"), "")

    def test_poll_shapes_hint_wait_sh(self):
        for c in ("pgrep -f gate.sh", "sleep 30", "tail -5 /tmp/x.log"):
            self.assertEqual(self.bash(c), "", c)
            self.assertDenied(self.bash(c), "wait.sh")

    def test_mistake_guard(self):
        mg = lambda c, **k: self.run_hook(MISTAKE, "Bash", {"command": c})
        for bad, needle in (("cd x && timeout 30 make test", "alarm 30; exec @ARGV' make test"),
                            ("grep -rn foo . --include=*.ts | head", "--include='*.ts'"),
                            ("sed -i 's/a/b/' f", "sed -i ''"), ("source <(foo env)", "eval"),
                            ("tools/phone/pull-root.sh /data/x/a.jpg /tmp/a.jpg", "DIRECTORY")):
            self.assertDenied(mg(bad), needle)
        for ok in ("perl -e 'alarm 5; exec @ARGV' ls", "grep -rn foo . --include='*.ts' | head", "grep -rn x --include=\"*.ts\" . | head -3",
                   "sed -i '' 's/a/b/' f", "sed -i.bak 's/a/b/' f", "sed -i .bak 's/a/b/' f", "docker exec c sed -i 's/a/b/' f",
                   "eval \"$(foo env)\"", "tools/phone/pull-root.sh /data/x/a.jpg /tmp/d/", "echo timeout 5", "gtimeout 5 ls"):
            self.assertEqual(mg(ok), "", ok)
        self.assertEqual(self.run_hook(MISTAKE, "Bash", {"command": "timeout 5 ls"}, transcript="/h/s.jsonl"), "")

    def test_wait_sh(self):
        w = os.path.join(REPO, "tools", "agents", "wait.sh")
        f = os.path.join(self.home.name, "g.log")
        open(f, "w").write("a\nFAIL x\nPASS y\n")
        r = subprocess.run([w, f, "5"], capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0)
        self.assertIn("PASS y", r.stdout)
        r = subprocess.run([w, "true foo", "5"], capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0)
        r = subprocess.run([w, os.path.join(self.home.name, "none"), "1"], capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 124)

    # -- card
    def test_card_once_and_subagent_only(self):
        o1 = self.run_hook(NOTICES, "Bash", {"command": "ls"})
        ctx = json.loads(o1)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("[agent-card]", ctx)
        self.assertIn("friction add", ctx)
        self.assertNotIn("[agent-card]", self.run_hook(NOTICES, "Bash", {"command": "ls"}))
        self.sess = "other"
        self.assertEqual(self.run_hook(NOTICES, "Bash", {"command": "ls"}, transcript="/h/s.jsonl"), "")

    def test_card_size(self):
        n = len(open(os.path.join(REPO, "docs", "AGENT-CARD.md")).read())
        self.assertLess(n, 6000, "card must stay ~1.5k tokens")


if __name__ == "__main__":
    unittest.main()
