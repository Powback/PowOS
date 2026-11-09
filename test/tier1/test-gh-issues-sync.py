#!/usr/bin/env python3
"""tools/agents/gh-issues-sync.py, hermetic (fake `gh` and a fake board CLI): an open issue no task links becomes ONE
queued task (title + link in the note) and isn't imported twice; an issue linked to a task that is done with a passed
check + a commit gets the evidence as a comment and is closed; done WITHOUT evidence, or a linked task still open,
leaves it open."""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SYNC = os.path.join(ROOT, "tools", "agents", "gh-issues-sync.py")
U = "https://github.com/Powback/PowOS/issues/"

FAKE_BOARD = r'''#!/usr/bin/env python3
import json, os, sys
st = os.environ["FAKE_STATE"]
tasks = json.load(open(st + "/tasks.json"))
a = sys.argv[1:]
if a[:2] == ["task", "list"]:
    print(json.dumps(tasks))
elif a[:2] == ["task", "add"]:
    o = dict(zip(a[3::2], a[4::2]))
    tasks.append({"id": "t%d" % len(tasks), "title": a[2], "status": o["--status"], "note": o["--note"], "commits": "[]"})
    json.dump(tasks, open(st + "/tasks.json", "w"))
elif a[:2] == ["check", "list"]:
    print(json.dumps(json.load(open(st + "/checks.json")).get(a[2], [])))
else:
    sys.exit(2)
'''

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
st = os.environ["FAKE_STATE"]
a = sys.argv[1:]
issues = json.load(open(st + "/issues.json"))
if a[:2] == ["issue", "list"]:
    print(json.dumps([i for i in issues if i["state"] == "open"]))
elif a[:2] == ["issue", "close"]:
    n = int(a[2]); body = a[a.index("--comment") + 1]
    for i in issues:
        if i["number"] == n:
            i["state"] = "closed"; i["comment"] = body
    json.dump(issues, open(st + "/issues.json", "w"))
else:
    sys.exit(2)
'''


class Sync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gh-sync-")
        b = os.path.join(self.tmp, "bin")
        os.mkdir(b)
        for name, src in (("gh", FAKE_GH), ("board", FAKE_BOARD)):
            p = os.path.join(b, name)
            with open(p, "w") as f:
                f.write(src)
            os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
        self.env = dict(os.environ, PATH=b + os.pathsep + os.environ["PATH"], FAKE_STATE=self.tmp,
                        POWOS_AGENTS_CLI=os.path.join(b, "board"))
        self.write("issues.json", [
            {"number": 1, "title": "New bug", "body": "## What\nIt breaks.\n| a | b |\n🤖 bot", "url": U + "1", "state": "open"},
            {"number": 2, "title": "Fixed bug", "body": "x", "url": U + "2", "state": "open"},
            {"number": 3, "title": "Done, no proof", "body": "x", "url": U + "3", "state": "open"},
            {"number": 4, "title": "Still working", "body": "x", "url": U + "4", "state": "open"},
        ])
        sha = json.dumps([{"sha": "abc123def4567", "subject": "fix the bug"}])
        self.write("tasks.json", [
            {"id": "fixed", "title": "Fixed bug", "status": "done", "note": "see " + U + "2", "commits": sha},
            {"id": "noproof", "title": "Done, no proof", "status": "done", "note": U + "3", "commits": sha},
            {"id": "busy", "title": "Still working", "status": "working", "note": U + "4", "commits": "[]"},
        ])
        self.write("checks.json", {"fixed": [{"job": "j1", "name": "the bug is gone", "state": "pass", "line": "PASS"}],
                                   "noproof": [{"job": "j2", "name": "x", "state": "fail"}]})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, obj):
        with open(os.path.join(self.tmp, name), "w") as f:
            json.dump(obj, f)

    def read(self, name):
        with open(os.path.join(self.tmp, name)) as f:
            return json.load(f)

    def sync(self, *a):
        r = subprocess.run([sys.executable, SYNC, *a], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_dry_run_changes_nothing(self):
        out = self.sync("--dry-run")
        self.assertIn("import #1", out)
        self.assertIn("close #2", out)
        self.assertEqual(len(self.read("tasks.json")), 3)
        self.assertTrue(all(i["state"] == "open" for i in self.read("issues.json")))

    def test_import_and_close(self):
        self.sync()
        tasks = self.read("tasks.json")
        new = [t for t in tasks if t["title"] == "New bug"]
        self.assertEqual(len(new), 1)
        self.assertEqual(new[0]["status"], "queued")
        self.assertIn(U + "1", new[0]["note"])
        self.assertIn("It breaks.", new[0]["note"])
        self.assertNotIn("bot", new[0]["note"])
        st = {i["number"]: i for i in self.read("issues.json")}
        self.assertEqual(st[2]["state"], "closed")
        self.assertIn("abc123def456", st[2]["comment"])
        self.assertIn("the bug is gone", st[2]["comment"])
        self.assertEqual(st[3]["state"], "open")   # done, but its check failed
        self.assertEqual(st[4]["state"], "open")   # still working
        self.sync()                                # idempotent: #1 is linked now
        self.assertEqual(len([t for t in self.read("tasks.json") if t["title"] == "New bug"]), 1)


if __name__ == "__main__":
    unittest.main()
