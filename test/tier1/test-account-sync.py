#!/usr/bin/env python3
"""lib/apps/powos-account-sync: an app's account-scoped tables on two devices through the account store.

Two simulated devices (each its own SpacetimeDB tables, enrollment and agent state) and a stand-in for the realm's
/v1/account API (PowStation enroll/powos-enroll.py, whose own test covers the server: LWW, secrets, revocation).
Pinned: a row made on one device reaches the other and back (both ways); last writer wins per row, a concurrent edit
resolves the same way on both; a delete travels as a tombstone; a new device takes the account's rows rather than
pushing its empty state over them; rows just pulled are not echoed back; a table with a column SQL can't write
(Timestamp) is reported, not synced; a revoked device stops syncing and says why; the installed-apps list says which
of the owner's apps a device lacks; Lights' manifest (home_bridge + pref) syncs with no app code.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
loader = importlib.machinery.SourceFileLoader("acctsync", os.path.join(REPO, "lib/apps/powos-account-sync"))
spec = importlib.util.spec_from_loader("acctsync", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

S, B, I32, U8, U64, F32 = {"String": []}, {"Bool": []}, {"I32": []}, {"U8": []}, {"U64": []}, {"F32": []}
TS = {"Product": {"elements": [{"name": {"some": "__timestamp_micros_since_unix_epoch__"}, "algebraic_type": {"I64": []}}]}}
fails = 0


def check(cond, what):
    global fails
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails += 1


# ── a device's SpacetimeDB, enough of its SQL for what the agent writes ─────────────────────────────────────────


def tokens(s):
    return re.findall(r"'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\"|-?\d+\.\d+(?:e-?\d+)?|-?\d+|[A-Za-z_]+|[(),=*]", s)


def val(t):
    if t.startswith("'"):
        return t[1:-1].replace("''", "'")
    if t in ("true", "false"):
        return t == "true"
    return float(t) if "." in t or "e" in t else int(t)


def name(t):
    return t[1:-1].replace('""', '"') if t.startswith('"') else t


class Stdb:
    def __init__(self, dbs):
        self.dbs = dbs  # db -> table -> {"cols": [(name, type)], "pk": [i], "rows": [dict]}
        self.writes = []

    def schema(self, db):
        if db not in self.dbs:
            return None
        return {t: {"cols": v["cols"], "pk": v["pk"]} for t, v in self.dbs[db].items()}

    def sql(self, db, q, token):
        if db not in self.dbs:
            raise RuntimeError(f"{db}: no such database")
        tk = tokens(q)
        if tk[0] == "SELECT":
            t = self.dbs[db][name(tk[3])]
            return [{"schema": {"elements": [{"name": {"some": n}} for n, _ in t["cols"]]},
                     "rows": [[r[n] for n, _ in t["cols"]] for r in t["rows"]]}]
        self.writes.append(q)
        if tk[0] == "INSERT":
            t = self.dbs[db][name(tk[2])]
            i = tk.index("VALUES")
            cols = [name(x) for x in tk[4:i - 1] if x != ","]
            vals = [val(x) for x in tk[i + 2:-1] if x != ","]
            pk = t["cols"][t["pk"][0]][0]
            row = dict(zip(cols, vals))
            assert not any(r[pk] == row[pk] for r in t["rows"]), "duplicate key"
            t["rows"].append(row)
        elif tk[0] == "UPDATE":
            t = self.dbs[db][name(tk[1])]
            w = tk.index("WHERE")
            sets = [x for x in tk[3:w] if x != ","]
            key = (name(tk[w + 1]), val(tk[w + 3]))
            for r in t["rows"]:
                if r[key[0]] == key[1]:
                    for j in range(0, len(sets), 3):
                        r[name(sets[j])] = val(sets[j + 2])
        elif tk[0] == "DELETE":
            t = self.dbs[db][name(tk[2])]
            k, v = name(tk[4]), val(tk[6])
            t["rows"] = [r for r in t["rows"] if r[k] != v]
        return []


def lights_db():
    return {"local-lights": {
        # The old per-device row (a Timestamp column): never synced; home_bridge is its account copy.
        "bridge": {"cols": [("id", U8), ("bridge_id", S), ("ip", S), ("name", S), ("paired_at", TS), ("module", S)],
                   "pk": [0], "rows": []},
        "home_bridge": {"cols": [("id", U8), ("bridge_id", S), ("ip", S), ("name", S), ("paired_ms", U64)],
                        "pk": [0], "rows": []},
        "pref": {"cols": [("rid", S), ("hidden", B), ("order", I32)], "pk": [0], "rows": []},
    }, "powos-keyboard-ai": {
        "app_pref": {"cols": [("app", S), ("learn", B), ("at", U64), ("origin", S)], "pk": [0], "rows": []},
        "day_stat": {"cols": [("id", S), ("day", U64), ("app", S), ("sessions", I32), ("picks", I32),
                              ("edit_sum", F32), ("edit_n", I32)], "pk": [0], "rows": []},
    }}


# ── the realm's /v1/account (LWW per row by (hlc, origin), seq cursor, 401 for a revoked token) ────────────────


class Realm:
    def __init__(self):
        self.rows, self.seq, self.devices = {}, 0, {}

    def http(self, url, body=None, token=None, method=None, raw=None, timeout=15):
        dev = next((d for d, t in self.devices.items() if t == token), None)
        if dev is None:
            return 401, b'{"error":"invalid_token"}'
        path = url.split("realm.test", 1)[1]
        if path.startswith("/v1/account/rows?"):
            q = dict(p.split("=") for p in path.split("?", 1)[1].split("&"))
            since, limit = int(q["since"]), int(q["limit"])
            got = sorted((r for r in self.rows.values() if r["seq"] > since), key=lambda r: r["seq"])
            more = len(got) > limit
            got = got[:limit]
            return 200, json.dumps({"rows": got, "seq": got[-1]["seq"] if got else since, "more": more}).encode()
        if path == "/v1/account/rows":
            applied = 0
            for r in body["rows"]:
                k = (r["app"], r["table"], r["pk"])
                old = self.rows.get(k)
                if old and (old["hlc"], old["origin"]) >= (r["hlc"], dev):
                    continue
                self.seq += 1
                self.rows[k] = {"app": r["app"], "table": r["table"], "pk": r["pk"], "hlc": r["hlc"], "origin": dev,
                                "deleted": bool(r.get("deleted")), "data": None if r.get("deleted") else r["data"],
                                "seq": self.seq}
                applied += 1
            return 200, json.dumps({"applied": applied}).encode()
        return 404, b"{}"


MANIFESTS = [
    json.load(open(os.path.join(REPO, "apps/keyboard-ai/powos-app.json"))),
    # Lights' manifest as its repo now declares it (~/Projects/lights/powos-app.json "sync").
    {"id": "local.lights", "module": {"database": "local-lights"}, "sync": {"tables": ["home_bridge", "pref"], "peers": "realm"}},
]


class Device:
    def __init__(self, ident, realm, work, apps=MANIFESTS):
        self.id, self.realm, self.db = ident, realm, Stdb(lights_db())
        self.dir = os.path.join(work, ident)
        man = os.path.join(self.dir, "manifests")
        os.makedirs(man)
        for a in apps:
            json.dump(a, open(os.path.join(man, a["id"] + ".json"), "w"))
        os.makedirs(os.path.join(self.dir, "deviced"))
        self.token = f"tok-{ident}"
        realm.devices[ident] = self.token
        json.dump({"realm": "http://realm.test", "device": {"id": ident}, "device_token": self.token},
                  open(os.path.join(self.dir, "deviced", "enrollment.json"), "w"))

    def round(self):
        m.DEVICED, m.STATE_DIR, m.APPS = os.path.join(self.dir, "deviced"), os.path.join(self.dir, "state"), "/nonexistent"
        m.sql, m.schema, m.http = self.db.sql, self.db.schema, self.realm.http
        return m.Agent([os.path.join(self.dir, "manifests")]).round()

    def t(self, db, table):
        return self.db.dbs[db][table]["rows"]


work = tempfile.mkdtemp()
realm = Realm()
a, b = Device("oneplus", realm, work), Device("s25", realm, work)

# The OnePlus paired the bridge long ago (its key is a secret of the PowOS app, not here) and arranged rooms.
a.t("local-lights", "home_bridge").append({"id": 0, "bridge_id": "ecb5fa", "ip": "192.168.50.20", "name": "Hue", "paired_ms": 1})
a.t("local-lights", "pref").extend([{"rid": "kitchen", "hidden": False, "order": 1}, {"rid": "hall", "hidden": True, "order": 2}])
a.t("local-lights", "bridge").append({"id": 0, "bridge_id": "x", "ip": "y", "name": "z", "paired_at": [1], "module": "m"})
r = a.round()
check(r["ok"] and r["pushed"] >= 3, f"device A's first round pushes its rows ({r['pushed']})")
check(r["tables"].get("local.lights|pref") == "ok" and r["tables"].get("local.lights|home_bridge") == "ok",
      "Lights' synced tables are ok")
check(not any(k[1] == "bridge" for k in realm.rows), "the per-device bridge table (not listed in sync) stays local")

# Device B: empty tables, takes the account's rows (no pairing, no arranging).
b.t("local-lights", "pref").append({"rid": "kitchen", "hidden": True, "order": 7})  # a stale local default
r = b.round()
check(r["ok"] and r["pulled"] >= 3, f"device B pulls them ({r['pulled']})")
check(b.t("local-lights", "home_bridge") == a.t("local-lights", "home_bridge"), "B has A's bridge row")
check(sorted(map(json.dumps, b.t("local-lights", "pref"))) == sorted(map(json.dumps, a.t("local-lights", "pref"))),
      "B has A's room prefs - the account's rows won over B's never-synced default")
check(r["pushed"] == 2, f"B pushes nothing it just pulled (only its 2 installed-apps records: {r['pushed']})")
r = b.round()
check(r["pushed"] == 0 and r["pulled"] == 0, "a quiet round moves nothing")

# B -> A: a change on B reaches A.
next(p for p in b.t("local-lights", "pref") if p["rid"] == "hall")["hidden"] = False
b.db.dbs["powos-keyboard-ai"]["app_pref"]["rows"].append({"app": "com.whatsapp", "learn": False, "at": 5, "origin": "s25"})
r = b.round()
check(r["pushed"] == 2, f"B pushes its two edits ({r['pushed']})")
r = a.round()
check(next(p for p in a.t("local-lights", "pref") if p["rid"] == "hall")["hidden"] is False, "A gets B's pref edit")
check(a.db.dbs["powos-keyboard-ai"]["app_pref"]["rows"] == [{"app": "com.whatsapp", "learn": False, "at": 5, "origin": "s25"}],
      "keyboard-ai syncs through its manifest alone")
check(any(w.startswith("UPDATE") for w in a.db.writes) and any(w.startswith("INSERT") for w in a.db.writes),
      "an existing row is UPDATEd, a new one INSERTed")

# Concurrent edits of one row: both devices end on the same value (the later stamp).
next(p for p in a.t("local-lights", "pref") if p["rid"] == "kitchen")["order"] = 10
a.round()
next(p for p in b.t("local-lights", "pref") if p["rid"] == "kitchen")["order"] = 20  # B's edit, stamped later
b.round()
a.round()
ka = next(p for p in a.t("local-lights", "pref") if p["rid"] == "kitchen")["order"]
kb = next(p for p in b.t("local-lights", "pref") if p["rid"] == "kitchen")["order"]
check(ka == kb == 20, f"LWW: the later write wins on both devices (A {ka}, B {kb})")

# An older write arriving late loses: B's state says it has a newer stamp than a replayed row.
old = dict(realm.rows[("local.lights", "pref", "kitchen")], hlc=1, origin="oneplus", data={"rid": "kitchen", "hidden": False, "order": 99})
realm.seq += 1
realm.rows[("local.lights", "pref", "kitchen")] = dict(old, seq=realm.seq)
b.round()
check(next(p for p in b.t("local-lights", "pref") if p["rid"] == "kitchen")["order"] == 20, "an older row never overwrites a newer one")

# A delete travels as a tombstone (A unpairs: home_bridge gone everywhere).
a.t("local-lights", "home_bridge").clear()
a.round()
b.round()
check(b.t("local-lights", "home_bridge") == [], "A's delete removes the row on B")

# A table SQL can't write is reported, not synced.
c = Device("desk", realm, work, apps=[{"id": "x.ts", "module": {"database": "local-lights"}, "sync": {"tables": ["bridge"]}}])
r = c.round()
check("paired_at" in r["tables"].get("x.ts|bridge", ""), f"a Timestamp column is refused with a reason: {r['tables']}")

# Same apps: the owner's apps this device lacks.
check("local.lights" in r["missing"] and "dev.powos.keyboard-ai" in r["missing"], f"desk lacks the phones' apps: {r['missing']}")

# Revoked: the next round stops and says so; nothing local is touched.
del realm.devices["s25"]
before = json.dumps(b.db.dbs)
r = b.round()
check(not r["ok"] and "isn't in the account" in r["why"], f"a revoked device stops syncing: {r.get('why')}")
check(json.dumps(b.db.dbs) == before, "and keeps its local data")

# Not enrolled: idle with a reason.
os.remove(os.path.join(a.dir, "deviced", "enrollment.json"))
r = a.round()
check(not r["ok"] and "not enrolled" in r["why"], "a device that hasn't joined doesn't sync")

# Literals: quotes in strings, no NaN.
check(m.lit("it's", "String") == "'it''s'" and m.lit(True, "Bool") == "true" and m.lit(3, "U64") == "3", "SQL literals")
try:
    m.lit(float("nan"), "F32")
    check(False, "NaN refused")
except ValueError:
    check(True, "NaN refused")

print(f"\n{'FAILED ' + str(fails) if fails else 'all ok'}")
sys.exit(1 if fails else 0)
