#!/usr/bin/env python3
"""appcap_serve.py - the App API app's local service: the runtime's files and call path, over loopback HTTP.

Runs on PowOS itself (the phone's system tier, lib/apps/services/app-api.json), never on the Mac. The App API app's
page reaches it with host.net.fetch("http://127.0.0.1:3411/..."); on the phone the port is locked to the PowOS uid
(rooted/powos-start.sh POWOS_PORTS), so no other Android app can call it.

It adds no logic of its own: views are appcap_render.py's, calls are appcap_run.py's (one subprocess per call, so the
one call path stays the only place that can say no), toggles are the spec's own `enabled` flags.

  GET  /apps                       every spec: app, actions, safety, enabled (handles only, never a token)
  GET  /views?app=A                {api, tools, cli, widgets}: appcap_render.py's output
  POST /enable {app, action?, enabled}         the kill switch / the per-action allowlist (spec re-validated)
  POST /call {app, action, args, send}         appcap_run.py; send only for `read` (first slice), never `spend`
  GET  /audit?app=A&n=100          the audit log, newest first
  GET  /trackers                   the proxy's tracker log, per app + a summary (empty until the proxy writes it)
  POST /trackers/allow {app, allow}            per-app "allow trackers" (trackers/policy.json, read by the proxy)
  GET|POST /rules, GET /recordings, GET /recording?name=, POST /recording/edit|replay   appcap_flows.py
  GET /files, GET|POST /files/override                                                 appcap_files.py

State: appcap_store.STATE (~/.local/state/powos/app-api): specs/<app>.appcap.json (seeded from examples/ once),
audit/<app>.jsonl, trackers/<app>.jsonl + trackers/policy.json. Stdlib only. Never prints or returns a token.
"""
from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import appcap_files  # noqa: E402
import appcap_flows  # noqa: E402
import appcap_render  # noqa: E402
import appcap_store  # noqa: E402
import appcap_validate  # noqa: E402

STATE = appcap_store.STATE
SPECS = os.path.join(STATE, "specs")
TRACKERS = os.path.join(STATE, "trackers")
PORT = int(os.environ.get("POWOS_APPAPI_PORT", "3411"))
MAX_BODY = 64 << 10
KEEP = ("summary", "safety", "origin", "promoted", "widget", "confirm", "confirm_template", "undo", "refresh",
        "inputs", "output", "enabled")


def seed():
    """The package's example specs, copied once: from then on the state's copy is the user's (its toggles)."""
    os.makedirs(SPECS, mode=0o700, exist_ok=True)
    for src in glob.glob(os.path.join(HERE, "examples", "*.appcap.json")):
        dst = os.path.join(SPECS, os.path.basename(src))
        if not os.path.exists(dst):
            shutil.copyfile(src, dst)


def spec_path(app: str) -> str:
    p = os.path.join(SPECS, f"{app}.appcap.json")
    if os.path.basename(p) != f"{app}.appcap.json" or not os.path.exists(p):
        raise LookupError(f"no app '{app}'")
    return p


def valid(path: str) -> dict:
    errs = [e for e in appcap_validate.validate(path, show_list=False) if "WARN" not in e]
    if errs:
        raise ValueError("; ".join(errs))
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def endpoint_text(ep: dict) -> str:
    if ep.get("ui"):
        ui = ep["ui"]
        return "open " + (ui.get("deep_link") or ui.get("route") or f"{len(ui.get('steps', []))} step(s)")
    if ep.get("argv"):
        return " ".join(ep["argv"])
    return f"{ep.get('method', 'GET')} {ep.get('path') or ep.get('operationId', '?')}"


def summary(path: str) -> dict:
    s = valid(path)
    toks = (s.get("auth") or {}).get("tokens", {})
    acts = {}
    for aid, a in s["actions"].items():
        acts[aid] = {k: a[k] for k in KEEP if k in a}
        acts[aid]["enabled"] = a.get("enabled", True)
        acts[aid]["endpoint"] = endpoint_text(a.get("endpoint", {}))
        auth = (a.get("endpoint") or {}).get("auth")
        if auth in toks:
            acts[aid]["auth"] = toks[auth].get("store")  # the handle, never a value
    return {"app": s["app"], "name": s.get("name", s["app"]), "description": s.get("description", ""),
            "enabled": s.get("enabled", False), "base": (s.get("base") or {}).get("url", ""), "actions": acts}


def apps(_q, _b):
    out = []
    for p in sorted(glob.glob(os.path.join(SPECS, "*.appcap.json"))):
        try:
            out.append(summary(p))
        except (OSError, ValueError, KeyError) as e:
            out.append({"app": os.path.basename(p).split(".")[0], "error": str(e)[:300]})
    return {"apps": out}


def views(q, _b):
    s = valid(spec_path(q["app"]))
    return {"api": appcap_render.render_api(s), "tools": appcap_render.render_tools(s),
            "cli": appcap_render.render_cli(s), "widgets": appcap_render.render_widgets(s)}


