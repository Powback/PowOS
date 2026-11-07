#!/usr/bin/env python3
"""Approving devices into the realm from an enrolled device (lib/devices/powos-deviced pending/approve/revoke and the
agent's /v1/enroll/* for this device's own Devices app), against a fake realm speaking PowStation powos-enroll's
approver API (GET /v1/devices/pending, POST /v1/devices/approve, POST /v1/devices/revoke, Bearer = device token).

Pinned: the realm is asked with THIS device's enrollment token and only when that enrollment is an approver; a paired
device asking to join is marked "paired" (a paired-only device upgrading to enrolled); approve/deny/tenant/
no-approver reach the realm as given; `approve` with no code takes the only waiting one after a yes; revoke drops the
local pairing and revokes in the realm; /v1/status says {enrolled, approver, here} and never a token; /v1/enroll/* is
refused to a paired caller on another device and to an unpaired one; nothing prints a token.
"""
import builtins
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "lib/devices/powos-deviced")

if not shutil.which("openssl"):
    print("SKIP: no openssl")
    sys.exit(0)

work = tempfile.mkdtemp()
os.environ["POWOS_DEVICED_DIR"] = os.path.join(work, "desk")
os.environ["POWOS_DEVICED_CONFIG"] = os.path.join(work, "deviced.json")
json.dump({"name": "Desk", "kind": "desktop"}, open(os.environ["POWOS_DEVICED_CONFIG"], "w"))
loader = importlib.machinery.SourceFileLoader("deviced", SRC)
spec = importlib.util.spec_from_loader("deviced", loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)

fails = []


def check(cond, what):
    if not cond:
        fails.append(what)


class Fake(d.Backend):
    kind = "desktop"

    def caps(self):
        return ["status", "lock"]

    def status(self):
        return {"online": True, "screen": "on", "locked": False, "busy": []}


d._backend = Fake()
d.show_code = lambda name, code: None

# ── the fake realm ──
TOK = "desk-realm-token"
seen = []
WAITING = [{"user_code": "BCDF-GHJK", "device": {"id": "phone1", "name": "Phone", "kind": "phone", "platform": "android"},
            "from": "192.168.50.239", "asked": 1794000000, "expires_in": 540},
           {"user_code": "MNPQ-RSTV", "device": {"id": "tv1", "name": "TV", "kind": "tv"}, "from": "192.168.50.40",
            "asked": 1794000001, "expires_in": 300}]
REGISTRY = {"phone1": False, "tv1": False, "desk": False}


