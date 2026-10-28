#!/usr/bin/env python3
"""tools/phone/ship-gate.py (Mac): the LAN door for `powos self push --ship` (unit units/mac/ship-gate-mac.json).

A device that pushed a sha to origin asks here to have it shipped; this writes the SAME .req that
`tools/phone/ship.sh request` writes (it calls `ship.sh request --sha`, so the format and the "must be on origin"
rule live in one place) and kicks the ship runner. It never ships anything itself.

  POST /request  {"sha","note","from","task"?}   -> 200 {"id","message"} | 403 sha not on origin | 401 | 400
  GET  /status                                   -> 200 text: `ship.sh status`
Auth: `Authorization: Bearer <secret>`, the one shared secret in $SHIP_GATE_SECRET_FILE (default
~/.config/powos/ship-gate.secret, mode 0600) - the claude-auth AUTH_BROKER_SECRET pattern: provisioned out of band,
never in git, never logged. No secret file = the gate refuses to start. Listens on $SHIP_GATE_PORT (7433), LAN only.
"""
import hmac, json, os, re, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SHIP = os.environ.get("SHIP_SH", os.path.join(HERE, "ship.sh"))
SECRET_FILE = os.path.expanduser(os.environ.get("SHIP_GATE_SECRET_FILE", "~/.config/powos/ship-gate.secret"))
SHA_RE, DEV_RE = re.compile(r"^[0-9a-f]{7,40}$"), re.compile(r"^[A-Za-z0-9._-]{1,40}$")


def load_secret():
    with open(SECRET_FILE) as f:
        s = f.read().strip()
    if len(s) < 16:
        raise SystemExit("ship-gate: secret in %s is shorter than 16 chars" % SECRET_FILE)
    return s


def validate(d):
    """(error, args): the ship.sh request arguments for a request body, or why it is refused."""
    sha, note, dev = str(d.get("sha", "")), str(d.get("note", "")).strip(), str(d.get("from", ""))
    if not SHA_RE.match(sha):
        return "sha must be 7-40 hex chars", None
    if not DEV_RE.match(dev):
        return "from must be a device name (letters, digits, . _ -)", None
    if not note or len(note) > 500:
        return "note is required (max 500 chars)", None
    if d.get("task"):
        note += " [task %s]" % re.sub(r"[^A-Za-z0-9._-]", "", str(d["task"]))[:40]
    return None, ["request", "--sha", sha, "--note", note, "--who", "phone:" + dev]


def run_ship(args):
    p = subprocess.run(["bash", SHIP] + args, capture_output=True, text=True, timeout=60, cwd=os.path.dirname(HERE))
    return p.returncode, (p.stdout + p.stderr).strip()


class Handler(BaseHTTPRequestHandler):
    secret = ""

    def reply(self, code, body, ctype="application/json"):
        data = (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def authed(self):
        got = self.headers.get("Authorization", "")
        if hmac.compare_digest(got.encode(), ("Bearer " + self.secret).encode()):
            return True
        self.reply(401, {"error": "unauthorized"}); return False

    def do_GET(self):
        if self.path != "/status": return self.reply(404, {"error": "not found"})
        if self.authed(): self.reply(200, run_ship(["status"])[1] + "\n", "text/plain")

    def do_POST(self):
        if self.path != "/request": return self.reply(404, {"error": "not found"})
        if not self.authed(): return
        try:
            d = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 8192)) or b"{}")
        except ValueError:
            return self.reply(400, {"error": "bad json"})
        err, args = validate(d if isinstance(d, dict) else {})
        if err: return self.reply(400, {"error": err})
        rc, out = run_ship(args)
        m = re.search(r"\[id ([^\]]+)\]", out)
        if rc == 0 and m: return self.reply(200, {"id": m.group(1), "message": out.splitlines()[-1]})
        self.reply(403 if rc == 3 else 500, {"error": out[-400:]})

    def log_message(self, fmt, *a):   # no request line logged beyond status: never the Authorization header
        sys.stderr.write("ship-gate %s %s\n" % (self.address_string(), fmt % a))


if __name__ == "__main__":
    Handler.secret = load_secret()
    ThreadingHTTPServer((os.environ.get("SHIP_GATE_BIND", "0.0.0.0"), int(os.environ.get("SHIP_GATE_PORT", "7433"))), Handler).serve_forever()
