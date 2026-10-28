#!/usr/bin/env python3
"""The work board's truth, its done rule, the orphan sweeper, the user's asks and friction - hermetic.

The user, 2026-10-23: 30 tasks said "working" while 4 agents ran, several had no phone check - "fix it all properly
permanently". What this holds (lib/ai/agents/powos-agents-cli, apps/agents' work_check / user_ask / friction tables):
  - truth(): "working" only while a live agent holds the task; otherwise awaiting-check / no-check / stalled /
    blocked / done, from facts (agents' spool rows, the verify queue's checks, commits, the status for blocked/done);
  - the done rule: a task closes only on a PASS of a shipped build, or --no-check with a reason;
  - check scan: the Mac's verify queue dir as check rows (queued, PASS, FAIL, INVALID, the job's commit shipped);
  - sweep: ONE digest of the orphans, asks with no task and new friction to the coordinator - and nothing again until
    something is new or changed;
  - friction: add dedupes (count up), --repro required, fix + a recurrence reopens;
  - powos-agentsd logs a permission refusal as friction; the manager records each user turn as an ask.
The CLI runs against a stand-in for the device's SpacetimeDB that models the module's reducers (as
test-agents-board.py does).
"""

import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
CLI = os.path.join(ROOT, "lib", "ai", "agents", "powos-agents-cli")
AGENTSD = os.path.join(ROOT, "lib", "ai", "agents", "powos-agentsd")
MANAGER = os.path.join(ROOT, "lib", "ai", "manager", "manager.py")


def load(name, path):
    loader = SourceFileLoader(name, path)
    m = module_from_spec(spec_from_loader(name, loader))
    loader.exec_module(m)
    return m


cli = load("powos_agents_cli", CLI)
WORK_COLS = ["id", "title", "owner", "status", "note", "created", "updated", "done", "project", "progress_done",
             "progress_total", "step", "steps", "commits", "images", "activity"]


def norm(s):
    words = []
    for w in "".join(c if c.isalnum() else " " for c in s.lower()).split():
        words.append("#" if any(c.isdigit() for c in w) else w)
    return " ".join(words)