def write_json(path: str, data: dict):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    return tmp


def enable(_q, b):
    path = spec_path(b["app"])
    with open(path, encoding="utf-8") as f:
        s = json.load(f)
    on = bool(b["enabled"])
    if b.get("action"):
        if b["action"] not in s["actions"]:
            raise LookupError(f"no action '{b['action']}'")
        s["actions"][b["action"]]["enabled"] = on
    else:
        s["enabled"] = on
    tmp = write_json(path, s)
    try:
        valid(tmp)  # a toggle never leaves an invalid spec behind
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return summary(path)


def call(_q, b):
    path = spec_path(b["app"])
    s = valid(path)
    act = s["actions"].get(b["action"])
    if not act:
        raise LookupError(f"no action '{b['action']}'")
    send = bool(b.get("send"))
    if send and act["safety"] == "spend":
        return {"refused": "confirm in chat: a spend action is never sent from this app"}
    if send and act["safety"] != "read":
        return {"refused": "writes are dry-run only in this version"}
    argv = [sys.executable, os.path.join(HERE, "appcap_run.py"), path, b["action"], "--consumer", "app", "--json"]
    for k, v in (b.get("args") or {}).items():
        if v not in (None, ""):
            argv += ["--arg", f"{k}={json.dumps(v) if isinstance(v, bool) else v}"]
    if send:
        argv.append("--send")
    p = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    if p.returncode:
        return {"refused": (p.stderr.strip().splitlines() or ["refused"])[-1]}
    return json.loads(p.stdout)


def tail(path: str, n: int) -> list:
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()[-n:]
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def audit(q, _b):
    n = min(int(q.get("n", 100)), 500)
    pat = f"{q['app']}.jsonl" if q.get("app") else "*.jsonl"
    rows = [r for p in glob.glob(os.path.join(STATE, "audit", pat)) for r in reversed(tail(p, n))]
    rows.sort(key=lambda r: r.get("ts", ""), reverse=True)
    return {"rows": rows[:n]}


def policy() -> dict:
    try:
        with open(os.path.join(TRACKERS, "policy.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"apps": {}}


def trackers(_q, _b):
    allow = policy().get("apps", {})
    per = {}
    for p in glob.glob(os.path.join(TRACKERS, "*.jsonl")):
        for r in tail(p, 5000):
            app = r.get("app") or os.path.basename(p)[:-6]
            key = (r.get("tracker") or r.get("host") or "?", r.get("host", ""))
            t = per.setdefault(app, {}).setdefault(key, {"tracker": key[0], "host": key[1],
                                                         "category": r.get("category", ""), "blocked": 0, "allowed": 0})
            t["blocked" if r.get("action") == "blocked" else "allowed"] += int(r.get("count", 1))
    out = [{"app": a, "allow": bool((allow.get(a) or {}).get("allow")),
            "seen": sorted(ts.values(), key=lambda t: -(t["blocked"] + t["allowed"]))} for a, ts in sorted(per.items())]
    total = {"apps": len(out), "trackers": len({t["tracker"] for a in out for t in a["seen"]}),
             "blocked": sum(t["blocked"] for a in out for t in a["seen"]),
             "allowed": sum(t["allowed"] for a in out for t in a["seen"])}
    return {"apps": out, "total": total}


def trackers_allow(_q, b):
    os.makedirs(TRACKERS, mode=0o700, exist_ok=True)
    pol = policy()
    pol.setdefault("apps", {})[str(b["app"])] = {"allow": bool(b["allow"])}
    path = os.path.join(TRACKERS, "policy.json")
    os.replace(write_json(path, pol), path)
    return pol


ROUTES = {("GET", "/apps"): apps, ("GET", "/views"): views, ("POST", "/enable"): enable, ("POST", "/call"): call,
          ("GET", "/audit"): audit, ("GET", "/trackers"): trackers, ("POST", "/trackers/allow"): trackers_allow,
          **appcap_flows.ROUTES, **appcap_files.ROUTES}


class Handler(BaseHTTPRequestHandler):
    def reply(self, code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_one(self, method: str):
        u = urlparse(self.path)
        fn = ROUTES.get((method, u.path))
        if not fn:
            return self.reply(404, {"error": "no such route"})
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        b = {}
        if method == "POST":
            n = int(self.headers.get("content-length") or 0)
            if n > MAX_BODY:
                return self.reply(413, {"error": "too big"})
            b = json.loads(self.rfile.read(n) or b"{}")
        try:
            self.reply(200, fn(q, b))
        except (LookupError, KeyError) as e:
            self.reply(404, {"error": str(e).strip("'\"")})
        except (ValueError, TypeError, subprocess.TimeoutExpired) as e:
            self.reply(400, {"error": str(e)[:300]})

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")

    def log_message(self, *_a):  # no request log: the audit log is the record
        pass


def main():
    seed()
    appcap_flows.seed()
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
