#!/usr/bin/env python3
"""appcap_proxy.py - the local capture + rules + tracker-blocking proxy for ONE enabled app.

Runs on PowOS itself (the phone's system tier / desktop), offline/LAN. It is the piece that FEEDS the App API app's
Recordings / Rules / Trackers tabs, which until now only edited local state. Nothing here is Mac-side.

Per the plan it is strictly per-app: one capture session runs as `--app NAME`, and on the phone only that app's
traffic is routed here (per-app routing / allowlist); every other app passes untouched. A capture session is an
explicit, bounded thing the user starts and stops.

For each request it sees:
  1. rules.json (appcap_flows): the first matching enabled rule BLOCKs (drop, never forwarded) or REWRITEs.
  2. tracker classification (appcap_block): tracker/analytics -> BLOCKED by default, unless the per-app
     trackers/policy.json says allow=true for this app (the Trackers tab's per-app "allow" switch). Every tracker
     decision is logged to trackers/<app>.jsonl ({ts, app, host, tracker, category, action, count}) for the tab.
  3. functional calls are forwarded and RECORDED to recordings/<app>-<date>.har (HAR is the interchange har2openapi
     reads). Secret-looking values are the recording side's concern (appcap_flows hides them on read); the HAR is
     written 0600 under the app-api state dir and never leaves the LAN.

HTTPS: a CONNECT is blocked at the host level when the host is a tracker/blocked (no bytes leave), otherwise tunneled.
Recording HTTPS bodies needs the local CA (the on-device unit app-ca) + is the on-device step; plain HTTP is recorded
in full here. SELinux is never touched; this is a userspace proxy.

  appcap_proxy.py --app NAME [--port 0] [--once]      start the proxy (prints the chosen port)
Decision logic is also importable (decide(app, host, path)) so the policy is unit-testable without forwarding.
Stdlib only. Never prints or records a token value to any human-facing output.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import appcap_block  # noqa: E402
import appcap_flows  # noqa: E402
import appcap_store  # noqa: E402

STATE = appcap_store.STATE
TRACKERS = os.path.join(STATE, "trackers")
RECS = appcap_flows.RECS


def _policy_allows(app: str) -> bool:
    try:
        with open(os.path.join(TRACKERS, "policy.json"), encoding="utf-8") as f:
            return bool((json.load(f).get("apps", {}).get(app) or {}).get("allow"))
    except (OSError, ValueError):
        return False


def decide(app: str, host: str, path: str = "") -> dict:
    """What the proxy will do with host+path for this app. No network, no side effects — the testable core."""
    rules = appcap_flows.get_rules(None, None).get("rules", [])
    r = appcap_flows.rule_for(host, path, rules)
    if r and r.get("action") == "block":
        return {"decision": "block", "reason": "rule", "rule": r.get("id"), "category": "rule"}
    cat, _ = appcap_block.classify(host, path)
    if cat in appcap_block.BLOCK_CATEGORIES and not _policy_allows(app):
        return {"decision": "block", "reason": "tracker", "category": cat}
    if r and r.get("action") == "rewrite":
        return {"decision": "rewrite", "rule": r.get("id"), "category": cat}
    return {"decision": "allow", "category": cat}


def _log_tracker(app: str, host: str, category: str, action: str):
    os.makedirs(TRACKERS, mode=0o700, exist_ok=True)
    with open(os.path.join(TRACKERS, f"{app}.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "app": app, "host": host,
                            "tracker": host, "category": category, "action": action, "count": 1}) + "\n")


def _record(app: str, entry: dict):
    os.makedirs(RECS, mode=0o700, exist_ok=True)
    p = os.path.join(RECS, f"{app}-{time.strftime('%Y%m%d')}.har")
    try:
        with open(p, encoding="utf-8") as f:
            har = json.load(f)
    except (OSError, ValueError):
        har = {"log": {"version": "1.2", "creator": {"name": "appcap_proxy", "version": "1"}, "entries": []}}
    har["log"]["entries"].append(entry)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(har, f)
    os.replace(tmp, p)


def _har_entry(method: str, url: str, req_headers: dict, status: int, body: bytes, mime: str) -> dict:
    return {
        "startedDateTime": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "request": {"method": method, "url": url,
                    "headers": [{"name": k, "value": v} for k, v in req_headers.items()],
                    "queryString": []},
        "response": {"status": status, "content": {"mimeType": mime, "text": body[:8000].decode("utf-8", "replace")}},
    }


def make_handler(app: str):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass  # never log request lines (may carry tokens in URLs)

        def _deny(self):
            self.send_response(403)
            self.send_header("content-length", "0")
            self.send_header("x-appcap", "blocked")
            self.end_headers()

        def do_CONNECT(self):
            host = self.path.split(":")[0]
            d = decide(app, host, "/")
            if d["decision"] == "block":
                _log_tracker(app, host, d.get("category", "tracker"), "blocked")
                return self._deny()
            if d.get("category") in appcap_block.BLOCK_CATEGORIES:
                _log_tracker(app, host, d["category"], "allowed")
            # tunnel (bodies not inspected without the local CA — the on-device step)
            try:
                hp = self.path.split(":")
                up = socket.create_connection((hp[0], int(hp[1] if len(hp) > 1 else 443)), timeout=20)
            except OSError:
                return self._deny()
            self.send_response(200, "Connection Established")
            self.end_headers()
            self._pump(self.connection, up)

        def _pump(self, a, b):
            import select
            a.setblocking(False)
            b.setblocking(False)
            socks = [a, b]
            try:
                while True:
                    r, _, x = select.select(socks, [], socks, 30)
                    if x or not r:
                        break
                    for s in r:
                        data = s.recv(65536)
                        if not data:
                            return
                        (b if s is a else a).sendall(data)
            except OSError:
                pass
            finally:
                for s in (a, b):
                    try:
                        s.close()
                    except OSError:
                        pass

        def _proxy(self, method):
            url = self.path  # absolute-form in a forward proxy
            parts = urlsplit(url)
            host, path = parts.hostname or "", (parts.path + ("?" + parts.query if parts.query else "")) or "/"
            d = decide(app, host, path)
            if d["decision"] == "block":
                _log_tracker(app, host, d.get("category", "tracker"), "blocked")
                return self._deny()
            if d.get("category") in appcap_block.BLOCK_CATEGORIES:
                _log_tracker(app, host, d["category"], "allowed")
            length = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(length) if length else None
            fwd = {k: v for k, v in self.headers.items() if k.lower() not in ("proxy-connection", "connection")}
            req = urllib.request.Request(url, data=body, headers=fwd, method=method)
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    rbody = r.read()
                    status, mime = r.status, r.headers.get("content-type", "")
            except Exception:
                return self._deny()
            if d.get("category") == "functional":
                _record(app, _har_entry(method, url, fwd, status, rbody, mime))
            self.send_response(status)
            self.send_header("content-length", str(len(rbody)))
            self.send_header("x-appcap", d["decision"])
            self.end_headers()
            self.wfile.write(rbody)

        def do_GET(self):
            self._proxy("GET")

        def do_POST(self):
            self._proxy("POST")

        def do_PUT(self):
            self._proxy("PUT")

    return H


def main() -> int:
    ap = argparse.ArgumentParser(description="per-app capture + tracker-blocking proxy")
    ap.add_argument("--app", required=True, help="the ONE enabled app this session captures")
    ap.add_argument("--port", type=int, default=0, help="loopback port (0 = pick one)")
    ap.add_argument("--once", action="store_true", help="serve a single request then exit (for tests)")
    a = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(a.app))
    print(f"appcap_proxy for app '{a.app}' on 127.0.0.1:{srv.server_address[1]}", flush=True)
    if a.once:
        srv.handle_request()
    else:
        srv.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
