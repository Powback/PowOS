#!/usr/bin/env python3
"""The keyboard AI learning the user's reply style (lib/ai/manager/reply_learn.py + reply_drafts.py; the Keyboard AI
app's database apps/keyboard-ai), against a stand-in SpacetimeDB (FakeDb: the module's reducers in Python, its SQL
reads over HTTP) and a fake claude - no model, no phone.

Pinned: retrieval ranks same app + same contact + shared words first and never returns uncommitted rows; the
draft prompt carries the learned block (profiles + examples) and stays small; an answered request is stored as an
offer with the contact the model read and the press's session, and the answer carries its rid; an outcome records the
committed text and the edit distance from the picked draft; password / incognito fields and apps switched off record
nothing and get no learned context; the database down never fails a draft; profiles are regenerated first after
PROFILE_FIRST picks, then after every PROFILE_EVERY_* new ones, not on every pick.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MGR = os.path.join(REPO, "lib/ai/manager")
sys.path.insert(0, MGR)
import reply_learn as rl  # noqa: E402
import reply_drafts as rd  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + (f" - {detail}" if detail and not ok else ""))
    if not ok:
        fails += 1


class FakeDb:
    """apps/keyboard-ai/module/src/lib.rs's tables and reducers, the parts reply_learn uses."""
    COLS = {"reply": ["id", "session", "app", "contact", "hint", "drafts", "action", "picked", "final_text", "edit",
                      "sent", "at", "done_at", "origin"],
            "profile": ["id", "app", "contact", "text", "outcomes", "at", "origin"],
            "app_pref": ["app", "learn", "at", "origin"]}

    def __init__(self):
        self.t = {k: [] for k in self.COLS}
        self.clock = 1_000_000
        self.calls = []

    def now(self):
        self.clock += 1000
        return self.clock

    def sql(self, query):
        m = re.fullmatch(r"SELECT \* FROM (\w+)(?: WHERE (\w+) = '((?:[^']|'')*)')?", query.strip())
        assert m, query
        rows = self.t[m.group(1)]
        if m.group(2):
            v = m.group(3).replace("''", "'")
            rows = [r for r in rows if str(r[m.group(2)]) == v]
        return [dict(r) for r in rows]

    def learning(self, app):
        return not any(p["app"] == app and not p["learn"] for p in self.t["app_pref"])

    def call(self, reducer, *args):
        self.calls.append((reducer, args))
        getattr(self, "r_" + reducer)(*args)

    def r_offer(self, js):
        o = json.loads(js)
        if not self.learning(o["app"]):
            return
        self.t["reply"].append({"id": o["id"], "session": o["session"], "app": o["app"], "contact": o.get("contact", ""),
                                "hint": o.get("hint", ""), "drafts": json.dumps(o["drafts"]), "action": "offered",
                                "picked": -1, "final_text": "", "edit": -1.0, "sent": False, "at": self.now(),
                                "done_at": 0, "origin": o.get("origin", "")})

    def r_outcome(self, js):
        o = json.loads(js)
        for r in self.t["reply"]:
            if r["id"] == o["id"] and r["action"] == "offered":
                picked = o["action"] == "picked"
                r.update(action=o["action"], picked=o["picked"] if picked else -1,
                         final_text=o["final_text"] if picked else "", edit=o["edit"] if picked else -1.0,
                         sent=picked and o["sent"], done_at=self.now())

    def r_profile_set(self, js):
        p = json.loads(js)
        pid = f"contact|{p['app']}|{p['contact']}" if p["contact"] else f"app|{p['app']}"
        self.t["profile"] = [x for x in self.t["profile"] if x["id"] != pid]
        self.t["profile"].append({"id": pid, "app": p["app"], "contact": p["contact"], "text": p["text"],
                                  "outcomes": p["outcomes"], "at": self.now(), "origin": p.get("origin", "")})

    def r_set_learn(self, app, learn):
        self.t["app_pref"] = [p for p in self.t["app_pref"] if p["app"] != app]
        if not learn:
            self.t["reply"] = [r for r in self.t["reply"] if r["app"] != app]
            self.t["profile"] = [p for p in self.t["profile"] if p["app"] != app]
            self.t["app_pref"].append({"app": app, "learn": False, "at": self.now(), "origin": ""})


