#!/usr/bin/env python3
"""Remote unlock (lib/devices/powos-deviced `unlock`) over real HTTPS, the real KDE backend and a fake loginctl.

Pinned: a desktop advertises unlock, a phone never does; unlock is logind's UnlockSession on this user's seat0 session
(no password anywhere); a paired device that isn't the owner is refused 403 and loginctl is never run; `owner <device>`
(run on the device) lets it, `--off` takes it back; an approver device enrolled in this device's realm may too, a
revoked or non-approver one may not; /v1/status says {you: {owner}} and locked goes false after unlock; every unlock
and refusal is logged with the peer id and never a token.
"""
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
bindir = os.path.join(work, "bin")
os.makedirs(bindir)
LOG = os.path.join(work, "loginctl.log")
LOCKED = os.path.join(work, "locked")
open(LOCKED, "w").close()
uid = os.getuid()
# A stateful logind: list-sessions (a background session first, then this user's seat0 one), lock/unlock, LockedHint.
open(os.path.join(bindir, "loginctl"), "w").write(f"""#!/bin/sh
echo "$@" >> {LOG}
case "$1" in
  list-sessions) printf '     1 {uid} powos -     2052 manager -    no -\\n     7 {uid} powos seat0 2075 user tty1 no -\\n' ;;
  lock-session) touch {LOCKED} ;;
  unlock-session) rm -f {LOCKED} ;;
  show-session) [ -e {LOCKED} ] && echo yes || echo no ;;
esac
""")
open(os.path.join(bindir, "kscreen-doctor"), "w").write("#!/bin/sh\necho 'Output: 1 DP-1 dpms mode: on'\n")
for f in ("loginctl", "kscreen-doctor"):
    os.chmod(os.path.join(bindir, f), 0o755)
os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
os.environ["POWOS_DEVICED_DIR"] = os.path.join(work, "state")
os.environ["POWOS_DEVICED_CONFIG"] = os.path.join(work, "deviced.json")
os.environ["POWOS_DEVICED_BACKEND"] = "desktop"
json.dump({"name": "Desk", "kind": "desktop"}, open(os.environ["POWOS_DEVICED_CONFIG"], "w"))
loader = importlib.machinery.SourceFileLoader("deviced", SRC)
spec = importlib.util.spec_from_loader("deviced", loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)
d.show_code = lambda name, code: None
d.KdeBackend.blockers = lambda self: []
d.KdeBackend.wol = lambda self: []

fails = []


def check(cond, what):
    if not cond:
        fails.append(what)


def ran():
    return open(LOG).read() if os.path.exists(LOG) else ""


err = io.StringIO()
crt, key = d.tls_files()
httpd = d.listen("127.0.0.1", 0, crt, key)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
URL = f"https://127.0.0.1:{httpd.server_address[1]}"


def call(path, method="GET", body=None, token=None):
    return d.request(URL + path, method, body, token)


def pair(pid, name):
    st, r = call("/v1/pair", "POST", {"id": pid, "name": name, "kind": "laptop"})
    code = json.load(open(os.path.join(d.STATE, "pending.json")))[-1]["code"]
    st, r = call("/v1/pair/confirm", "POST", {"request": r["request"], "code": code})
    return r["token"]


# 1. capabilities: a desktop advertises unlock; a phone (rooted or not) never does
st, info = call("/v1/info")
check("unlock" in info["caps"] and "lock" in info["caps"], f"desktop caps: {info['caps']}")
check("unlock" not in d.AndroidBackend().caps(), "a phone never advertises unlock")
check("unlock" not in d.Backend().caps(), "a server never advertises unlock")

