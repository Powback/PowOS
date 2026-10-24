#!/usr/bin/env python3
"""The work board's progress (`powos agents task ... --progress/--step/--plan/--commit/--image`), hermetic.

The real CLI (lib/ai/agents/powos-agents-cli) against a stand-in for the device's SpacetimeDB: an HTTP server that
answers `SELECT * FROM work` in the server's shape and applies work_set / work_track / work_drop the way the module
(apps/agents/module/src/lib.rs) does. Checks the columns the PowOS AI page reads: progress_done/progress_total, step,
steps (the history: done / current / next), commits (by --commit and by a commit mentioning the task id, from the
caller's git repo), images and activity.
"""

import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.normpath(os.path.join(HERE, "..", "..", "lib", "ai", "agents", "powos-agents-cli"))
COLS = ["id", "title", "owner", "status", "note", "created", "updated", "done", "project", "progress_done",
        "progress_total", "step", "steps", "commits", "images", "activity"]


class FakeStdb(http.server.BaseHTTPRequestHandler):
    work = {}
    clock = [1000]
    calls = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.endswith("/sql"):
            rows = [[w[c] for c in COLS] for w in self.work.values()]
            out = [{"schema": {"elements": [{"name": {"some": c}} for c in COLS]}, "rows": rows}]
            return self.reply(200, json.dumps(out))
        name = self.path.rsplit("/", 1)[-1]
        args = json.loads(body)
        self.calls.append((name, args))
        self.clock[0] += 1000
        now = self.clock[0]
        if name == "work_set":
            wid, title, owner, status, note, project = args
            o = self.work.get(wid)
            if o is None:
                if not title:
                    return self.reply(400, "no title")
                o = {c: "" for c in COLS} | {"id": wid, "created": now, "done": 0, "progress_done": 0,
                                               "progress_total": 0, "status": "working"}
            for k, v in (("title", title), ("owner", owner), ("status", status), ("note", note), ("project", project)):
                if v:
                    o[k] = v
            o["done"] = (o["done"] or now) if o["status"] == "done" else 0
            o["updated"] = o["activity"] = now
            self.work[wid] = o
        elif name == "work_track":
            wid, pd, pt, step, steps, commits, images = args
            if wid not in self.work or pd > pt:
                return self.reply(400, "work_track: bad")
            for s in (steps, commits, images):
                if s:
                    assert isinstance(json.loads(s), list)
            self.work[wid].update(progress_done=pd, progress_total=pt, step=step, steps=steps, commits=commits,
                                  images=images, updated=now, activity=now)
        elif name == "work_drop":
            self.work.pop(args[0], None)
        return self.reply(200, "")

    def reply(self, code, text):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class BoardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeStdb)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        FakeStdb.work.clear()
        FakeStdb.calls.clear()
        FakeStdb.clock[0] = 1000  # class-level, mutated in place by do_POST - reset so tests don't see each other's time (f93)
        self.tmp = tempfile.mkdtemp(prefix="board-test-")
        os.makedirs(os.path.join(self.tmp, ".config", "spacetime"))
        with open(os.path.join(self.tmp, ".config", "spacetime", "cli.toml"), "w") as f:
            f.write('spacetimedb_token = "tok"\n')
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        self.env = dict(os.environ, HOME=self.tmp, POWOS_STDB=f"http://127.0.0.1:{self.srv.server_address[1]}",
                        POWOS_AGENTS_REMOTE="0", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_GLOBAL="/dev/null")
        self.git("init", "-q")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *a):
        return subprocess.run(["git", *a], cwd=self.repo, env=self.env, check=True, capture_output=True,
                              text=True).stdout.strip()

    def commit(self, msg):
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def cli(self, *args, ok=True):
        p = subprocess.run([sys.executable, CLI, "task", *args], cwd=self.repo, env=self.env, capture_output=True,
                           text=True, timeout=30)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def row(self, wid="switcher"):
        return FakeStdb.work[wid]

    def steps(self, wid="switcher"):
        return [(s["text"], s["state"]) for s in json.loads(self.row(wid)["steps"] or "[]")]

    def test_plan_and_steps_history(self):
        self.cli("add", "Switcher follows finger", "--id", "switcher", "--plan", "follow the finger; settle; test on device")
        self.assertEqual(self.steps(), [("follow the finger", "next"), ("settle", "next"), ("test on device", "next")])
        self.assertEqual((self.row()["progress_done"], self.row()["progress_total"]), (0, 3))
        self.cli("set", "switcher", "--step", "follow the finger")
        self.assertEqual(self.row()["step"], "follow the finger")
        self.cli("set", "switcher", "--step", "settle")
        self.assertEqual(self.steps(), [("follow the finger", "done"), ("settle", "current"), ("test on device", "next")])
        self.assertEqual((self.row()["progress_done"], self.row()["progress_total"]), (1, 3))
        # An unplanned step goes in as current, before what's still to come.
        self.cli("set", "switcher", "--step", "fix the snap")
        self.assertEqual(self.steps(), [("follow the finger", "done"), ("settle", "done"), ("fix the snap", "current"),
                                        ("test on device", "next")])
        self.assertEqual((self.row()["progress_done"], self.row()["progress_total"]), (2, 4))
        self.cli("done", "switcher")
        self.assertEqual(self.row()["status"], "done")
        self.assertEqual(self.steps()[2], ("fix the snap", "done"))
        self.assertEqual(self.row()["step"], "")
        self.assertEqual((self.row()["progress_done"], self.row()["progress_total"]), (4, 4))

    def test_explicit_progress_wins(self):
        self.cli("add", "Kernel netfilter", "--id", "netfilter")
        self.cli("set", "netfilter", "--progress", "3/10", "--step", "checking on device")
        r = self.row("netfilter")
        self.assertEqual((r["progress_done"], r["progress_total"], r["step"]), (3, 10, "checking on device"))
        self.cli("set", "netfilter", "--step", "flashing")   # a step doesn't override an explicit count
        self.assertEqual((self.row("netfilter")["progress_done"], self.row("netfilter")["progress_total"]), (3, 10))
        self.assertEqual(self.steps("netfilter"), [("checking on device", "done"), ("flashing", "current")])
        self.assertNotEqual(self.cli("set", "netfilter", "--progress", "11/10", ok=False).returncode, 0)
        self.assertNotEqual(self.cli("set", "netfilter", "--progress", "three", ok=False).returncode, 0)

    def test_commits_linked_and_mentioned(self):
        a = self.commit("Switcher: follow the finger (task switcher)")
        self.commit("unrelated work")
        b = self.commit("Snap at the edges")
        self.cli("add", "Switcher follows finger", "--id", "switcher")
        self.cli("set", "switcher", "--commit", b[:7])
        commits = json.loads(self.row()["commits"])
        self.assertEqual([c["sha"] for c in commits], [a[:12], b[:12]])
        self.assertEqual(commits[1]["subject"], "Snap at the edges")
        self.cli("set", "switcher", "--commit", b)    # again: not twice
        self.assertEqual(len(json.loads(self.row()["commits"])), 2)
        self.assertNotEqual(self.cli("set", "switcher", "--commit", "not-a-sha", ok=False).returncode, 0)

    def test_images_activity_and_list(self):
        self.cli("add", "Glass on home", "--id", "glass", "--image", "/home/powos/design-qa/a.png")
        self.cli("set", "glass", "--image", "/home/powos/design-qa/b.png", "--image", "/home/powos/design-qa/a.png",
                 "--progress", "1/2", "--step", "review")
        r = self.row("glass")
        self.assertEqual(json.loads(r["images"]), ["/home/powos/design-qa/a.png", "/home/powos/design-qa/b.png"])
        self.assertGreater(r["activity"], r["created"])
        out = self.cli("list").stdout
        self.assertIn("Glass on home 1/2 · review", out)

    def test_owner_unowned_and_new(self):
        self.cli("new", "Drawer snaps", "--id", "drawer")
        self.cli("add", "Widget sizes", "--id", "widgets", "--owner", "coder")
        self.cli("add", "Lights app", "--id", "lights", "--owner", "powos-widgets")
        free = self.cli("list", "--unowned").stdout
        self.assertIn("[drawer]", free)
        self.assertIn("[widgets]", free)
        self.assertNotIn("[lights]", free)
        self.cli("set", "drawer", "--owner", "powos-drawer")
        self.assertEqual(self.row("drawer")["owner"], "powos-drawer")
        self.assertNotIn("[drawer]", self.cli("list", "--unowned").stdout)
        mine = self.cli("list", "--owner", "powos-drawer").stdout
        self.assertIn("Drawer snaps", mine)
        self.assertIn("powos-drawer", mine)
        self.assertNotIn("[lights]", mine)

    def test_image_rm(self):
        self.cli("add", "Recents", "--id", "recents", "--image", "/Users/mac/dead.png", "--image", "/home/powos/design-qa/ok.png")
        self.cli("set", "recents", "--image-rm", "/Users/mac/dead.png")
        self.assertEqual(json.loads(self.row("recents")["images"]), ["/home/powos/design-qa/ok.png"])
        self.cli("set", "recents", "--image-rm", "/home/powos/design-qa/ok.png")
        self.assertEqual(self.row("recents")["images"], "")

    def test_nothing_changed_no_track_call(self):
        self.cli("add", "Plain task", "--id", "plain")
        self.cli("set", "plain", "--note", "just a note")
        self.assertEqual([n for n, _ in FakeStdb.calls], ["work_set", "work_set"])

    def test_task_key_refused_unless_one_task(self):
        """`task set working --step ..` (a scraped status column) must not land on a task with 'working' in it."""
        self.cli("add", "Board shows real agent state (working only if an agent is live)", "--id", "board-live")
        self.cli("add", "Games launch instantly", "--id", "games-launch-instantly")
        self.cli("add", "Games freeze on resume", "--id", "games-freeze")
        before = dict(self.row("board-live"))
        for key in ("working", "Working", "games-launch-instantly-x", "Games", "stat", "nope"):
            p = self.cli("set", key, "--step", "measuring Broforce", ok=False)
            self.assertNotEqual(p.returncode, 0, key)
        self.assertEqual(self.row("board-live"), before)
        self.assertEqual(self.cli("set", "agent state", "--step", "y").stdout.strip(), "board-live")
        self.assertEqual(self.cli("done", "freeze resume").stdout.strip(), "games-freeze")

    def test_id_prefix_resolves_uniquely_else_lists_candidates(self):
        """A unique id prefix ('broforce-black' -> 'broforce-black-checkerboard-on-loading-menu') resolves; a
        prefix shared by several ids is refused and LISTS them, never guesses one (the friction this replaces:
        'no task has the id broforce-bla' with no way to act on the 'did you mean' short of retyping it exactly)."""
        self.cli("add", "Games launch instantly", "--id", "games-launch-instantly")
        self.cli("add", "Games freeze on resume", "--id", "games-freeze")
        # Unique prefix: resolves without needing the exact id.
        self.assertEqual(self.cli("set", "games-launch", "--step", "x").stdout.strip(), "games-launch-instantly")
        # A prefix several ids share: refused, candidates listed (not the first one picked).
        p = self.cli("set", "games-", "--step", "x", ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("games-launch-instantly", p.stderr)
        self.assertIn("games-freeze", p.stderr)
        # A longer, misspelled id still gets a "did you mean" rather than a bare refusal.
        p = self.cli("set", "games-launch-instantly-x", "--step", "x", ok=False)
        self.assertIn("games-launch-instantly", p.stderr)

    def test_merge_folds_dup_into_target(self):
        """`task merge <dup> --into <target>`: the dup's title/note and open steps/commits/images land on the
        target, then the dup is marked done ("merged into <target>") with no device check needed."""
        a = self.commit("fix the checkerboard flash")
        self.cli("add", "Broforce checkerboard on loading menu", "--id", "broforce-a", "--owner", "powos-games",
                 "--plan", "repro on device; patch the shader")
        self.cli("add", "Broforce shows a checkerboard while loading", "--id", "broforce-b", "--note", "seen on gpu-195",
                 "--image", "/home/powos/design-qa/checker.png")
        self.cli("set", "broforce-b", "--commit", a[:7])
        out = self.cli("merge", "broforce-b", "--into", "broforce-a", "--note", "same bug")
        self.assertEqual(out.stdout.strip(), "broforce-a")
        dup = self.row("broforce-b")
        self.assertEqual(dup["status"], "done")
        self.assertIn("merged into broforce-a", dup["note"])
        checks = [json.loads(c[1][0]) for c in FakeStdb.calls if c[0] == "check_set"]
        mine = [c for c in checks if c["task"] == "broforce-b"]
        self.assertEqual(len(mine), 1)
        self.assertEqual(mine[0]["state"], "none")
        self.assertIn("merged into broforce-a", mine[0]["line"])
        target = self.row("broforce-a")
        self.assertIn("same bug", target["note"])
        self.assertIn("Broforce shows a checkerboard while loading", target["note"])
        self.assertIn("seen on gpu-195", target["note"])
        steps = [s[0] for s in self.steps("broforce-a")]
        self.assertIn("repro on device", steps)
        self.assertIn("patch the shader", steps, "the target's own plan is kept, not wiped by the merge")
        self.assertEqual(json.loads(target["images"]), ["/home/powos/design-qa/checker.png"])
        self.assertEqual([c["sha"] for c in json.loads(target["commits"])], [a[:12]])
        # Refused: a dup can't be merged into itself, and a done target refuses further merges.
        self.cli("add", "Another dup", "--id", "broforce-c")
        self.assertNotEqual(self.cli("merge", "broforce-a", "--into", "broforce-a", ok=False).returncode, 0)
        self.cli("done", "broforce-c", "--no-check", "docs only")
        self.assertNotEqual(self.cli("merge", "broforce-a", "--into", "broforce-c", ok=False).returncode, 0)

    def test_dupes_lists_similar_open_tasks_only(self):
        self.cli("add", "Broforce checkerboard on loading menu", "--id", "broforce-a")
        self.cli("add", "Totally unrelated task", "--id", "unrelated")
        base = int(self.row("broforce-a")["created"])
        # Near-duplicates (inserted directly: `task add` itself refuses to create a second open duplicate, so
        # this is how two end up on the board for real - two agents racing past that check, or an old task
        # predating it) - one open (a merge candidate), one already done (must NOT be suggested).
        FakeStdb.work["broforce-b"] = {c: "" for c in COLS} | {
            "id": "broforce-b", "title": "Broforce checkerboard on the loading menu", "status": "working",
            "created": base + 100, "updated": base + 100, "done": 0, "progress_done": 0, "progress_total": 0}
        FakeStdb.work["broforce-c"] = {c: "" for c in COLS} | {
            "id": "broforce-c", "title": "Broforce checkerboard on the loading menus", "status": "done",
            "created": base - 100, "updated": base - 100, "done": base - 100, "progress_done": 0, "progress_total": 0}
        out = self.cli("dupes").stdout
        self.assertIn("broforce-a", out)
        self.assertIn("broforce-b", out)
        self.assertNotIn("unrelated", out)
        self.assertNotIn("broforce-c", out, "a done task is not a merge suggestion")
        pairs = json.loads(self.cli("dupes", "--json").stdout)
        self.assertEqual([(p["a"], p["b"]) for p in pairs], [("broforce-a", "broforce-b")])

    def test_help_documents_it(self):
        out = subprocess.run([sys.executable, CLI, "help"], capture_output=True, text=True).stdout
        for flag in ("--progress N/M", "--step TEXT", "--plan", "--commit SHA", "--image PATH", "--image-rm PATH",
                     "--unowned", "add|new", "task merge", "--into", "task dupes"):
            self.assertIn(flag, out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
