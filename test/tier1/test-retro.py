#!/usr/bin/env python3
"""tools/agents/retro.py, hermetic: a hand-built fake transcript exercising every friction kind it digests -
a permission refusal, a tool error, a Bash retry, an information hunt + a 3x-reread file, a wait/sleep, a
"not a real failure" misleading check, a secret that must be redacted, and a `friction add` call. No network:
the board lookup is best-effort and must degrade to "unknown" rather than fail when unreachable.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RETRO = os.path.normpath(os.path.join(HERE, "..", "..", "tools", "agents", "retro.py"))


def msg(mid, tool_uses=None, text=None, usage=None):
    content = []
    if text is not None:
        content.append({"type": "text", "text": text})
    for tu in tool_uses or []:
        content.append({"type": "tool_use", "id": tu["id"], "name": tu["name"], "input": tu["input"]})
    return json.dumps({"type": "assistant", "timestamp": "2026-10-24T00:00",
                        "message": {"id": mid, "usage": usage or {"input_tokens": 100}, "content": content}})


def result(tool_use_id, text, is_error=False):
    return json.dumps({"type": "user", "timestamp": "2026-10-24T00:00",
                        "message": {"content": [{"type": "tool_result", "tool_use_id": tool_use_id,
                                                  "is_error": is_error, "content": text}]}})


def build_transcript(path):
    lines = []
    # 1. a permission refusal (Bash)
    lines.append(msg("m1", [{"id": "t1", "name": "Bash", "input": {"command": "rm -rf /important"}}]))
    lines.append(result("t1", "Permission for this command was denied by a built-in Claude Code safety check.",
                         is_error=True))
    # 2. a plain tool error
    lines.append(msg("m2", [{"id": "t2", "name": "Bash", "input": {"command": "cat missing.txt"}}]))
    lines.append(result("t2", "cat: missing.txt: No such file or directory", is_error=True))
    # 3. a retried Bash command (same command 3x)
    for i in range(3):
        lines.append(msg(f"m3{i}", [{"id": f"t3{i}", "name": "Bash",
                                      "input": {"command": "grep -rn foo some/big/tree"}}]))
        lines.append(result(f"t3{i}", "no matches"))
    # 4. an information hunt: several reads/greps before the first edit, one file read 3x
    for i in range(4):
        lines.append(msg(f"m4{i}", [{"id": f"t4{i}", "name": "Read", "input": {"file_path": "/repo/a.py"}}]))
        lines.append(result(f"t4{i}", "file contents"))
    lines.append(msg("m4g", [{"id": "t4g", "name": "Grep", "input": {"pattern": "where is X"}}]))
    lines.append(result("t4g", "no matches"))
    lines.append(msg("m5", [{"id": "t5", "name": "Edit", "input": {"file_path": "/repo/a.py"}}]))
    lines.append(result("t5", "ok"))
    # 5. a long sleep (wait/poll category, via efficiency.py's CATS)
    lines.append(msg("m6", [{"id": "t6", "name": "Bash", "input": {"command": "sleep 90; echo done"}}]))
    lines.append(result("t6", "done"))
    # 6. a misleading check: FAIL then an acknowledgement it wasn't real
    lines.append(msg("m7", text="Ran the gate: FAIL widgets: baseline mismatch. ... "
                                 "turns out it wasn't a real failure - stale baseline, not a regression."))
    # 7. a secret that must never reach the digest, in a command AND its error output (exercises redaction on
    # both the short-command path and the error-cause path; "Permission denied" here is the OS kind, not the
    # classifier kind item 1 covers, so it lands as its own error cause)
    lines.append(msg("m8", [{"id": "t8", "name": "Bash",
                              "input": {"command": "curl -H 'Authorization: Bearer sk-ant-abcdEFGH12345678901234' x"}}]))
    lines.append(result("t8", "bash: sk-ant-abcdEFGH12345678901234: Permission denied", is_error=True))
    # 8. logged friction
    lines.append(msg("m9", [{"id": "t9", "name": "Bash",
                              "input": {"command": 'tools/agents/friction add --area gate --kind slow '
                                                    '"the gate took 9 minutes" --repro "run gate.sh"'}}]))
    lines.append(result("t9", "logged friction f123"))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


class TestRetro(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".jsonl")
        os.close(fd)
        build_transcript(self.path)

    def tearDown(self):
        os.unlink(self.path)

    def run_retro(self, *args):
        out = subprocess.run([sys.executable, RETRO, self.path, *args],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout

    def test_json_digest_finds_every_kind(self):
        d = json.loads(self.run_retro("--json"))
        self.assertEqual([c[1] for c in d["permissions"]], [1])
        self.assertTrue(any("no such file" in c for c, _ in d["errors"]))
        self.assertTrue(any(n >= 3 for _, n in d["retries"]))
        self.assertGreaterEqual(d["hunt_before_edit"], 4)
        self.assertTrue(any(n >= 3 for _, n in d["reread_files"]))
        self.assertGreaterEqual(d["waits"], 1)
        self.assertTrue(d["long_sleeps"])
        self.assertTrue(d["misled"])
        self.assertEqual(len(d["friction"]), 1)
        self.assertIn("gate took 9 minutes", d["friction"][0]["title"])

    def test_text_digest_is_short_and_redacts_secrets(self):
        out = self.run_retro()
        lines = [l for l in out.splitlines() if l]
        self.assertLessEqual(len(lines), 60)
        self.assertNotIn("sk-ant-abcdEFGH12345678901234", out)
        self.assertIn("[REDACTED]", out)  # the secret command/error must be redacted, not just omitted
        self.assertIn("permission refusals", out)
        self.assertIn("retries", out)

    def test_unknown_ref_fails_cleanly(self):
        out = subprocess.run([sys.executable, RETRO, "no-such-agent-id-xyz"],
                              capture_output=True, text=True, timeout=10)
        self.assertNotEqual(out.returncode, 0)


if __name__ == "__main__":
    unittest.main()
