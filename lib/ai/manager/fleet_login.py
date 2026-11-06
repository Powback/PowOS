#!/usr/bin/env python3
"""PowOS's native Claude sign-in: claude-login (~/Projects/claude-login, the real `claude /login` run headless) end to
end, through one of two backends picked by how this machine's claude is configured:

  authority  an endpoint (ANTHROPIC_BASE_URL = the fleet's claude-auth.pow + the tenant's secret): the authority runs
             claude-login for the tenant (/oauth/start, /oauth/complete) and stays the only refresher; this machine
             never holds a refresh token or a .credentials.json.
  direct     no endpoint (a sellable non-root install): claude-login runs here, in PowOS's Linux, and writes this
             machine's own ~/.claude/.credentials.json (mode 600); claude refreshes it itself.

Both answer the same verbs, so the AI page, the terminal tile and the notification share one UI:

  status   {"mode", "state", "tenant", "why", "canLogin", ...} - the state is ok / missing / refresh / unknown
  word     relogin when the user is needed (missing or refresh), else the state - `powos manager --auth`'s question
  login    a held login: prints {"authorizeUrl"} as soon as claude-login has it, reads one line (the pasted code#state)
           from stdin, prints {"ok"} or {"error"}. The Kotlin host keeps the process between the two steps.

Authority detail:

The authority is the only thing that ever holds or refreshes a Claude login; this machine's claude only carries the
tenant's routing secret (ANTHROPIC_AUTH_TOKEN in /etc/powos/ai/endpoint.conf). When the tenant's login is missing or
its refresh failed, the AI page / the terminal tile / a notification offer a Login button that drives the authority's
headless login - which is ~/Projects/claude-login end to end (the real `claude /login` in a pty on the authority, the
subscription URL it prints, the code#state typed back into that same process). Nothing here builds an OAuth URL,
exchanges a code, or writes a .credentials.json; it only relays three calls, authorized with the tenant's own secret:

  status            GET /auth/check (whose tenant the secret is) + GET /tenants (that tenant's auth state)
  start <tenant>    POST /oauth/start {tenant}  -> {"authorizeUrl"}
  complete <tenant> POST /oauth/complete {code} -> {"ok", "tenant"}; the code#state is read from stdin (never argv,
                    which any process can read)

Each prints one JSON object on stdout. The secret is never printed, logged or put in an error.
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

ENDPOINT_FILE = os.environ.get("POWOS_AI_ENDPOINT_FILE", "/etc/powos/ai/endpoint.conf")

# The states the UI shows (shell/types.ts FleetLogin.state):
#   ok        the tenant's login works
#   missing   the tenant has no login at all (hasCreds false): sign-in missing
#   refresh   it has one but its refresh failed / needs re-auth (the "run /login" the user saw)
#   unknown   no endpoint, the authority unreachable, or an old authority that doesn't name the tenant
STATES = ("ok", "missing", "refresh", "unknown")


def endpoint() -> tuple[str, str]:
    """The machine's authority URL and tenant secret: the environment over endpoint.conf (as lib/ai/agent.sh)."""
    conf: dict[str, str] = {}
    try:
        with open(ENDPOINT_FILE, encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and not k.startswith("#"):
                    conf.setdefault(k, v)
    except OSError:
        pass
    url = os.environ.get("ANTHROPIC_BASE_URL") or conf.get("ANTHROPIC_BASE_URL", "")
    token = os.environ.get("ANTHROPIC_AUTH_TOKEN") or conf.get("ANTHROPIC_AUTH_TOKEN", "")
    return url.rstrip("/"), token


def call(url: str, token: str, method: str, path: str, body: dict | None = None, timeout: float = 5) -> tuple[int, dict]:
    """(status, json) of one authority call; (0, {"error"}) when it can't be reached. Never echoes the secret."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url + path, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, _json(r.read())
    except urllib.error.HTTPError as e:
        return e.code, _json(e.read())
    except (OSError, ValueError) as e:
        return 0, {"error": f"the authority ({url}) can't be reached: {type(e).__name__}"}


def _json(raw: bytes) -> dict:
    try:
        v = json.loads(raw or b"{}")
        return v if isinstance(v, dict) else {}
    except ValueError:
        return {}


def classify(row: dict | None) -> tuple[str, str]:
    """A /tenants row's (state, why): its broker status (auth.ok / hasCreds / needsReauth / lastError)."""
    if not row:
        return "unknown", ""
    auth = row.get("auth") or {}
    err = str(auth.get("lastError") or "")
    if auth.get("ok"):
        return "ok", ""
    if auth.get("mode") == "follower":
        return "unknown", "this tenant is a follower: sign in on its authority"
    if not auth.get("hasCreds"):
        return "missing", err or "no Claude login yet"
    if auth.get("needsReauth") or err:
        return "refresh", err or "the login needs a refresh"
    return "unknown", ""


def status(url: str, token: str) -> dict:
    out: dict = {"mode": "authority", "state": "unknown", "tenant": None, "why": "", "canLogin": False, "candidates": []}
    code, check = call(url, token, "GET", "/auth/check", timeout=4)
    if code == 0:
        out["why"] = check.get("error", "")
        return out
    code_t, tenants = call(url, token, "GET", "/tenants", timeout=4)
    rows = tenants.get("tenants") if isinstance(tenants.get("tenants"), list) else []
    if code == 200 and check.get("tenant"):
        name = str(check["tenant"])
        out["tenant"], out["canLogin"] = name, True
    elif code == 200:
        # HACK: an authority older than claude-rate-limiter agent/native-claude-signin (ab1c334) answers /auth/check
        # without the tenant's name. The tenants that need a login are offered and the authority 403s a wrong pick
        # (a secret only re-logs its own tenant). Real fix: that branch deployed; then drop this. docs/REMOTE-POWOS.md §4.
        out["canLogin"] = True
        out["candidates"] = [r.get("name") for r in rows if classify(r)[0] in ("missing", "refresh")]
        if len(out["candidates"]) == 1:
            name = out["candidates"][0]
            out["tenant"] = name
        else:
            out["why"] = "pick the account to sign in"
            if out["candidates"]:
                out["state"] = "refresh"
            return out
    else:
        # Not a tenant secret: the proxy routes it to the default subscription, which only the admin can re-login.
        name = next((r.get("name") for r in rows if r.get("isDefault")), None)
        out["tenant"] = name
        out["why"] = "this machine's token can't sign in by itself: sign in at " + url + "/manage"
    row = next((r for r in rows if r.get("name") == out["tenant"]), None)
    state, why = classify(row)
    out["state"] = state
    if not out["canLogin"] and state in ("missing", "refresh"):
        out["why"] = (why + " - " if why else "") + out["why"]
    elif why:
        out["why"] = why
    return out


def start(url: str, token: str, tenant: str) -> dict:
    # claude /login starts in a pty on the authority and steps its menus: a few seconds, rarely more.
    code, r = call(url, token, "POST", "/oauth/start", {"tenant": tenant}, timeout=90)
    if code == 200 and r.get("authorizeUrl"):
        return {"ok": True, "tenant": tenant, "authorizeUrl": r["authorizeUrl"]}
    return {"ok": False, "tenant": tenant, "error": r.get("error") or f"start failed (HTTP {code})"}


def complete(url: str, token: str, tenant: str, code_state: str) -> dict:
    code_state = code_state.strip()
    if not code_state:
        return {"ok": False, "tenant": tenant, "error": "paste the code from claude.com first"}
    code, r = call(url, token, "POST", "/oauth/complete", {"tenant": tenant, "code": code_state}, timeout=90)
    if code == 200 and r.get("ok"):
        return {"ok": True, "tenant": r.get("tenant") or tenant}
    return {"ok": False, "tenant": tenant, "error": r.get("error") or f"sign-in failed (HTTP {code})"}


# ── direct: claude-login here, this machine's own login ───────────────────────────────────────────────────────────
def creds_path() -> str:
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"), ".credentials.json")


def direct_status() -> dict:
    """This machine's own login from its credentials file: only the presence of a refresh token and the expiry are
    looked at - nothing of it is printed."""
    out: dict = {"mode": "direct", "state": "missing", "tenant": None, "why": "not signed in to Claude", "canLogin": True}
    if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        out.update(state="ok", why="")
        return out
    try:
        with open(creds_path(), encoding="utf-8") as f:
            oauth = (json.load(f) or {}).get("claudeAiOauth") or {}
    except (OSError, ValueError, AttributeError):
        return out
    if not oauth.get("accessToken"):
        return out
    if not oauth.get("refreshToken"):
        # Nothing to refresh with: claude says "run /login" once the access token runs out.
        exp = oauth.get("expiresAt") or 0
        if exp and exp < time.time() * 1000:
            out.update(state="refresh", why="the login expired")
            return out
    out.update(state="ok", why="")
    return out


def claude_login_cmd() -> list[str] | None:
    """claude-login (~/Projects/claude-login): POWOS_CLAUDE_LOGIN (its dist/cli.js, or a command), else on PATH."""
    c = os.environ.get("POWOS_CLAUDE_LOGIN", "")
    if c.endswith(".js") and os.path.exists(c) and shutil.which("node"):
        return ["node", c]
    if c and shutil.which(c):
        return [c]
    if shutil.which("claude-login"):
        return ["claude-login"]
    return None


URL_RE = re.compile(r"https://\S+/oauth/authorize\?\S+")


def direct_login() -> int:
    cmd = claude_login_cmd()
    if not cmd:
        emit({"ok": False, "error": "claude-login isn't installed on this machine (POWOS_CLAUDE_LOGIN or claude-login on PATH)"})
        return 1
    path = creds_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".powos-login"
    # The credentials go straight to a file of mode 600 (claude-login -o), never through this process or the app.
    p = subprocess.Popen([*cmd, "-o", tmp], stdin=subprocess.PIPE, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True)
    tail: list[str] = []
    url = None
    assert p.stderr and p.stdin
    for line in p.stderr:
        tail = (tail + [line.strip()])[-5:]
        m = URL_RE.search(line)
        if m:
            url = m.group(0)
            break
    if not url:
        p.wait()
        emit({"ok": False, "error": next((t for t in reversed(tail) if t), "claude-login printed no sign-in link")})
        return 1
    emit({"ok": True, "authorizeUrl": url})
    code = sys.stdin.readline().strip()
    if not code:
        p.kill()
        emit({"ok": False, "error": "cancelled"})
        return 1
    p.stdin.write(code + "\n")
    p.stdin.close()
    rest = p.stderr.read()
    rc = p.wait()
    if rc == 0 and os.path.exists(tmp):
        os.replace(tmp, path)
        emit({"ok": True, "done": True})
        return 0
    with contextlib.suppress(OSError):
        os.remove(tmp)
    why = next((ln.strip().lstrip("✗ ").strip() for ln in reversed(rest.splitlines()) if ln.strip()), "")
    emit({"ok": False, "error": why or f"sign-in failed (claude-login {rc})"})
    return 1


def authority_login(url: str, token: str, tenant: str | None) -> int:
    if not tenant:
        st = status(url, token)
        tenant = st.get("tenant")
        if not tenant or not st.get("canLogin"):
            emit({"ok": False, "error": st.get("why") or "no tenant to sign in"})
            return 1
    r = start(url, token, tenant)
    emit(r)
    if not r.get("ok"):
        return 1
    code = sys.stdin.readline()
    if not code.strip():
        emit({"ok": False, "tenant": tenant, "error": "cancelled"})
        return 1
    r = complete(url, token, tenant, code)
    if r.get("ok"):
        r["done"] = True
    emit(r)
    return 0 if r.get("ok") else 1


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def main(argv: list[str]) -> int:
    verb = argv[0] if argv else "status"
    url, token = endpoint()
    if verb in ("status", "word"):
        st = status(url, token) if url else direct_status()
        st.setdefault("mode", "authority")
        if verb == "word":
            print("relogin" if st["state"] in ("missing", "refresh") else st["state"])
        else:
            emit(st)
        return 0
    if verb == "login":
        return authority_login(url, token, argv[1] if len(argv) > 1 else None) if url else direct_login()
    if verb in ("start", "complete") and len(argv) > 1 and url:
        res = start(url, token, argv[1]) if verb == "start" else complete(url, token, argv[1], sys.stdin.read())
        emit(res)
        return 0 if res.get("ok") else 1
    print("usage: fleet_login.py status | word | login [tenant] | start <tenant> | complete <tenant> (code on stdin)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
