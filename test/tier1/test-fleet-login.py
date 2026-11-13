#!/usr/bin/env python3
"""PowOS's native Claude sign-in (lib/ai/manager/fleet_login.py) against a fake fleet authority.

Pinned: whose tenant the secret is (/auth/check's name, unknown with /manage for an old authority, the default for a
non-tenant secret); both states the user can hit - sign-in missing (no creds) and needs refresh (refresh failed) -
and ok; start/complete relay the authority's claude-login flow with the tenant's own secret (the code from stdin, not
argv); `powos manager --auth` says relogin and a chat turn emits {"kind": "relogin"} with status 4; the secret is
never printed.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(REPO, "lib/ai/manager/fleet_login.py")
SECRET = "tenant-secret-FIXTURE"

STATE = {"name_tenant": True, "auth": {}, "seen": []}


def row(name, auth, default=False):
    return {"name": name, "isDefault": default, "credentialsPath": "/x", "auth": auth}


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def mine(self):
        return self.headers.get("Authorization") == "Bearer " + SECRET

    def do_GET(self):
        if self.path == "/auth/check":
            if not self.mine():
                return self.reply(401, {"ok": False, "admin": False})
            body = {"ok": True, "admin": False}
            if STATE["name_tenant"]:
                body["tenant"] = "powback"
            return self.reply(200, body)
        if self.path == "/tenants":
            return self.reply(200, {"tenants": [row("default", {"ok": True, "hasCreds": True}, True), row("powback", STATE["auth"])]})
        self.reply(404, {})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        STATE["seen"].append((self.path, body, self.mine()))
        if not self.mine():
            return self.reply(401, {"error": "unauthorized"})
        if self.path == "/oauth/start":
            return self.reply(200, {"authorizeUrl": "https://claude.com/cai/oauth/authorize?fixture=1"})
        if self.path == "/oauth/complete":
            if body.get("code") == "good#state":
                return self.reply(200, {"ok": True, "tenant": "powback"})
            return self.reply(400, {"error": "invalid code"})
        self.reply(404, {})


srv = HTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{srv.server_port}"

work = tempfile.mkdtemp()
conf = os.path.join(work, "endpoint.conf")
with open(conf, "w") as f:
    f.write(f"ANTHROPIC_BASE_URL={URL}\nANTHROPIC_AUTH_TOKEN={SECRET}\n")
other = os.path.join(work, "other.conf")
with open(other, "w") as f:
    f.write(f"ANTHROPIC_BASE_URL={URL}\nANTHROPIC_AUTH_TOKEN=proxy-managed\n")

passed = failed = 0
printed = []


def check(cond, what):
    global passed, failed
    if cond:
        passed += 1
        print("  ok:", what)
    else:
        failed += 1
        print("  FAIL:", what)


def helper(conf_path, *args, stdin=""):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "POWOS_AI_ENDPOINT_FILE": conf_path,
       "MANAGER_CLAUDE_CMD": "true"}   # claude "installed": the install word (missing CLI) is test-manager-auth's
    p = subprocess.run([sys.executable, HELPER, *args], input=stdin, capture_output=True, text=True, env=env, timeout=30)
    printed.append(p.stdout + p.stderr)
    return p


def status(conf_path=conf):
    return json.loads(helper(conf_path, "status").stdout)


print("== fleet login (native Claude sign-in via the authority's claude-login) ==")

STATE["auth"] = {"ok": False, "mode": "authority", "hasCreds": True, "needsReauth": True, "lastError": "refresh token itself has expired"}
s = status()
check(s["state"] == "refresh" and s["tenant"] == "powback" and s["canLogin"], f"refresh failed -> needs refresh, own tenant ({s})")
check("expired" in s["why"], "the why is the authority's error")
check(helper(conf, "word").stdout.strip() == "relogin", "word: relogin")

STATE["auth"] = {"ok": False, "mode": "authority", "hasCreds": False, "lastError": None}
s = status()
check(s["state"] == "missing", f"no creds -> sign-in missing ({s['state']})")

STATE["auth"] = {"ok": True, "mode": "authority", "hasCreds": True}
s = status()
check(s["state"] == "ok", "a working login -> ok")
check(helper(conf, "word").stdout.strip() == "ok", "word: ok (not relogin)")

STATE["name_tenant"] = False
STATE["auth"] = {"ok": False, "hasCreds": True, "needsReauth": True, "lastError": "x"}
s = status()
check(s["tenant"] is None and s["state"] == "unknown" and not s["canLogin"] and "/manage" in s["why"], "old authority (no tenant name): unknown, sign in at /manage")
STATE["name_tenant"] = True

s = status(other)
check(s["tenant"] == "default" and not s["canLogin"] and "/manage" in s["why"], "a non-tenant secret: the default, sign in at /manage")


dead = os.path.join(work, "dead.conf")
with open(dead, "w") as f:
    f.write("ANTHROPIC_BASE_URL=http://127.0.0.1:9\nANTHROPIC_AUTH_TOKEN=x\n")
s = status(dead)
check(s["state"] == "unknown" and "can't be reached" in s["why"], "authority down -> unknown, not relogin")

p = helper(conf, "start", "powback")
r = json.loads(p.stdout)
check(p.returncode == 0 and r["authorizeUrl"].startswith("https://claude.com/"), "start: the authority's claude /login URL")
check(STATE["seen"][-1] == ("/oauth/start", {"tenant": "powback"}, True), "start: POST /oauth/start {tenant} with the tenant's own secret")

p = helper(conf, "complete", "powback", stdin="  good#state\n")
r = json.loads(p.stdout)
check(p.returncode == 0 and r["ok"], "complete: code#state from stdin -> ok")
check(STATE["seen"][-1][1].get("code") == "good#state", "complete: the code is trimmed and sent in the body")
p = helper(conf, "complete", "powback", stdin="bad")
r = json.loads(p.stdout)
check(p.returncode == 1 and r["error"] == "invalid code", "complete: the authority's error comes back")
r = json.loads(helper(conf, "complete", "powback", stdin="").stdout)
check(not r["ok"] and "paste" in r["error"], "complete: nothing pasted -> asks for the code, no call")

# powos manager --auth / a chat turn with the tenant needing a login.
STATE["auth"] = {"ok": False, "hasCreds": True, "needsReauth": True, "lastError": "x"}
script = f"""
source "{REPO}/lib/ai/agent.sh" >/dev/null 2>&1
_ai_load_agent() {{ :; }}
source "{REPO}/lib/ai/manager/manager.sh"
# After the source, or manager.sh's own definition wins: a chat turn runs _manager_ensure_claude before the sign-in
# gate, and the real one downloads Claude Code into $HOME (~20 s, network) - a 60 s timeout in a loaded full run.
_manager_ensure_claude() {{ :; }}
manager_run "$@"; echo "rc=$?"
"""
bin_dir = os.path.join(work, "bin")
os.makedirs(bin_dir, exist_ok=True)
broker = os.path.join(work, "broker.py")
with open(broker, "w") as f:
    f.write('print("BROKER-RAN")\n')
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": work, "TMPDIR": work, "MANAGER_CLAUDE_CMD": "true", "POWOS_AI_ENDPOINT_FILE": conf,
       "MANAGER_SERVER": broker, "MANAGER_SANDBOX": "/nonexistent", "AI_STATE_DIR": os.path.join(work, "state")}


def manager(*args):
    p = subprocess.run(["bash", "-c", script, "_", *args], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL, timeout=60)
    printed.append(p.stdout + p.stderr)
    return p.stdout


check(manager("--auth") == "relogin\nrc=0\n", "manager --auth: relogin")
out = manager("--once-stdin", "--json-events")
check(out == '{"kind": "relogin"}\nrc=4\n', f"a chat turn: the relogin event, status 4, no broker ({out!r})")
out = manager("--fleet-login", "status")
check('"state": "refresh"' in out and '"tenant": "powback"' in out, "manager --fleet-login status relays the helper")
STATE["auth"] = {"ok": True, "hasCreds": True}
check(manager("--auth") == "endpoint\nrc=0\n", "manager --auth: endpoint again once the login works")

# --- authority: the held login (one process: the URL, then the pasted code) ---------------------------------------
STATE["auth"] = {"ok": False, "hasCreds": True, "needsReauth": True, "lastError": "refresh token itself has expired"}
p = helper(conf, "login", stdin="good#state\n")
lines = [json.loads(x) for x in p.stdout.splitlines()]
check(p.returncode == 0 and lines[0].get("authorizeUrl") and lines[1].get("done"), f"login (authority): URL first, then done ({lines})")
check([x[0] for x in STATE["seen"][-2:]] == ["/oauth/start", "/oauth/complete"], "login (authority): start then complete, own secret")
p = helper(conf, "login", stdin="\n")
check(p.returncode == 1 and "cancelled" in p.stdout, "login (authority): nothing pasted = cancelled")

# --- direct: no endpoint, claude-login here, this machine's own .credentials.json -----------------------------------
home = os.path.join(work, "dhome")
os.makedirs(os.path.join(home, ".claude"))
fake = os.path.join(work, "bin", "claude-login")
with open(fake, "w") as f:
    f.write("""#!/usr/bin/env python3