def committed_row(db, rid, app, contact, final, draft="draft", at=None):
    db.t["reply"].append({"id": rid, "session": rid, "app": app, "contact": contact, "hint": "Message",
                          "drafts": json.dumps([draft]), "action": "picked", "picked": 0, "final_text": final,
                          "edit": 0.1, "sent": True, "at": at if at is not None else db.now(), "done_at": db.now(),
                          "origin": "t"})


WA = "com.whatsapp"
REQ = {"app": WA, "hint": "Message", "inputType": 0x1 | 0x40, "imeOptions": 0, "transcript": "dinner tonight",
       "text": "", "session": "s1"}

# --- ranking ---
db = FakeDb()
committed_row(db, "a", "com.slack", "", "Dinner tonight works for me")          # other app, shared words
committed_row(db, "b", WA, "Anna", "haha yes!! see you at 8 🍝")                # same app + contact
committed_row(db, "c", WA, "Bob", "ok")                                         # same app
committed_row(db, "d", WA, "Anna", "dinner tonight? I'm in")                    # same app + contact + words
db.t["reply"].append(dict(db.t["reply"][1], id="e", action="more", final_text=""))     # not committed
db.t["reply"].append(dict(db.t["reply"][1], id="f", action="offered", final_text="x"))  # not committed
committed_row(db, "g", WA, "Anna", "dinner tonight? I'm in")                    # duplicate text
top = rl.rank(db.t["reply"], WA, "Anna", "dinner tonight", db.clock, k=5)
ids = [r["id"] for r in top]
check("rank: same app + contact + words first", ids[0] in ("d", "g"), ids)
check("rank: same contact beats same app only", ids.index("b") < ids.index("c"), ids)
check("rank: uncommitted rows never returned", not {"e", "f"} & set(ids), ids)
check("rank: identical texts once", len([i for i in ids if i in ("d", "g")]) == 1, ids)
check("rank: other app still eligible, below same app", ids[-1] == "a" or ids.index("a") > ids.index("b"), ids)
check("rank: k caps it", len(rl.rank(db.t["reply"], WA, "", "", db.clock, k=2)) == 2)
check("likely contact: newest in the app within the window",
      rl.likely_contact(db.t["reply"], WA, db.clock) == "Anna"
      and rl.likely_contact(db.t["reply"], WA, db.clock + rl.LIKELY_MS + 1) == "")

# --- context + prompt ---
db.r_profile_set(json.dumps({"app": WA, "contact": "", "text": "Short, lowercase, lots of emoji.", "outcomes": 4}))
db.r_profile_set(json.dumps({"app": WA, "contact": "Anna", "text": "Playful, Italian food jokes.", "outcomes": 3}))
ctx = rl.context(REQ, db, db.clock)
check("context: learn on with examples and profiles", ctx["learn"] and ctx["examples"] and len(ctx["profiles"]) == 2, ctx)
block = rl.prompt_block(ctx)
check("prompt: app profile, contact profile and examples", "in this app: Short" in block and "with Anna: Playful" in block
      and "dinner tonight? I'm in" in block, block)
check("prompt: small (k examples, capped lines)", len(block) < 2000 and block.count("\n- (") <= rl.K, len(block))
rq = dict(rd.parse_request(json.dumps(dict(REQ, v=1, image="aGk=", n=3))))
check("draft prompt starts with the learned block", rd.prompt_text(rq, block).startswith(block))
for name, req in (("password field", dict(REQ, inputType=0x1 | 0x80)), ("numeric PIN", dict(REQ, inputType=0x2 | 0x10)),
                  ("incognito field", dict(REQ, imeOptions=0x1000000))):
    c = rl.context(req, db, db.clock)
    check(f"privacy: {name} gets no learned context", c == {"learn": False, "examples": [], "profiles": [], "contact": ""}, c)


class Down:
    def sql(self, q):
        raise rl.Unavailable("connection refused")

    def call(self, *a):
        raise rl.Unavailable("connection refused")


check("database down: no learning, no error", rl.context(REQ, Down(), 0)["learn"] is False)
check("database down: offer not stored -> no rid", rl.record_offer(REQ, ["x"], "", Down()) is None)