class FakeStdb(http.server.BaseHTTPRequestHandler):
    """The powos-agents module's tables and the reducers this needs, as apps/agents/module/src/lib.rs has them."""
    db = {}

    @classmethod
    def reset(cls):
        cls.db = {"work": {}, "work_check": {}, "user_ask": {}, "friction": {}}
        cls.clock = [int(time.time() * 1000) - 5000]

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.endswith("/sql"):
            name = body.decode().split()[-1]
            rows = list(self.db[name].values())
            cols = WORK_COLS if name == "work" else (list(rows[0]) if rows else ["id"])
            out = [{"schema": {"elements": [{"name": {"some": c}} for c in cols]}, "rows": [[r[c] for c in cols] for r in rows]}]
            return self.reply(200, json.dumps(out))
        name = self.path.rsplit("/", 1)[-1]
        self.clock[0] += 1
        try:
            getattr(self, "r_" + name)(*json.loads(body))
        except ValueError as e:
            return self.reply(400, str(e))
        return self.reply(200, "")

    def reply(self, code, text):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def r_work_set(self, wid, title, owner, status, note, project):
        now = self.clock[0]
        o = self.db["work"].get(wid)
        if status == "done" and (o is None or o["status"] != "done"):
            self.may_close(wid)
        if o is None:
            if not title:
                raise ValueError("no title")
            o = {c: "" for c in WORK_COLS} | {"id": wid, "created": now, "done": 0, "progress_done": 0,
                                                "progress_total": 0, "status": "working"}
        for k, v in (("title", title), ("owner", owner), ("status", status), ("note", note), ("project", project)):
            if v:
                o[k] = v
        o["done"] = (o["done"] or now) if o["status"] == "done" else 0
        o["updated"] = o["activity"] = now
        self.db["work"][wid] = o

    def r_work_track(self, wid, pd, pt, step, steps, commits, images):
        self.db["work"][wid].update(progress_done=pd, progress_total=pt, step=step, steps=steps, commits=commits,
                                    images=images, updated=self.clock[0], activity=self.clock[0])

    def may_close(self, wid):
        res = [c for c in self.db["work_check"].values() if c["task"] == wid and c["state"] in ("PASS", "FAIL", "none")]
        last = max(res, key=lambda c: c["at"]) if res else None
        if last and (last["state"] == "none" or (last["state"] == "PASS" and last["shipped"])):
            return
        raise ValueError(f"'{wid}' can't be done: " + ("its last phone check FAILED" if last and last["state"] == "FAIL"
                                                         else "a build that wasn't on the phone" if last else
                                                         "no phone check passed for it"))

    def _check(self, c):
        return {"job": c["job"], "task": c["task"], "name": c.get("name", ""), "state": c["state"],
                "line": c.get("line", ""), "at": c.get("at") or self.clock[0], "need": c.get("need", ""),
                "shipped": c.get("shipped", True)}

    def r_check_set(self, check):
        c = self._check(json.loads(check))
        self.db["work_check"][c["job"]] = c

    def r_check_sync(self, checks):
        rows = [self._check(c) for c in json.loads(checks)]
        have = {r["job"] for r in rows}
        for j in [j for j, c in self.db["work_check"].items() if c["state"] in ("queued", "running") and j not in have]:
            del self.db["work_check"][j]
        for r in rows:
            self.db["work_check"][r["job"]] = r

    def r_user_ask_add(self, ask):
        a = json.loads(ask)
        self.db["user_ask"].setdefault(a["id"], {"id": a["id"], "at": a.get("at") or self.clock[0], "text": a["text"],
                                                 "by": a.get("by", ""), "task": "", "none": ""})

    def r_user_ask_link(self, aid, task, none):
        if aid not in self.db["user_ask"]:
            raise ValueError("no ask")
        a = self.db["user_ask"][aid]
        a["task"] = task or a["task"]
        a["none"] = none or a["none"]

    def r_friction_add(self, item):
        f = json.loads(item)
        key = f"{norm(f['area'])}|{f['kind']}|{norm(f['title'])}"
        now = self.clock[0]
        o = next((x for x in self.db["friction"].values() if x["key"] == key), None)
        if o:
            back = o["status"] == "fixed" and not f.get("fixed")
            o.update(count=o["count"] + 1, last=now, status="open" if back else o["status"],
                     reopened=o["reopened"] + int(back), details=f.get("details") or o["details"])
            return
        fid = f"f{len(self.db['friction']) + 1}"
        self.db["friction"][fid] = {
            "id": fid, "key": key, "area": f["area"].strip().lower(), "kind": f["kind"], "title": f["title"],
            "details": f.get("details", ""), "repro": f.get("repro", ""), "evidence": f.get("evidence", ""),
            "by": f.get("by", ""), "count": 1, "first": now, "last": now,
            "status": "fixed" if f.get("fixed") else "open", "fix_commit": f.get("fixed", ""), "fix_note": "",
            "fixed_at": now if f.get("fixed") else 0, "reopened": 0}

    def r_friction_fix(self, fid, commit, note):
        self.db["friction"][fid].update(status="fixed", fix_commit=commit, fix_note=note, fixed_at=self.clock[0])


NOW = 10_000_000_000


def row(wid, **kw):
    return {"id": wid, "title": wid.replace("-", " "), "owner": "", "status": "working", "note": "", "step": "",
            "commits": "", "activity": NOW - 3600_000, "updated": NOW - 3600_000} | kw


def agent(work="", role="general-purpose", state="working", age_ms=60_000, title="An agent"):
    return {"id": f"mac:s/{work or role}", "role": role, "state": state, "last": NOW - age_ms, "work": work, "title": title}