import sys
out = sys.argv[sys.argv.index("-o") + 1]
print("Open this, sign in with the subscription account, and authorize:", file=sys.stderr)
print("https://claude.com/cai/oauth/authorize?code=true&state=fx", file=sys.stderr, flush=True)
code = sys.stdin.readline().strip()
if code != "good#state":
    print("\u2717 invalid code", file=sys.stderr); sys.exit(1)
open(out, "w").write('{"claudeAiOauth": {"accessToken": "ACCESS-FIXTURE", "refreshToken": "REFRESH-FIXTURE", "expiresAt": 1}}')
""")
os.chmod(fake, 0o755)
none = os.path.join(work, "none.conf")


def direct(*args, stdin=""):
    env2 = {"PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "POWOS_AI_ENDPOINT_FILE": none}
    p = subprocess.run([sys.executable, HELPER, *args], input=stdin, capture_output=True, text=True, env=env2, timeout=30)
    printed.append(p.stdout + p.stderr)
    return p


s = json.loads(direct("status").stdout)
check(s["mode"] == "direct" and s["state"] == "missing" and s["canLogin"], f"direct, no login: sign-in missing ({s})")
p = direct("login", stdin="bad\n")
lines = [json.loads(x) for x in p.stdout.splitlines()]
check(p.returncode == 1 and lines[0]["authorizeUrl"].startswith("https://claude.com/cai/oauth/authorize") and lines[-1]["error"] == "invalid code",
      f"direct login: claude-login's URL, its error back ({lines})")
check(not os.path.exists(os.path.join(home, ".claude", ".credentials.json")), "direct login failed: no credentials file")
p = direct("login", stdin="good#state\n")
cred = os.path.join(home, ".claude", ".credentials.json")
check(p.returncode == 0 and json.loads(p.stdout.splitlines()[-1]).get("done") and os.path.exists(cred), "direct login: done, this machine's own credentials file")
check("ACCESS-FIXTURE" not in p.stdout + p.stderr, "direct login: the credentials never pass through the output")
s = json.loads(direct("status").stdout)
check(s["state"] == "ok", "direct, logged in (a refresh token): ok")
with open(cred, "w") as f:
    f.write('{"claudeAiOauth": {"accessToken": "ACCESS-FIXTURE", "expiresAt": 1}}')
s = json.loads(direct("status").stdout)
check(s["state"] == "refresh", "direct, expired without a refresh token: needs refresh")
check(all("ACCESS-FIXTURE" not in t and "REFRESH-FIXTURE" not in t for t in printed), "no credential is ever printed")

check(not any(SECRET in t for t in printed), "the tenant secret is never printed")

srv.shutdown()
print(f"  {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