# --- offer + outcome ---
db2 = FakeDb()
rid = rl.record_offer(REQ, ["See you at 8!", "Can't tonight, sorry"], "Anna", db2)
row = db2.t["reply"][0]
check("offer stored as text: app, contact, hint, drafts, session", row["id"] == rid and row["app"] == WA
      and row["contact"] == "Anna" and json.loads(row["drafts"]) == ["See you at 8!", "Can't tonight, sorry"]
      and row["session"] == "s1", row)
check("offer has no image field", "image" not in json.dumps(db2.calls))
o = rl.parse_outcome(json.dumps({"v": 1, "rid": rid, "action": "picked", "picked": 0, "final": "See you at 8 🙂",
                                 "sent": True, "inputType": 0x41}))
out = rl.handle_outcome(o, db2, regen=lambda s, a, c: [])
row = db2.t["reply"][0]
check("outcome: picked + committed text + sent", out["recorded"] and row["action"] == "picked" and row["picked"] == 0
      and row["final_text"] == "See you at 8 🙂" and row["sent"] is True, (out, row))
check("outcome: edit distance from the picked draft", 0 < row["edit"] < 0.3, row["edit"])
check("edit distance: 0 unchanged, 1 all new", rl.edit_distance("abc", "abc") == 0 and rl.edit_distance("abc", "xyz") == 1)
check("edit distance: kitten/sitting", abs(rl.edit_distance("kitten", "sitting") - 3 / 7) < 1e-3)
rid2 = rl.record_offer(dict(REQ, session="s2"), ["a", "b"], "", db2)
rl.handle_outcome(rl.parse_outcome(json.dumps({"rid": rid2, "action": "more"})), db2, regen=lambda *a: 1 / 0)
check("outcome: more recorded, no text, no profile run", db2.t["reply"][1]["action"] == "more"
      and db2.t["reply"][1]["final_text"] == "")
rid3 = rl.record_offer(dict(REQ, session="s3"), ["a"], "", db2)
r = rl.handle_outcome(rl.parse_outcome(json.dumps({"rid": rid3, "action": "picked", "picked": 0, "final": "secret",
                                                   "inputType": 0x81})), db2)
check("privacy: outcome from a password field records nothing", not r["recorded"]
      and db2.t["reply"][2]["action"] == "offered", r)
for bad in ({"rid": "", "action": "picked"}, {"rid": "x", "action": "deleted"}, {"v": 2, "rid": "x", "action": "more"}):
    try:
        rl.parse_outcome(json.dumps(bad))
        check(f"bad outcome refused {bad}", False)
    except ValueError:
        check(f"bad outcome refused {bad}", True)

# --- the off switch ---
db2.r_set_learn(WA, False)
check("off: what was learned in the app is gone", not [r for r in db2.t["reply"] if r["app"] == WA])
check("off: no learned context", rl.context(REQ, db2, db2.clock)["learn"] is False)
db2.r_offer(json.dumps({"id": "z", "session": "z", "app": WA, "drafts": ["x"]}))
check("off: the module stores no offer", not db2.t["reply"])
db2.r_set_learn(WA, True)
check("on again: learning resumes", rl.context(REQ, db2, db2.clock)["learn"] is True)

# --- profile regeneration trigger ---
check("profile_due: first after PROFILE_FIRST", not rl.profile_due(rl.PROFILE_FIRST - 1, 0, False, 8)
      and rl.profile_due(rl.PROFILE_FIRST, 0, False, 8))
check("profile_due: then every N new", not rl.profile_due(50, 7, True, 8) and rl.profile_due(50, 8, True, 8))
db3 = FakeDb()
ran = []


def fake_model(prompt):
    ran.append(prompt)
    return "Writes short and warm."


real_model, rl.run_profile_model = rl.run_profile_model, fake_model
os.environ["XDG_RUNTIME_DIR"] = tempfile.mkdtemp()
regens = []
for i in range(1, 2 + rl.PROFILE_FIRST + rl.PROFILE_EVERY_APP):
    rid = rl.record_offer(dict(REQ, session=f"p{i}"), [f"draft {i}"], "Anna", db3)
    res = rl.handle_outcome(rl.parse_outcome(json.dumps({"rid": rid, "action": "picked", "picked": 0,
                                                         "final": f"reply number {i}", "sent": True})), db3)
    regens.append(res["regenerated"])
