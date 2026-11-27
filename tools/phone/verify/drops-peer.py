#!/usr/bin/env python3
"""drops-peer.py - the "other signed-in device" for tools/phone/verify/drops.sh: a test device of the owner's account
(kind "test", no approver rights, no AI subscription) on the Mac, which speaks drops through the Linux tool itself
(lib/apps/powos-drop: same envelope, same realm calls), so every leg of the check is one implementation sealing and the
other opening. Run with python-cryptography (drops.sh: `uv run --with cryptography`).

  drops-peer.py enroll                    once, by the owner: asks to join the realm and prints the user code; the
                                          OWNER approves it (Devices app "New device wants to join", or on the server
                                          `docker exec powos-enroll powos-enroll approve <code> --no-approver`); it waits
                                          up to 15 min and prints its id. Never approved by a script: the account is
                                          the owner's to grow
  drops-peer.py id                        its device id
  drops-peer.py sends <from-id> <nonce>   sends to it from <from-id> whose text/name contains <nonce>: opened, marked
                                          done, printed as JSON lines {id, type, name, text|sha256, size}
  drops-peer.py clips <from-id> <nonce>   clips from <from-id> containing <nonce>, opened: JSON lines {id, text}
  drops-peer.py clip TEXT                 offer TEXT as its clip; prints the drop id
  drops-peer.py send <to-id> TEXT         send TEXT to one device; prints the drop id
  drops-peer.py handoff <to-id> URL TITLE a handoff ("Continue TITLE" there, devices/Handoff.kt); prints the drop id
  drops-peer.py state <id>                "waiting" while the drop is still in the realm, "gone" once taken/withdrawn
  drops-peer.py done <id>                 withdraw its own drop (a clip it offered)

State: DROPS_PEER_DIR (default ~/.local/state/powos/verify-drops-peer): enrollment.json (0600) and drop/drop.key.
HACK: a standing test device in the account, because the realm hides a device's own drops from its list (a phone
can't receive from itself) and a fresh enrollment per run would page the owner each time. Real fix: a realm test
fixture (e.g. ENROLL_TEST_PEER) that needs no enrollment.
"""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.environ.get("DROPS_PEER_DIR") or os.path.expanduser("~/.local/state/powos/verify-drops-peer")
os.environ["POWOS_DEVICED_DIR"] = DIR
os.environ["POWOS_DROP_DIR"] = os.path.join(DIR, "drop")
REALM = os.environ.get("DROPS_REALM", "http://powstation.pow")
PEER_ID = "verify-drops-peer"


def tool():
    path = os.path.join(HERE, "..", "..", "..", "lib", "apps", "powos-drop")
    loader = importlib.machinery.SourceFileLoader("powos_drop", path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("powos_drop", loader))
    loader.exec_module(mod)
    return mod


def post(path, body):
    req = urllib.request.Request(REALM + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")


def enroll():
    f = os.path.join(DIR, "enrollment.json")
    if os.path.exists(f):
        print(json.load(open(f))["device"]["id"])
        return 0
    c = post("/v1/device/code", {"id": PEER_ID, "name": "PowOS verify (drops check)", "kind": "test",
                                 "platform": "verify queue on the Mac", "caps": []})
    if "user_code" not in c:
        print(f"enroll: {c}", file=sys.stderr)
        return 1
    print(f"approve {c['user_code']} for 'PowOS verify (drops check)' (kind test): Devices app, or on the server "
          f"docker exec powos-enroll powos-enroll approve {c['user_code']} --no-approver", file=sys.stderr)
    for _ in range(int(c.get("expires_in", 900)) // max(1, c.get("interval", 5))):
        time.sleep(c.get("interval", 5))
        r = post("/v1/device/token", {"device_code": c["device_code"]})
        if r.get("device_token"):
            os.makedirs(DIR, mode=0o700, exist_ok=True)
            fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as out:
                json.dump({"realm": r.get("realm") or REALM, "device": r["device"],
                           "device_token": r["device_token"]}, out)
            print(r["device"]["id"])
            return 0
        if r.get("error") not in ("authorization_pending", "slow_down"):
            print(f"enroll: {r}", file=sys.stderr)
            return 1
    return 1


def main(a):
    if a[:1] == ["enroll"]:
        return enroll()
    if not a or a[0] not in ("id", "sends", "clips", "clip", "send", "handoff", "state", "done"):
        print(__doc__)
        return 2
    d = tool()
    realm = d.Realm()
    cmd = a[0] if a else ""
    if cmd == "id":
        print(json.load(open(os.path.join(DIR, "enrollment.json")))["device"]["id"])
    elif cmd in ("sends", "clips"):
        frm, nonce = a[1], a[2]
        for w in realm.waiting(cmd[:-1]):
            if w.get("from") != frm:
                continue
            got = realm.take(w)
            if not got:
                print(json.dumps({"id": w["id"], "error": "didn't open with the account's drop key"}))
                continue
            h, body = got
            text = body.decode(errors="replace") if h.get("type") in ("text", "link") else None
            if nonce not in (text or "") and nonce not in (h.get("name") or ""):
                continue
            o = {"id": w["id"], "type": h.get("type"), "name": h.get("name"), "size": len(body)}
            o.update({"text": text} if text is not None else {"sha256": hashlib.sha256(body).hexdigest()})
            print(json.dumps(o))
            if cmd == "sends":
                realm.json("POST", f"/v1/account/drop/{w['id']}/done", {})
    elif cmd == "clip":
        typ, body = d.text_item(a[1])
        print(realm.put("clip", typ, body, mime="text/plain")["id"])
    elif cmd == "send":
        typ, body = d.text_item(a[2])
        print(realm.put("send", typ, body, a[1], mime="text/plain")["id"])
    elif cmd == "handoff":
        body = json.dumps({"v": 1, "title": a[3], "url": a[2]}).encode()
        print(realm.put("send", "handoff", body, a[1], a[3], "application/json")["id"])
    elif cmd == "state":
        st, _ = realm.call("GET", f"/v1/account/drop/{a[1]}")
        print("waiting" if st == 200 else "gone" if st == 404 else f"http {st}")
    elif cmd == "done":
        realm.json("POST", f"/v1/account/drop/{a[1]}/done", {})
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # noqa: BLE001 - the check prints the reason as its FAIL/SKIP line
        print(f"drops-peer: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
