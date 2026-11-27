#!/usr/bin/env python3
"""lib/apps/powos-drop: the universal clipboard and Send to my device between two Linux devices of one account.

A stand-in for the realm's drop store (PowStation enroll/powos-enroll.py /v1/account/drop*, whose own test pins the
server: memory-only clips, expiry, account isolation, revocation) with the same contract: ciphertext in, per-device
visibility, a clip to everyone but its sender, a send to one device until done, expiry, 401 for a revoked token.
Pinned here: the drop key is made once and shared (a second device creating it at the same time gets the first one);
the realm never sees the plaintext (text, file name); a clip reaches the other device and is not offered back; a send
is saved under a safe name and taken off the realm; expired clips are gone; a third account's device can't open a drop;
too-big clips are refused and an over-16 MB file without a writable NAS is refused with the reason; a revoked device
drops its key; the switch (`off`) stops this device offering its clips; a handoff (a page continued on another
device) arrives as Continue, not as a file.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import secrets
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    import cryptography  # noqa: F401
except ImportError:
    print("skip: python3-cryptography missing (tools/jobs/tier1.Dockerfile installs it)")
    sys.exit(0)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
loader = importlib.machinery.SourceFileLoader("powosdrop", os.path.join(REPO, "lib/apps/powos-drop"))
spec = importlib.util.spec_from_loader("powosdrop", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
fails = 0


def check(cond, what):
    global fails
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails += 1


TOKENS = {"tok-desk": "desk", "tok-fold": "fold"}
DEVICES = {"desk": "Desk", "fold": "Fold", "tv": "TV"}
STORE = {"secret": {}, "drops": {}, "bodies": []}
CLIP_TTL = 1.0


class Realm(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, st, data, ctype="application/json"):
        b = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(st)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def handle_any(self):
        u = urlparse(self.path)
        q, path = parse_qs(u.query), u.path
        me = TOKENS.get(self.headers.get("Authorization", "")[7:])
        if not me:
            return self.reply(401, {"error": "invalid_token"})
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        t = time.time()
        for i in [i for i, d in STORE["drops"].items() if d["expires"] <= t]:
            del STORE["drops"][i]
        if path == "/v1/devices":
            return self.reply(200, {"devices": [{"id": i, "name": n, "self": i == me, "revoked": i == "tv"}
                                                for i, n in DEVICES.items()]})
        if path == "/v1/account/secret" and self.command == "POST":
            b = json.loads(body)
            k = (b["app"], b["name"])
            if b.get("keep") and k in STORE["secret"]:
                return self.reply(200, {"ok": True, "value": STORE["secret"][k]})
            STORE["secret"][k] = b["value"]
            return self.reply(200, {"ok": True})
        if path == "/v1/account/drop":
            kind, to = q["kind"][0], q.get("to", ["*"])[0]
            if kind == "send" and to not in DEVICES:
                return self.reply(404, {"error": "not_found", "error_description": "no such device in this account"})
            i = secrets.token_urlsafe(18)
            STORE["drops"][i] = {"id": i, "kind": kind, "from": me, "from_name": DEVICES[me], "to": to if kind == "send" else "*",
                                 "size": len(body), "at": int(t), "expires": t + (CLIP_TTL if kind == "clip" else 60), "ct": body}
            STORE["bodies"].append(body)
            return self.reply(200, {"id": i, "expires": 0})
        vis = [d for d in STORE["drops"].values() if d["from"] != me and d["to"] in ("*", me)]
        if path == "/v1/account/drops":
            kind = q.get("kind", [""])[0]
            return self.reply(200, {"drops": [{k: v for k, v in d.items() if k != "ct"} for d in vis if kind in ("", d["kind"])]})
        if path.startswith("/v1/account/drop/"):
            i = path.split("/")[4]
            d = next((d for d in vis if d["id"] == i), None)
            if not d:
                return self.reply(404, {"error": "not_found"})
            if path.endswith("/done"):
                if d["kind"] == "send":
                    del STORE["drops"][i]
                return self.reply(200, {"ok": True})
            return self.reply(200, d["ct"], "application/octet-stream")
        return self.reply(404, {"error": "not_found"})

    do_GET = do_POST = handle_any


srv = ThreadingHTTPServer(("127.0.0.1", 0), Realm)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_port}"
tmp = tempfile.mkdtemp(prefix="drops-")


def device(name, token):
    d = f"{tmp}/{name}"
    os.makedirs(f"{d}/deviced", exist_ok=True)
    with open(f"{d}/deviced/enrollment.json", "w") as f:
        json.dump({"realm": base, "device_token": token}, f)
    return d


def be(d):
    m.DEVICED, m.STATE = f"{d}/deviced", f"{d}/state"
    return m.Realm()


desk, fold = device("desk", "tok-desk"), device("fold", "tok-fold")

# The drop key: made once; the second device to ask gets the first one's.
k_desk = be(desk).key()
k_fold = be(fold).key()
check(k_desk == k_fold and len(k_desk) == 32, "one drop key per account, shared by both devices")
check(oct(os.stat(f"{desk}/state/drop.key").st_mode & 0o777) == "0o600", "the key is kept 0600")

# A clip: Desk copies, Fold is offered it; Desk isn't offered its own.
be(desk).put("clip", *m.text_item("secret clipboard words"))
got = m.clips(be(fold))
check([c["text"] for c in got] == ["secret clipboard words"] and got[0]["from"] == "Desk", "a clip reaches the other device")
check(m.clips(be(desk)) == [], "a clip is not offered back to its sender")
check(all(b"secret clipboard" not in b for b in STORE["bodies"]), "the realm only ever sees ciphertext")
check(m.text_item("https://x.org/a")[0] == "link", "a lone URL travels as a link")
time.sleep(CLIP_TTL + 0.2)
check(m.clips(be(fold)) == [], "a clip expires")

# A send: Fold sends Desk a file; Desk's inbox saves it under a safe name and the realm's copy goes.
src = f"{tmp}/report.pdf"
with open(src, "wb") as f:
    f.write(b"%PDF-1.4 hello")
check(m.send(be(fold), "Desk", path=src) == "sent to Desk", "send a file by device name")
check(all(b"report.pdf" not in b for b in STORE["bodies"]), "the file name is sealed too")
out = f"{tmp}/downloads"
got = m.inbox(be(desk), out)
check(len(got) == 1 and open(got[0]["saved"], "rb").read() == b"%PDF-1.4 hello" and got[0]["saved"].endswith("report.pdf"),
      "the target saves the file")
check(m.inbox(be(desk), out) == [], "a send is taken off the realm once saved")
m.send(be(fold), "Desk", text="call me")
check(m.inbox(be(desk), out) == [{"from": "Fold", "type": "text", "text": "call me"}], "a text send")
# Handoff: Fold's page continues on Desk ("Continue <title> from Fold"); Desk's inbox reports it and saves nothing.
m.notify = lambda *a: None
opened = []
m.continue_here = lambda frm, h: opened.append((frm, h.get("url")))
check(m.handoff(be(fold), "Desk", "https://notes.pow/n/42", "Notes") == "continue on Desk", "a handoff by device name")
check(m.inbox(be(desk), out) == [{"from": "Fold", "type": "handoff", "title": "Notes", "url": "https://notes.pow/n/42", "app": None}]
      and opened == [("Fold", "https://notes.pow/n/42")], "a handoff arrives as Continue, nothing saved")
try:
    m.handoff(be(fold), "Desk", "file:///etc/passwd")
    check(False, "a non-web URL is refused")
except m.Refused:
    check(True, "a non-web URL is refused")
check(m.safe_name({"name": "../../.ssh/authorized_keys", "type": "file"}) == "authorized_keys", "no path in a name")
try:
    m.send(be(fold), "TV", text="x")
    check(False, "a revoked device is no target")
except m.Refused as e:
    check("no single device" in str(e), "a revoked device is no target")

# Another account's device (its own key) can't open a drop.
other = m.seal(secrets.token_bytes(32), "clip", "text", b"theirs")
check(m.open_(k_desk, "clip", other) is None, "another account's drop doesn't open")
check(m.open_(k_desk, "send", m.seal(k_desk, "clip", "text", b"x")) is None, "a clip can't be replayed as a send")

# Caps.
m.NAS = f"{tmp}/no-nas"
big = f"{tmp}/big.bin"
with open(big, "wb") as f:
    f.truncate(m.SEND_MAX + 1)
try:
    m.send(be(fold), "Desk", path=big)
    check(False, "an over-16 MB file without the NAS is refused")
except m.Refused as e:
    check("16 MB max" in str(e) and "NAS" in str(e), "an over-16 MB file without the NAS is refused, with why")
os.makedirs(m.NAS)
m.NAS_URL = "http://cdn.test"
check("NAS link" in m.send(be(fold), "Desk", path=big), "an over-16 MB file goes as a NAS link")
got = m.inbox(be(desk), out)
check(got and got[0]["type"] == "link" and got[0]["text"].startswith("http://cdn.test/powos-drop/"), "the link arrives")
sys.stdout, saved = io.StringIO(), sys.stdout
rc = m.main(["powos-drop", "clip", "-t", "x" * (m.CLIP_MAX + 1)])
sys.stdout = saved
check(rc == 1, "a clip over 1 MB is refused")

# The switch: off on Desk, nothing it copies leaves.
m.STATE = f"{desk}/state"
m.main(["powos-drop", "off"])
check(not m.clip_on() and m.main(["powos-drop", "clip", "-t", "nope"]) == 1, "the shared clipboard off: nothing offered")
m.main(["powos-drop", "on"])
check(m.clip_on(), "and on again")

# Revoked: the realm answers 401, the device forgets the key.
del TOKENS["tok-fold"]
try:
    be(fold).waiting("clip")
except m.Refused as e:
    check("isn't in the account" in str(e) and not os.path.exists(f"{fold}/state/drop.key"), "a revoked device drops its key")

srv.shutdown()
print(f"\n{'PASS' if not fails else f'{fails} FAILED'}: powos-drop")
sys.exit(1 if fails else 0)