class TruthTest(unittest.TestCase):
    """truth(): one state per task, from facts."""

    def t(self, w, agents=(), checks=()):
        held, roles = cli.holders(list(agents))
        return cli.truth(w, held, roles, list(checks), NOW)

    def test_newer_pass_supersedes_older_fail_and_closes_a_landed_fix(self):
        fail = {"state": "FAIL", "at": NOW - 5000, "job": "j1", "line": "x"}
        ok = {"state": "PASS", "at": NOW - 1000, "job": "j2", "shipped": True}
        landed = row("a", commits='["abc1234"]')
        self.assertEqual(self.t(landed, checks=[ok, fail])[0], "done")   # order of the list does not matter, time does
        self.assertEqual(self.t(landed, checks=[dict(fail, at=NOW - 100), ok])[0], "no-check")   # newer FAIL wins
        self.assertEqual(self.t(row("a"), checks=[fail, ok])[0], "no-check")   # no landed fix recorded: not closed blindly
        self.assertEqual(self.t(landed, checks=[dict(ok, shipped=False)])[0], "no-check")
        # a queued re-check keeps it awaiting-check (no stalled clock while it waits on the queue/ship)
        self.assertEqual(self.t(landed, checks=[fail, {"state": "queued", "at": NOW, "job": "j3"}])[0], "awaiting-check")

    def test_working_only_while_a_live_agent_holds_it(self):
        self.assertEqual(self.t(row("a"), [agent("a")])[0], "working")
        # Its owner set, no agent at all: not working, even with status working.
        self.assertEqual(self.t(row("a", owner="powos-games"))[0], "stalled")
        self.assertIn("owner powos-games isn't running", self.t(row("a", owner="powos-games"))[1])
        # A live agent of the owner's role holding nothing else holds it; the generic "coder" never does.
        self.assertEqual(self.t(row("a", owner="powos-games"), [agent(role="powos-games")])[0], "working")
        self.assertEqual(self.t(row("a", owner="coder"), [agent(role="coder")])[0], "stalled")

    def test_live_agents_from_spool_files(self):
        d = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(d, "mirror"))
            json.dump({"agents": [agent("a"), agent("b", state="idle"), agent("c", age_ms=31 * 60_000)]},
                      open(os.path.join(d, "state.json"), "w"))
            json.dump({"agents": [agent("m")]}, open(os.path.join(d, "mirror", "mac.json"), "w"))
            os.environ["POWOS_AGENTS_DIR"] = d
            os.environ.pop("POWOS_AGENTS_SPOOLS", None)
            live = {a["work"] for a in cli.live_agents(NOW)}
            self.assertEqual(live, {"a", "m"}, "idle, stale (>30 min) agents hold nothing; the mirror's count")
        finally:
            os.environ.pop("POWOS_AGENTS_DIR", None)
            shutil.rmtree(d)

    def test_checks(self):
        q = {"job": "j1", "task": "a", "name": "board-state", "state": "queued", "at": NOW - 1000, "shipped": True}
        self.assertEqual(self.t(row("a"), checks=[q]), ("awaiting-check", "check board-state queued"))
        st, why = self.t(row("a"), checks=[q | {"shipped": False, "need": "abcdef1234567"}])
        self.assertEqual(st, "awaiting-check")
        self.assertIn("waits for its ship (abcdef123)", why)
        fail = {"job": "j0", "task": "a", "name": "board-state", "state": "FAIL", "line": "FAIL rows", "at": NOW - 5000}
        st, why = self.t(row("a"), checks=[fail])
        self.assertEqual(st, "no-check")
        self.assertIn("FAILED: FAIL rows - nobody on it", why)
        # A newer queued check after the FAIL: awaiting it.
        self.assertEqual(self.t(row("a"), checks=[fail, q])[0], "awaiting-check")
        st, why = self.t(row("a"), checks=[fail | {"state": "PASS", "at": NOW - 60_000}])
        self.assertEqual(st, "no-check")
        self.assertIn("close it", why)
        self.assertIn("INVALID", self.t(row("a"), checks=[fail | {"state": "INVALID"}])[1])
        # Held beats every check fact.
        self.assertEqual(self.t(row("a"), [agent("a")], [fail])[0], "working")

    def test_queue_marker_before_a_sync(self):
        self.assertEqual(self.t(row("a", step=cli.QUEUED_STEP))[0], "awaiting-check")

    def test_pushed_blocked_done(self):
        st, why = self.t(row("a", commits=json.dumps([{"sha": "abc", "subject": "x"}])))
        self.assertEqual((st, why), ("no-check", "fix pushed (1 commit), no phone check queued"))
        self.assertEqual(self.t(row("a", status="blocked", note="needs the kernel")), ("blocked", "needs the kernel"))
        self.assertEqual(self.t(row("a", status="blocked"))[1], "no reason given")
        self.assertEqual(self.t(row("a", status="waiting", note="fold it"))[1], "waiting on the user: fold it")
        self.assertEqual(self.t(row("a", status="done"), [agent("a")])[0], "done")
        self.assertEqual(self.t(row("a"))[0], "stalled")


