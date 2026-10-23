#!/usr/bin/env python3
"""appcap_run.py - the app-api RUNTIME: one shared call path every consumer uses.

    resolve action -> check app+action allowlist -> enforce safety class ->
    inject auth by handle -> rate-limit -> dry-run / send -> append audit line

Runs LOCALLY on PowOS (phone Linux + desktop), offline/LAN. Stdlib + the local
encrypted store (appcap_store.py); no Mac, no cloud at runtime.

The safety rules live HERE, once, so no consumer can bypass them:
  - read               : may send.
  - reversible-write    : may send only with --send; the undo action is recorded.
  - spend               : may send only with --send AND --confirm "<text>"; the
                          confirm_template (what + how much) is shown first; a
                          widget consumer can never reach it.
  - widget consumer     : may only call `read` actions (refused otherwise).
  - captured + non-read : refused unless the action is promoted.
  - DEFAULT IS DRY-RUN  : without --send nothing leaves the machine; the exact
                          request is previewed (auth shown only as its handle).

Every call appends one line to <state>/audit/<app>.jsonl with secret-pattern
args redacted; a token value is never logged or printed.

Usage:
  appcap_run.py SPEC ACTION [--arg k=v]... [--state k=v]... \
      [--consumer ai|cli|sdk|widget|app] [--send] [--confirm TEXT] [--json]
Default (no --send) = dry-run preview. Exit 0 ok, 3 = refused by safety/allowlist.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.request

import appcap_store
import appcap_validate

STATE = appcap_store.STATE
SECRET_ARG = re.compile(r"(token|secret|session|auth|cookie|password|key|signature)", re.I)
REFUSED = 3


def _audit(app: str, rec: dict):
    d = os.path.join(STATE, "audit")
    os.makedirs(d, mode=0o700, exist_ok=True)
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), **rec}
    with open(os.path.join(d, f"{app}.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def _redact(args: dict) -> dict:
    return {k: ("<redacted>" if SECRET_ARG.search(k) else v) for k, v in args.items()}


def _rate_ok(app: str, action: str, limit: dict) -> bool:
    per_min = (limit or {}).get("per_minute")
    if not per_min:
        return True
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    path = os.path.join(STATE, "ratelimit.json")
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
    now = time.time()
    key = f"{app}:{action}"
    hits = [t for t in data.get(key, []) if now - t < 60]
    if len(hits) >= per_min:
        return False
    hits.append(now)
    data[key] = hits
    json.dump(data, open(path, "w"))
    return True


def _fill(obj, args: dict):
    if isinstance(obj, str):
        for k, v in args.items():
            obj = obj.replace("{" + k + "}", str(v))
        return obj
    if isinstance(obj, dict):
        return {k: _fill(v, args) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_fill(v, args) for v in obj]
    return obj


def main() -> int:
    ap = argparse.ArgumentParser(description="app-api runtime call path")
    ap.add_argument("spec")
    ap.add_argument("action")
    ap.add_argument("--arg", action="append", default=[], metavar="k=v")
    ap.add_argument("--state", action="append", default=[], metavar="k=v",
                    help="placeholder values from PowOS app state (e.g. bridge_ip=...)")
    ap.add_argument("--consumer", default="cli", choices=["ai", "cli", "sdk", "widget", "app"])
    ap.add_argument("--send", action="store_true", help="actually perform (default: dry-run)")
    ap.add_argument("--confirm", help="the user's typed confirmation for a spend action")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    # refuse an invalid/unsafe spec before doing anything
    errs = [e for e in appcap_validate.validate(a.spec, show_list=False) if "WARN" not in e]
    if errs:
        for e in errs:
            print("ERROR " + e, file=sys.stderr)
        return REFUSED
    spec = json.load(open(a.spec, encoding="utf-8"))
    args = dict(p.split("=", 1) for p in a.arg)
    state = dict(p.split("=", 1) for p in a.state)
    app = spec["app"]
    act = spec["actions"].get(a.action)

    def refuse(why: str) -> int:
        _audit(app, {"consumer": a.consumer, "action": a.action,
                     "safety": (act or {}).get("safety"), "sent": False,
                     "refused": why, "args": _redact(args)})
        print(f"REFUSED: {why}", file=sys.stderr)
        return REFUSED

    if not act:
        print(f"no such action '{a.action}'", file=sys.stderr)
        return REFUSED
    safety = act["safety"]

    # ---- allowlist ----
    if not spec.get("enabled", False):
        return refuse(f"app '{app}' is not enabled")
    if act.get("enabled", True) is False:
        return refuse(f"action '{a.action}' is not in the allowlist")

    # ---- safety class ----
    if act["origin"] == "captured" and safety != "read" and not act.get("promoted"):
        return refuse("captured action is read-only until promoted")
    if a.consumer == "widget" and safety != "read":
        return refuse("a widget may only call read actions")

    sending = a.send
    if safety == "reversible-write" and sending:
        pass  # allowed; undo recorded below
    if safety == "spend":
        if sending and not a.confirm:
            return refuse("spend action needs --confirm with the user's yes")
        if sending:
            tmpl = _fill(act.get("confirm_template", "(no template)"), {**state, **args})
            print(f"confirmation shown: {tmpl}", file=sys.stderr)

    # ---- rate limit ----
    limit = act.get("rate_limit") or (spec.get("defaults") or {}).get("rate_limit")
    if sending and not _rate_ok(app, a.action, limit):
        return refuse(f"rate limit exceeded ({limit})")

    # ---- build the request (auth by handle; value only resolved if sending) ----
    ep = act["endpoint"]
    ph = {**state, **args}
    preview = {"consumer": a.consumer, "app": app, "action": a.action, "safety": safety,
               "dry_run": not sending}
    headers = {}
    tok_handle = None
    auth = ep.get("auth")
    if auth:
        t = (spec.get("auth") or {}).get("tokens", {}).get(auth, {})
        tok_handle = t.get("store")
        hdr = t.get("header") or ("Cookie" if t.get("type") == "cookie" else None)
        preview["auth"] = f"{hdr or t.get('query','?')} <- {tok_handle} (value never shown)"

    if ep.get("ui"):
        ui = _fill(ep["ui"], ph)
        target = ui.get("deep_link") or ui.get("route") or f"{len(ui.get('steps', []))} step(s)"
        preview["ui"] = target
        result = {"preview": preview}
        if sending:
            # On real PowOS this invokes the opener/deep-link; here we record intent.
            result["opened"] = target
        print(json.dumps(result, indent=2) if a.json else f"UI -> {target}" + ("" if sending else "  (dry-run)"))
        _audit(app, {**preview, "sent": sending, "args": _redact(args)})
        return 0

    base = (spec.get("base") or {}).get("url", "")
    if ep.get("argv"):  # native CLI / D-Bus surface
        argv = _fill(ep["argv"], ph)
        preview["argv"] = argv
    else:
        preview["request"] = f"{ep.get('method','GET')} {_fill(base + ep.get('path',''), ph)}"
        if ep.get("body"):
            preview["body"] = _fill(ep["body"], ph)

    status, body = None, None
    if sending:
        t0 = time.time()
        if ep.get("argv"):
            import subprocess
            p = subprocess.run(preview["argv"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            status, body = p.returncode, p.stdout[:4000]
        else:
            method = ep.get("method", "GET")
            url = _fill(base + ep.get("path", ""), ph)
            data = None
            if ep.get("body"):
                data = json.dumps(_fill(ep["body"], ph)).encode()
                headers["content-type"] = "application/json"
            if auth and tok_handle:                      # resolve in-process, never print
                val = appcap_store.get_secret(tok_handle).decode()
                t = (spec.get("auth") or {}).get("tokens", {}).get(auth, {})
                headers[t.get("header", "authorization")] = (
                    val if t.get("type") != "bearer" or val.lower().startswith("bearer") else "Bearer " + val)
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    status, body = r.status, r.read(4000).decode("utf-8", "replace")
            except Exception as e:
                status, body = "error", str(e)[:200]
        preview["sent"] = True
        preview["status"] = status
        preview["duration_ms"] = int((time.time() - t0) * 1000)
    if safety == "reversible-write" and act.get("undo"):
        preview["undo"] = act["undo"]

    _audit(app, {**preview, "sent": sending, "args": _redact(args)})
    out = {"preview": preview}
    if sending and body is not None:
        out["response_sample"] = body
    print(json.dumps(out, indent=2) if a.json else json.dumps(preview, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