first = next(i for i, r in enumerate(regens, 1) if r)
check("regen: first profiles after PROFILE_FIRST picks (app + contact)",
      first == rl.PROFILE_FIRST and sorted(regens[first - 1]) == ["(app)", "Anna"], regens)
check("regen: not on every pick", sum(1 for r in regens if r) < len(regens) // 2, regens)
check("regen: the contact's comes again after PROFILE_EVERY_CONTACT", "Anna" in regens[first - 1 + rl.PROFILE_EVERY_CONTACT],
      regens)
check("regen: the app's after PROFILE_EVERY_APP", "(app)" in regens[first - 1 + rl.PROFILE_EVERY_APP], regens)
check("regen: profile stored with its text", any(p["text"] == "Writes short and warm." for p in db3.t["profile"]))
check("regen: model input is committed text, never an image", ran and "reply number" in ran[0] and "image" not in ran[0])
rl.run_profile_model = real_model

# --- end to end: `reply_drafts.py` over HTTP with a stand-in SpacetimeDB ---
srv_db = FakeDb()
committed_row(srv_db, "old", WA, "Anna", "lol sure, 8 works 🍝")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        path = self.path.split("/")
        if path[-1] == "sql":
            rows = srv_db.sql(body)
            cols = FakeDb.COLS[re.search(r"FROM (\w+)", body).group(1)]
            out = [{"schema": {"elements": [{"name": {"some": c}} for c in cols]},
                    "rows": [[r[c] for c in cols] for r in rows]}]
        else:
            srv_db.call(path[-1], *json.loads(body))
            out = {}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
tmp = tempfile.mkdtemp()
seen = os.path.join(tmp, "seen.json")
claude = os.path.join(tmp, "claude")
with open(claude, "w") as f:
    f.write(f"""#!/usr/bin/env python3
import sys, json
json.dump(json.loads(sys.stdin.readline()), open({seen!r}, "w"))
print(json.dumps({{"type": "result", "is_error": False,
  "result": '{{"contact": "Anna", "variations": ["8 works 🍝", "can we do 9?"]}}'}}))
""")
os.chmod(claude, 0o755)
env = dict(os.environ, MANAGER_CLAUDE_CMD=claude, POWOS_STDB=f"http://127.0.0.1:{httpd.server_port}")
req = dict(REQ, v=1, image="aGk=", n=2, session="press-1")
code = ("import sys; sys.path.insert(0, %r); import reply_learn; reply_learn._token = lambda: 'tok'; "
        "import reply_drafts; sys.exit(reply_drafts.main())" % MGR)
p = subprocess.run([sys.executable, "-c", code], input=json.dumps(req), capture_output=True, text=True, env=env)
ans = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}
check("e2e: drafts answer carries learn + rid", ans.get("ok") and ans.get("learn") is True and ans.get("rid"), (ans, p.stderr))
check("e2e: contact not passed to the keyboard", "contact" not in ans, ans)
sent_text = json.load(open(seen))["message"]["content"][1]["text"] if os.path.exists(seen) else ""
check("e2e: the prompt carries the past committed reply", "lol sure, 8 works" in sent_text, sent_text[:300])
offer = [r for r in srv_db.t["reply"] if r["id"] == ans.get("rid")]
check("e2e: offer stored with the model's contact and the press", offer and offer[0]["contact"] == "Anna"
      and offer[0]["session"] == "press-1", offer)
srv_db.r_set_learn(WA, False)
p = subprocess.run([sys.executable, "-c", code], input=json.dumps(req), capture_output=True, text=True, env=env)
ans = json.loads(p.stdout.strip().splitlines()[-1])
check("e2e: app switched off -> drafts work, learn false, no rid", ans["ok"] and ans["learn"] is False and "rid" not in ans,
      ans)
httpd.shutdown()

print(f"{'FAIL' if fails else 'PASS'}: reply learning ({fails} failed)")
sys.exit(1 if fails else 0)