class ScanTest(unittest.TestCase):
    """check scan: the Mac's verify queue dir as check rows."""

    def test_scan(self):
        q = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(q, "done"))
            qt = int(time.time())
            open(os.path.join(q, "20261023-010000-1-a.job"), "w").write(
                f"task=a\nclose=1\ntries=0\ncwd=.\nrel=1\nfrom=''\nname=board-state\nscreen=''\nbudget=300\nneed=\nqt={qt}\ncmd=(x )\n")
            for n, task, log in (("20261023-000001-2-b", "b", "ok\nPASS: all good\n"),
                                 ("20261023-000002-3-c", "c", "FAIL: rows missing\nmore\nFAIL rc=1: more\n"),
                                 ("20261023-000003-4-d", "d", "INVALID x: no window\nINVALID rc=1: no window\n")):
                open(os.path.join(q, "done", n + ".job"), "w").write(
                    f"task={task}\n" + (f"name=chk-{task}\n" if task != "d" else "") + f"need=\nqt={qt}\n"
                    "cmd=(env PROFILE=1 bash -x /x/tools/phone/verify/bf-coldstart.sh 12 )\n")
                open(os.path.join(q, "done", n + ".log"), "w").write(log)
            got = {c["task"]: c for c in cli.scan_queue(q, repo=q)}
            self.assertEqual(got["a"]["state"], "queued")
            self.assertEqual(got["a"]["name"], "board-state")
            self.assertEqual(got["a"]["at"], qt * 1000)
            self.assertEqual((got["b"]["state"], got["b"]["line"]), ("PASS", "PASS: all good"))
            self.assertEqual((got["c"]["state"], got["c"]["line"]), ("FAIL", "FAIL: rows missing"))
            self.assertEqual(got["d"]["state"], "INVALID")
            self.assertEqual(got["d"]["name"], "bf-coldstart", "no name= (an older job): its script's")
            self.assertTrue(all(c["shipped"] for c in got.values()), "no commit known: it runs anyway (shipped)")
        finally:
            shutil.rmtree(q)