with contextlib.redirect_stderr(err):
    mac = pair("mac1", "Mac")
    tv = pair("tv1", "TV")
    # 2. not the owner: refused, logind never asked to unlock
    st, s = call("/v1/status", token=mac)
    check(st == 200 and s["status"]["locked"] is True and s["you"] == {"owner": False}, f"status, not owner: {st} {s}")
    st, a = call("/v1/action", "POST", {"action": "unlock"}, mac)
    check(st == 403 and "owner" in a["error"] and "unlock-session" not in ran(), f"unlock, not owner: {st} {a}")
    # 3. the owner mark, set on the device: unlock = loginctl unlock-session <this user's seat0 session>
    with contextlib.redirect_stdout(io.StringIO()):
        check(d.main(["owner", "Mac"]) == 0, "owner Mac")
    check(json.load(open(d.peers_path()))["mac1"].get("owner") is True, "owner mark stored")
    st, a = call("/v1/action", "POST", {"action": "unlock"}, mac)
    check(st == 200 and a["ok"] and "unlock-session 7" in ran(), f"unlock, owner: {st} {a} {ran()!r}")
    st, s = call("/v1/status", token=mac)
    check(s["status"]["locked"] is False and s["you"] == {"owner": True}, f"status after unlock: {s}")
    check("unlock-session 1" not in ran(), "never the background session")
    # lock still for any paired device; unlock still not for the TV
    st, a = call("/v1/action", "POST", {"action": "lock"}, tv)
    check(st == 200 and "lock-session 7" in ran(), f"lock by a non-owner: {st}")
    st, a = call("/v1/action", "POST", {"action": "unlock"}, tv)
    check(st == 403, f"unlock by the TV: {st}")
    # 4. --off takes it back
    with contextlib.redirect_stdout(io.StringIO()):
        d.main(["owner", "mac1", "--off"])
    st, a = call("/v1/action", "POST", {"action": "unlock"}, mac)
    check(st == 403, f"unlock after owner --off: {st}")
    try:
        d.main(["owner", "nobody"])
        fails.append("owner of an unpaired device accepted")
    except SystemExit as e:
        check("not paired" in str(e), f"owner nobody: {e}")

# 5. the realm: an enrolled approver device may unlock; a non-approver or revoked one may not
REG = {"mac1": {"approver": True}, "tv1": {"approver": False}}


class Realm(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        ok = self.headers.get("Authorization") == "Bearer realm-tok" and self.path == "/v1/devices"
        b = json.dumps({"devices": [{"id": k, **v} for k, v in REG.items()]} if ok else {"error": "invalid_token"}).encode()
        self.send_response(200 if ok else 401)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


rs = ThreadingHTTPServer(("127.0.0.1", 0), Realm)
threading.Thread(target=rs.serve_forever, daemon=True).start()
d.save_json(d.enrollment_path(), {"realm": f"http://127.0.0.1:{rs.server_address[1]}", "device_token": "realm-tok",
                                  "device": {"id": "desk", "name": "Desk", "approver": False}})
with contextlib.redirect_stderr(err):
    open(LOCKED, "w").close()
    st, a = call("/v1/action", "POST", {"action": "unlock"}, mac)
    check(st == 200, f"unlock by an enrolled approver: {st} {a}")
    st, a = call("/v1/action", "POST", {"action": "unlock"}, tv)
    check(st == 403, f"unlock by an enrolled non-approver: {st}")
    REG["mac1"]["revoked"] = 1794000000
    d.REALM_OWNERS.clear()  # (the realm's answer is kept a minute; a revoke there counts from the next ask)
    st, a = call("/v1/action", "POST", {"action": "unlock"}, mac)
    check(st == 403, f"unlock by a revoked approver: {st}")
    rs.shutdown()
    rs.server_close()
    d.REALM_OWNERS.clear()
    st, a = call("/v1/action", "POST", {"action": "unlock"}, mac)
    check(st == 403, f"unlock with the realm down and no owner mark: {st}")
httpd.shutdown()

log = err.getvalue()
check("action unlock by mac1 (owner)" in log and "action unlock refused for tv1" in log, f"log: {log!r}")
check(mac not in log and tv not in log and "realm-tok" not in log, "no token in the log")

shutil.rmtree(work, ignore_errors=True)
if fails:
    for f in fails:
        print("FAIL", f)
    sys.exit(1)
print("ok deviced unlock: desktop only, owner/approver only, logind unlock-session, logged")
