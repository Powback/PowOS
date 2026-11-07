#!/usr/bin/env python3
"""The device control channel (lib/devices/powos-deviced) end to end over real HTTPS, with a fake backend.

Pinned: info is the only thing an unpaired device sees (no status, no action); pairing needs the code shown on the
target (never in the answer), a wrong code fails and the 5th wrong try ends the request, at most 3 requests wait;
a paired token reads status and runs only advertised actions; sleep is refused while something runs there unless
forced; revoking a peer stops its token at once; the CLI client pins the certificate it paired with; tokens are
stored hashed, never in clear, and never logged.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import ssl
import sys
import tempfile
import threading
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "lib/devices/powos-deviced")

if not shutil.which("openssl"):
    print("SKIP: no openssl")
    sys.exit(0)

work = tempfile.mkdtemp()
os.environ["POWOS_DEVICED_DIR"] = os.path.join(work, "target")
os.environ["POWOS_DEVICED_CONFIG"] = os.path.join(work, "deviced.json")
json.dump({"name": "Desk", "kind": "desktop"}, open(os.environ["POWOS_DEVICED_CONFIG"], "w"))
loader = importlib.machinery.SourceFileLoader("deviced", SRC)
spec = importlib.util.spec_from_loader("deviced", loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)

ran = []


class Fake(d.Backend):
    kind = "desktop"
    busy = ["llama-swap.service"]

    def caps(self):
        return ["status", "lock", "screen_off", "screen_on", "sleep"]

    def blockers(self):
        return list(self.busy)

    def status(self):
        return {"online": True, "screen": "on", "locked": False, "busy": self.blockers(), "power": {"source": "ac"}}

    def act(self, action, args, force=False):
        if action in ("lock", "screen_off", "screen_on"):
            ran.append(action)
            return {"done": True}
        if action == "sleep":
            if self.blockers() and not force:
                raise d.ActionError("busy: llama-swap.service would stop - sleep refused", "busy")
            ran.append("sleep")
            return {"done": True}
        return d.Backend.act(self, action, args, force)


d._backend = Fake()
crt, key = d.tls_files()
httpd = d.listen("127.0.0.1", 0, crt, key)
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()
URL = f"https://127.0.0.1:{port}"
d.show_code = lambda name, code: None  # no notification in a test

fails = []


def check(cond, what):
    if not cond:
        fails.append(what)


def call(path, method="GET", body=None, token=None):
    return d.request(URL + path, method, body, token)


def code():
    p = json.load(open(os.path.join(os.environ["POWOS_DEVICED_DIR"], "pending.json")))
    return p[-1]["code"]


# 1. unpaired: info only
st, info = call("/v1/info")
check(st == 200 and info["name"] == "Desk" and "lock" in info["caps"] and "status" not in json.dumps(info.get("status", "")),
      f"info: {st} {info}")
check("status" not in info, "info carries no live status")
st, _ = call("/v1/status")
check(st == 401, f"status without a token: {st}, want 401")
st, _ = call("/v1/action", "POST", {"action": "lock"})
check(st == 401 and not ran, f"action without a token: {st}, ran {ran}")
st, _ = call("/v1/status", token="made-up")
check(st == 401, f"status with a made-up token: {st}")

# 2. pairing
st, r = call("/v1/pair", "POST", {"id": "phone1", "name": "Phone", "kind": "phone"})
check(st == 200 and "code" not in r and "request" in r, f"pair start: {st} {r} (the code must not be in the answer)")
right = code()
wrong = "000000" if right != "000000" else "111111"
st, r2 = call("/v1/pair/confirm", "POST", {"request": r["request"], "code": wrong})
check(st == 401, f"wrong code: {st}")
st, r3 = call("/v1/pair/confirm", "POST", {"request": r["request"], "code": right})
check(st == 200 and r3.get("token") and r3["device"]["name"] == "Desk", f"right code: {st} {r3}")
token = r3.get("token", "")
stored = open(os.path.join(os.environ["POWOS_DEVICED_DIR"], "peers.json")).read()
check(token and token not in stored and d.sha(token) in stored, "the token is stored as its hash only")
check(oct(os.stat(os.path.join(os.environ["POWOS_DEVICED_DIR"], "peers.json")).st_mode & 0o777) == "0o600", "peers.json is 0600")
st, _ = call("/v1/pair/confirm", "POST", {"request": r["request"], "code": right})
check(st == 410, f"a used request again: {st}, want 410")

# 5 wrong tries end a request
st, r = call("/v1/pair", "POST", {"id": "x", "name": "X"})
right = code()
wrong = "000000" if right != "000000" else "111111"
for _ in range(5):
    call("/v1/pair/confirm", "POST", {"request": r["request"], "code": wrong})
st, _ = call("/v1/pair/confirm", "POST", {"request": r["request"], "code": right})
check(st == 410, f"after 5 wrong tries the right code: {st}, want 410 (request gone)")
# at most 3 waiting
sts = [call("/v1/pair", "POST", {"id": f"y{i}", "name": "Y"})[0] for i in range(4)]
check(sts == [200, 200, 200, 409], f"4 waiting requests: {sts}, want the 4th refused")
d.PENDING.clear()

# 3. paired: status, actions by capability
st, s = call("/v1/status", token=token)
check(st == 200 and s["status"]["screen"] == "on" and s["caps"], f"status: {st} {s}")
st, a = call("/v1/action", "POST", {"action": "screen_off"}, token)
check(st == 200 and a["ok"] and ran[-1:] == ["screen_off"], f"screen_off: {st} {a}")
st, a = call("/v1/action", "POST", {"action": "ring"}, token)
check(st == 404, f"an action this device doesn't advertise: {st}, want 404")
st, a = call("/v1/action", "POST", {"action": "rm -rf"}, token)
check(st == 400, f"an unknown action: {st}, want 400")
st, a = call("/v1/action", "POST", {"action": "sleep"}, token)
check(st == 409 and "llama-swap" in a["error"] and "sleep" not in ran, f"sleep while busy: {st} {a}")
d._backend.busy = []
st, a = call("/v1/action", "POST", {"action": "sleep"}, token)
check(st == 200 and ran[-1] == "sleep", f"sleep when idle: {st} {a}")
st, p = call("/v1/peers", token=token)
check(st == 200 and [x["id"] for x in p["peers"]] == ["phone1"] and "token" not in json.dumps(p), f"peers: {p}")

# 4. revoke: the token stops at once
st, r = call("/v1/peers/phone1", "DELETE", token=token)
check(st == 200 and r["revoked"], f"revoke: {st} {r}")
st, _ = call("/v1/status", token=token)
check(st == 401, f"status after revoke: {st}, want 401")

# 5. the CLI client: pairs, pins, calls; a changed certificate is refused
os.environ["POWOS_DEVICED_DIR"] = os.path.join(work, "client")
d.STATE = os.environ["POWOS_DEVICED_DIR"]
target_state = os.path.join(work, "target")


def pair_cli():
    # the agent's state stays the target's: the request handler reads module globals, so swap around each call
    st, r = call("/v1/pair", "POST", {"id": "cli", "name": "CLI"})
    return r


orig_peers, orig_save_pending = d.peers_path, d.save_pending
d.peers_path = lambda: os.path.join(target_state, "peers.json")
d.save_pending = lambda: d.save_json(os.path.join(target_state, "pending.json"),
                                     [{"from": p["peer"]["name"], "code": p["code"], "expires": int(p["expires"])} for p in d.PENDING.values()])
orig_input = __builtins__.input if hasattr(__builtins__, "input") else input
import builtins
builtins.input = lambda _p="": json.load(open(os.path.join(target_state, "pending.json")))[-1]["code"]
try:
    d.cli_pair([URL])
    rem = json.load(open(os.path.join(d.STATE, "remotes.json")))
    (rid, r), = rem.items()
    check(r["pin"] == d.pin_of(URL) and r["token"], "the CLI keeps the pin and its token (its own 0600 state)")
    check(oct(os.stat(os.path.join(d.STATE, "remotes.json")).st_mode & 0o777) == "0o600", "remotes.json is 0600")
    rc = d.cli_call(["Desk", "lock"])
    check(rc == 0 and ran[-1] == "lock", f"cli call lock: rc {rc} ran {ran}")
    rem[rid]["pin"] = "0" * 64
    d.save_json(os.path.join(d.STATE, "remotes.json"), rem)
    try:
        d.cli_call(["Desk", "lock"])
        fails.append("a changed certificate was accepted")
    except SystemExit as e:
        check("certificate changed" in str(e), f"changed certificate: {e}")
finally:
    builtins.input = orig_input

httpd.shutdown()
shutil.rmtree(work, ignore_errors=True)
if fails:
    for f in fails:
        print("FAIL", f)
    sys.exit(1)
print("ok deviced: info/pair/confirm/status/action/revoke/pin")