class BoardTest(unittest.TestCase):
    """The CLI end to end against the stand-in module: list, the done rule, asks, friction, the sweep."""

    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeStdb)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        FakeStdb.reset()
        self.tmp = tempfile.mkdtemp(prefix="board-truth-")
        os.makedirs(os.path.join(self.tmp, ".config", "spacetime"))
        open(os.path.join(self.tmp, ".config", "spacetime", "cli.toml"), "w").write('spacetimedb_token = "tok"\n')
        self.spool = os.path.join(self.tmp, "state.json")
        json.dump({"agents": []}, open(self.spool, "w"))
        self.mails = os.path.join(self.tmp, "mails")
        comms = os.path.join(self.tmp, "comms")
        open(comms, "w").write(f'#!/bin/sh\n{{ echo "TO $2"; cat; echo "--END--"; }} >> {self.mails}\n')
        os.chmod(comms, 0o755)
        self.env = dict(os.environ, HOME=self.tmp, POWOS_STDB=f"http://127.0.0.1:{self.srv.server_address[1]}",
                        POWOS_AGENTS_REMOTE="0", POWOS_AGENTS_SPOOLS=self.spool, POWOS_COMMS_CMD=comms,
                        POWOS_SWEEP_STATE=os.path.join(self.tmp, "sweep.json"),
                        POWOS_ASKS_FILE=os.path.join(self.tmp, "asks.jsonl"), GIT_CONFIG_GLOBAL="/dev/null")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, *args, ok=True, stdin=None):
        p = subprocess.run([sys.executable, CLI, *args], cwd=self.tmp, env=self.env, capture_output=True, text=True,
                           timeout=30, input=stdin)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def old(self, wid, minutes=60):
        """Make the row last move [minutes] ago (past the sweeper's grace)."""
        w = FakeStdb.db["work"][wid]
        w["activity"] = w["updated"] = int(time.time() * 1000) - minutes * 60_000

    def mails_sent(self):
        try:
            return open(self.mails).read().split("--END--\n")[:-1]
        except OSError:
            return []

    def test_list_shows_truth(self):
        self.run_cli("task", "add", "Switcher follows finger", "--owner", "powos-switcher")
        self.run_cli("task", "add", "Lights popup rooms")
        json.dump({"agents": [agent("lights-popup-rooms") | {"last": int(time.time() * 1000)}]}, open(self.spool, "w"))
        out = self.run_cli("task", "list").stdout
        self.assertIn("board: 1 working, 1 stalled", out)
        self.assertIn("why: nobody on it and no check; owner powos-switcher isn't running", out)
        js = {w["id"]: w for w in json.loads(self.run_cli("task", "list", "--json").stdout)}
        self.assertEqual(js["lights-popup-rooms"]["truth"], "working")
        self.assertEqual(js["switcher-follows-finger"]["status"], "working", "the status column itself is untouched")
        self.assertIn("switcher-follows-finger", self.run_cli("task", "list", "--state", "stalled").stdout)
        self.assertNotIn("lights-popup-rooms", self.run_cli("task", "list", "--state", "stalled").stdout)

    def test_done_needs_a_passed_check(self):
        self.run_cli("task", "add", "Prompt glyph")
        p = self.run_cli("task", "done", "prompt-glyph", ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("no phone check passed", p.stderr)
        self.run_cli("check", "set", "prompt-glyph", "j1", "FAIL", "--line", "FAIL glyph clipped")
        self.assertIn("FAILED", self.run_cli("task", "set", "prompt-glyph", "--status", "done", ok=False).stderr)
        self.run_cli("check", "set", "prompt-glyph", "j2", "PASS", "--shipped", "0")
        self.assertIn("wasn't on the phone", self.run_cli("task", "done", "prompt-glyph", ok=False).stderr)
        self.run_cli("check", "set", "prompt-glyph", "j3", "PASS")
        self.run_cli("task", "done", "prompt-glyph")
        self.assertEqual(FakeStdb.db["work"]["prompt-glyph"]["status"], "done")

    def test_sync_closes_a_passed_close_check(self):
        self.run_cli("task", "add", "Running dot")
        self.run_cli("task", "add", "Edit mode add")
        self.run_cli("task", "add", "Reopened one")
        at = FakeStdb.clock[0]
        FakeStdb.db["work"]["reopened-one"]["updated"] = at + 3600_000   # its owner moved it after the pass
        cs = [{"job": "j1", "task": "running-dot", "state": "PASS", "close": True, "shipped": True, "at": at},
              {"job": "j2", "task": "edit-mode-add", "state": "PASS", "close": False, "shipped": True, "at": at},
              {"job": "j3", "task": "reopened-one", "state": "PASS", "close": True, "shipped": True, "at": at}]
        f = os.path.join(self.tmp, "c.json")
        json.dump(cs, open(f, "w"))
        self.assertIn("1 task(s) closed", self.run_cli("check", "sync", f).stdout)
        self.assertEqual(FakeStdb.db["work"]["running-dot"]["status"], "done")
        self.assertEqual(FakeStdb.db["work"]["edit-mode-add"]["status"], "working", "no --close: the owner closes it")
        self.assertEqual(FakeStdb.db["work"]["reopened-one"]["status"], "working", "moved since the pass: its owner's")

    def test_done_with_no_check_reason(self):
        self.run_cli("task", "add", "Handbook board section")
        self.assertIn("needs the reason", self.run_cli("task", "done", "handbook-board-section", "--no-check", " ", ok=False).stderr)
        self.run_cli("task", "done", "handbook-board-section", "--no-check", "docs only")
        self.assertEqual(FakeStdb.db["work"]["handbook-board-section"]["status"], "done")
        self.assertEqual(FakeStdb.db["work_check"]["nocheck:handbook-board-section"]["line"], "docs only")

    def test_asks(self):
        self.run_cli("ask", "add", "--id", "ask-1", "-", stdin="make the search bar\nwork  in the drawer")
        self.run_cli("ask", "add", "--id", "ask-2", "thanks!")
        self.assertEqual(FakeStdb.db["user_ask"]["ask-1"]["text"], "make the search bar\nwork  in the drawer")
        out = self.run_cli("ask", "list", "--untracked").stdout
        self.assertIn("ask-1", out)
        self.assertIn("ask-2", out)
        self.run_cli("task", "add", "Search bar in the drawer", "--ask", "ask-1")
        self.run_cli("ask", "none", "ask-2", "--reason", "thanks, nothing to do")
        self.assertEqual(self.run_cli("ask", "list", "--untracked").stdout.strip(), "no asks without a task")
        # The manager's own log: an ask the module never got (it was down) is added by `ask sync`.
        open(self.env["POWOS_ASKS_FILE"], "w").write(json.dumps({"id": "ask-3", "text": "full chat", "at": 5}) + "\n")
        self.run_cli("ask", "sync")
        self.assertIn("ask-3", FakeStdb.db["user_ask"])

    def test_friction(self):
        add = ["friction", "add", "--area", "ship", "--kind", "refused"]
        self.assertIn("--repro is required", self.run_cli(*add, "ship refused at load 17", ok=False).stderr)
        self.assertIn("--kind is one of", self.run_cli("friction", "add", "--area", "x", "--kind", "meh", "t", "--repro", "r", ok=False).stderr)
        self.run_cli(*add, "ship refused at load 17", "--repro", "ship.sh request", "--details", "-", stdin="the whole\nstory")
        self.run_cli(*add, "Ship refused at load 25!", "--repro", "ship.sh request")
        fs = list(FakeStdb.db["friction"].values())
        self.assertEqual(len(fs), 1, "the same area, kind and normalized title count up")
        self.assertEqual(fs[0]["count"], 2)
        self.run_cli("friction", "fix", "f1", "--commit", "abc1234")
        self.assertEqual(FakeStdb.db["friction"]["f1"]["status"], "fixed")
        self.run_cli(*add, "ship refused at load 30", "--repro", "ship.sh request")
        self.assertEqual((FakeStdb.db["friction"]["f1"]["status"], FakeStdb.db["friction"]["f1"]["reopened"]), ("open", 1))
        out = self.run_cli("friction", "list").stdout
        self.assertIn("f1    x3   [ship/refused] ship refused at load 17", out)
        self.assertIn("reopened x1", out)
        self.assertIn("details: the whole\nstory", self.run_cli("friction", "show", "f1").stdout)

    def test_sweep_mails_one_digest_then_only_changes(self):
        for t in ("Teardown starts", "Broforce folds", "Lights rooms", "Chat frost"):
            self.run_cli("task", "add", t)
        self.run_cli("task", "set", "chat-frost", "--status", "blocked")
        self.run_cli("check", "set", "broforce-folds", "j1", "FAIL", "--name", "bf-fold", "--line", "FAIL timeout")
        self.run_cli("check", "set", "lights-rooms", "j2", "queued", "--name", "lights")
        for w in FakeStdb.db["work"]:
            self.old(w)
        self.run_cli("task", "add", "Fresh one")   # inside the grace: not an orphan yet
        self.run_cli("ask", "add", "--id", "ask-9", "make it all work")
        FakeStdb.db["user_ask"]["ask-9"]["at"] -= 3600_000
        self.run_cli("friction", "add", "--area", "verify", "--kind", "flaky-check", "paused queue blocks checks", "--repro", "queue.sh pause")
        out = self.run_cli("sweep").stdout
        mails = self.mails_sent()
        self.assertEqual(len(mails), 1, out)
        m = mails[0]
        self.assertTrue(m.startswith("TO coder\nBoard sweep: 3 task(s), 1 ask(s), 1 friction"), m)
        self.assertIn("[stalled] Teardown starts (teardown-starts)", m)
        self.assertIn("[no-check] Broforce folds (broforce-folds) - last check bf-fold FAILED: FAIL timeout", m)
        self.assertIn("[blocked] Chat frost (chat-frost) - no reason given", m)
        self.assertNotIn("Lights rooms", m, "an awaiting-check task isn't an orphan")
        self.assertNotIn("Fresh one", m)
        self.assertIn("- ask-9", m)
        self.assertIn("f1 x1 [verify/flaky-check] paused queue blocks checks - repro: queue.sh pause", m)
        # Nothing changed: no mail at all.
        self.assertIn("nothing new", self.run_cli("sweep").stdout)
        self.assertEqual(len(self.mails_sent()), 1)
        # One thing changed (Teardown's check now FAILED; the friction recurred): only those.
        self.run_cli("check", "set", "teardown-starts", "j3", "FAIL", "--name", "td-launch", "--line", "FAIL no window")
        self.old("teardown-starts")
        self.run_cli("friction", "add", "--area", "verify", "--kind", "flaky-check", "paused queue blocks checks", "--repro", "x")
        self.run_cli("sweep")
        m = self.mails_sent()[1]
        self.assertIn("Board sweep: 1 task(s), 0 ask(s), 1 friction", m)
        self.assertIn("td-launch FAILED", m)
        self.assertNotIn("Broforce", m)
        self.assertIn("f1 x2", m)
        # A dry run prints the digest but mails nothing and remembers nothing: the next real pass still mails it.
        self.run_cli("task", "add", "Dry one")
        self.old("dry-one")
        self.assertIn("[stalled] Dry one", self.run_cli("sweep", "--dry-run").stdout)
        self.assertEqual(len(self.mails_sent()), 2)
        self.run_cli("sweep")
        self.assertIn("[stalled] Dry one", self.mails_sent()[2])


class RefusalTest(unittest.TestCase):
    """powos-agentsd: a tool call the permission system refused becomes friction (once an hour per role/tool/hint)."""

    def test_refusal_logged(self):
        agentsd = load("powos_agentsd", AGENTSD)
        tmp = tempfile.mkdtemp()
        try:
            log = os.path.join(tmp, "argv")
            fake = os.path.join(tmp, "fake-cli")
            open(fake, "w").write(f"import json, sys\nopen({log!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n")
            os.environ["POWOS_AGENTS_CLI"] = fake
            s = agentsd.Spool(tmp, "mac")
            me = {"role": "powos-games", "id": "mac:x"}
            rec = {"error": "Permission to use Bash with command adb shell was denied by the auto mode classifier",
                   "tool_input": {"command": "adb shell su -c reboot", "description": "Reboot the phone"}}
            s.refusal(me, "Bash", rec, 1_000_000)
            s.refusal(me, "Bash", rec, 1_000_000 + 60_000)            # within the hour: not again
            s.refusal(me, "Bash", {"error": "exit code 1"}, 2_000_000)  # a plain failure: not a refusal
            for _ in range(50):
                if os.path.exists(log):
                    break
                time.sleep(0.1)
            time.sleep(0.3)
            calls = [json.loads(x) for x in open(log)]
            self.assertEqual(len(calls), 1)
            a = calls[0]
            self.assertEqual(a[:6], ["friction", "add", "--area", "permissions", "--kind", "refused"])
            self.assertEqual(a[6], "Bash refused by the permission system: Reboot")
            self.assertIn("powos-games ran Bash: Reboot the phone", a)
        finally:
            os.environ.pop("POWOS_AGENTS_CLI", None)
            shutil.rmtree(tmp)


class AskTurnTest(unittest.TestCase):
    """manager.py: each user turn is recorded as an ask (asks.jsonl + `powos agents ask add`) and sent with its id."""

    def test_ask_turn(self):
        manager = load("powos_manager", MANAGER)
        tmp = tempfile.mkdtemp()
        try:
            log = os.path.join(tmp, "argv")
            fake = os.path.join(tmp, "agents")
            open(fake, "w").write(f"#!/bin/sh\n{{ echo \"$@\"; cat; }} > {log}\n")
            os.chmod(fake, 0o755)
            os.environ["POWOS_AGENTS_CMD"] = fake
            m = types.SimpleNamespace(args=types.SimpleNamespace(session_store=tmp), _agent_id="manager")
            sent = manager.Manager._ask_turn(m, "the search bar, again")
            rec = json.loads(open(os.path.join(tmp, "asks.jsonl")).read())
            self.assertEqual(rec["text"], "the search bar, again")
            self.assertTrue(sent.startswith("the search bar, again\n\n[user ask " + rec["id"]))
            self.assertIn(f"--ask {rec['id']}", sent)
            for _ in range(50):
                if os.path.exists(log) and "search bar" in open(log).read():
                    break
                time.sleep(0.1)
            self.assertEqual(open(log).read(), f"ask add --id {rec['id']} --by manager -\nthe search bar, again")
            os.environ["POWOS_MANAGER_ASKS"] = "0"
            self.assertEqual(manager.Manager._ask_turn(m, "x"), "x")
        finally:
            os.environ.pop("POWOS_AGENTS_CMD", None)
            os.environ.pop("POWOS_MANAGER_ASKS", None)
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main(verbosity=1)