class Realm(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def answer(self, code, data):
        b = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def authed(self):
        seen.append((self.command, self.path, self.headers.get("Authorization")))
        return self.headers.get("Authorization") == f"Bearer {TOK}"

    def do_GET(self):
        if not self.authed():
            return self.answer(401, {"error": "invalid_token"})
        if self.path == "/v1/devices/pending":
            return self.answer(200, {"pending": WAITING})
        if self.path == "/v1/devices":
            return self.answer(200, {"devices": [{"id": k, "name": k, "revoked": v or None} for k, v in REGISTRY.items()]})
        self.answer(404, {"error": "not_found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if not self.authed():
            return self.answer(401, {"error": "invalid_token"})
        seen[-1] = seen[-1] + (body,)
        if self.path == "/v1/devices/approve":
            p = next((p for p in WAITING if p["user_code"] == body.get("code")), None)
            if not p:
                return self.answer(410, {"error": "expired_token", "error_description": "no device is waiting with that code (it may have expired)"})
            WAITING.remove(p)
            return self.answer(200, {"state": "approved" if body["decision"] == "approve" else "denied", "device": p["device"],
                                     "tenant": body.get("tenant"), "approver": body.get("approver", True)})
        if self.path == "/v1/devices/revoke":
            hit = body.get("id") in REGISTRY and not REGISTRY[body["id"]]
            if hit:
                REGISTRY[body["id"]] = True
            return self.answer(200, {"revoked": hit})
        self.answer(404, {})


rs = ThreadingHTTPServer(("127.0.0.1", 0), Realm)
threading.Thread(target=rs.serve_forever, daemon=True).start()
REALM = f"http://127.0.0.1:{rs.server_address[1]}"


def enroll_as(approver):
    d.save_json(d.enrollment_path(), {"realm": REALM, "device_token": TOK,
                                      "device": {"id": "desk", "name": "Desk", "approver": approver}})


def cli(*argv, answer=None):
    out = io.StringIO()
    old = builtins.input
    builtins.input = lambda _p="": answer or ""
    try:
        with contextlib.redirect_stdout(out):
            try:
                d.main(list(argv))
                return 0, out.getvalue()
            except SystemExit as e:
                return 1, out.getvalue() + str(e)
    finally:
        builtins.input = old


# The Phone is paired with Desk (it controls Desk) but not enrolled: it runs `powos devices enroll`, Desk approves.
peers = {"phone1": {"id": "phone1", "name": "Phone", "kind": "phone", "token_sha256": d.sha("phone-pair-token"), "paired": 1}}
d.save_json(d.peers_path(), peers)

# 1. not enrolled / not an approver: refused with why, the realm never asked
rc, out = cli("pending")
check(rc == 1 and "isn't enrolled" in out and not seen, f"pending, not enrolled: rc {rc} {out!r}")
enroll_as(False)
rc, out = cli("pending")
check(rc == 1 and "without the right to approve" in out and not seen, f"pending, not an approver: rc {rc} {out!r}")

# 2. an approver: pending lists both, the paired Phone marked, its token never printed
enroll_as(True)
rc, out = cli("pending")
check(rc == 0 and "BCDF-GHJK  Phone (phone, android)" in out and "already paired with this device" in out.split("\n")[0]
      and "MNPQ-RSTV  TV" in out and "already paired" not in out.split("\n")[1], f"pending: {out!r}")
check(seen and seen[-1][2] == f"Bearer {TOK}", "the realm is asked with this device's own token")
check(TOK not in out, "pending printed the device token")

# 3. approve with no code while two wait: refused, lists them
rc, out = cli("approve")
check(rc == 1 and "more than one" in out, f"approve without a code, two waiting: {out!r}")

# 4. approve the Phone's code with an AI tenant: the realm gets exactly that
rc, out = cli("approve", "BCDF-GHJK", "--tenant", "default")
check(rc == 0 and out.startswith("approved: Phone (phone1), AI default, may approve others"), f"approve: {out!r}")
check(seen[-1][1] == "/v1/devices/approve" and seen[-1][3] == {"code": "BCDF-GHJK", "decision": "approve", "approver": True,
                                                                 "tenant": "default"}, f"approve body: {seen[-1]}")

# 5. approve with no code, one waiting: asks first; "n" keeps it waiting, "y" approves (here: --no-approver)
d.sys.stdin.isatty = lambda: True
rc, out = cli("approve", "--no-approver", answer="n")
check(rc == 1 and "not approved" in out and len(WAITING) == 1, f"approve, answered no: {out!r}")
rc, out = cli("approve", "--no-approver", answer="y")
check(rc == 0 and "approved: TV (tv1), no AI, may not approve others" in out and not WAITING, f"approve, answered yes: {out!r}")
check(seen[-1][3]["approver"] is False, "--no-approver reaches the realm")

# 6. an expired code: the realm's words
rc, out = cli("approve", "ZZZZ-ZZZZ", "--deny")
check(rc == 1 and "no device is waiting" in out, f"expired code: {out!r}")

# 7. revoke a lost Phone: its pairing here goes and the realm revokes it; --local only drops the pairing
rc, out = cli("revoke", "Phone")
check(rc == 0 and "phone1: may no longer control this device" in out and "revoked in the realm" in out
      and "phone1" not in d.peers() and REGISTRY["phone1"], f"revoke: {out!r}")
rc, out = cli("revoke", "tv1", "--local")
check(rc == 0 and not REGISTRY["tv1"], f"revoke --local touched the realm: {out!r}")

# 8. the agent's /v1/enroll/* for this device's Devices app, over real HTTPS
crt, key = d.tls_files()
httpd = d.listen("127.0.0.1", 0, crt, key)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
URL = f"https://127.0.0.1:{httpd.server_address[1]}"
d.save_json(d.peers_path(), {"app": {"id": "app", "name": "Devices app", "kind": "phone", "token_sha256": d.sha("app-tok"), "paired": 1},
                             "phone1": peers["phone1"]})
WAITING.append({"user_code": "WXYZ-BCDF", "device": {"id": "phone1", "name": "Phone", "kind": "phone"}, "from": "x",
                "asked": 1, "expires_in": 100})
st, r = d.request(URL + "/v1/status", token="app-tok")
check(st == 200 and r.get("realm") == {"enrolled": True, "approver": True, "here": True} and TOK not in json.dumps(r),
      f"status realm: {st} {r.get('realm')}")
st, r = d.request(URL + "/v1/enroll/pending")
check(st == 401, f"enroll/pending unpaired: {st}, want 401")
st, r = d.request(URL + "/v1/enroll/pending", token="app-tok")
check(st == 200 and r["pending"][0]["user_code"] == "WXYZ-BCDF" and r["pending"][0]["paired"] is True, f"enroll/pending: {st} {r}")
st, r = d.request(URL + "/v1/enroll/approve", "POST", {"code": "WXYZ-BCDF", "decision": "deny"}, token="app-tok")
check(st == 200 and r["state"] == "denied", f"enroll/approve deny: {st} {r}")
st, r = d.request(URL + "/v1/enroll/approve", "POST", {"code": "WXYZ-BCDF"}, token="app-tok")
check(st == 410 and "no device is waiting" in r.get("error", ""), f"a decided code again: {st} {r}")
st, r = d.request(URL + "/v1/enroll/devices", token="app-tok")
check(st == 200 and {x["id"] for x in r["devices"]} == set(REGISTRY), f"enroll/devices: {st} {r}")
st, r = d.request(URL + "/v1/enroll/revoke", "POST", {"id": "tv1"}, token="app-tok")
check(st == 200 and r["revoked"] is True and REGISTRY["tv1"], f"enroll/revoke: {st} {r}")
# a paired peer on another device: refused (pairing grants control of this device, not the realm)
real_here, d.Handler.here = d.Handler.here, (lambda self: False)
n = len(seen)
st, r = d.request(URL + "/v1/enroll/pending", token="phone-pair-token")
check(st == 403 and len(seen) == n, f"enroll/pending from another device: {st} {r}, realm asked {len(seen) - n}x")
st, r = d.request(URL + "/v1/status", token="phone-pair-token")
check(st == 200 and r["realm"]["here"] is False, f"status realm.here from another device: {r.get('realm')}")
# the realm revoked THIS device: a 403 for the app (never a 401, which would read "pair again")
d.Handler.here = real_here
enroll_as(True)
TOK_SAVED, TOK = TOK, "rotated"
st, r = d.request(URL + "/v1/enroll/pending", token="app-tok")
check(st == 403, f"realm refused this device's token: {st} {r}, want 403")
TOK = TOK_SAVED
httpd.shutdown()
rs.shutdown()

shutil.rmtree(work, ignore_errors=True)
if fails:
    for f in fails:
        print("FAIL", f)
    sys.exit(1)
print("ok deviced approve: pending/approve/deny/revoke CLI + /v1/enroll/* for this device's app, approver-only")
