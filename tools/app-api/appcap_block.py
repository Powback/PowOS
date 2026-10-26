#!/usr/bin/env python3
"""appcap_block.py - tracker / unwanted-traffic identification and blocking.

Runs LOCALLY on PowOS beside the capture proxy (offline/LAN). It classifies each
request the proxy sees (from enabled apps, and optionally all apps) as a TRACKER
/ analytics call vs a FUNCTIONAL call, using known lists (EasyPrivacy-style host
rules + Exodus-style tracker signatures) plus whatever was learned per app, and
decides block vs allow.

Policy (per the brief):
  - trackers/analytics are BLOCKED by default;
  - functional calls are ALLOWED;
  - if blocking breaks an app, a per-app ALLOW switch force-allows a host;
  - it COMPLEMENTS Pi-hole (DNS-level) with request-level, per-app decisions —
    it does not replace it.

It only observes + blocks (no account, spend, or ToS risk). It produces a per-app
report (which trackers, how many calls, how many bytes) that the App API app
shows. Blocklists are seeded here with well-known trackers and are meant to be
refreshed on-device from EasyPrivacy + the Exodus tracker database (the updater
is a scheduled unit; this file carries a small starter set so it works offline).

Stdlib only. Never prints a token/secret.

CLI:
  appcap_block.py classify <host> [path]
  appcap_block.py report --from-json flows.json [--app NAME]   # flows: [{host,app,bytes}]
  appcap_block.py allow  --app NAME <host>      # per-app override: force-allow
  appcap_block.py unallow --app NAME <host>
  appcap_block.py lists                         # show the loaded signature set
"""
from __future__ import annotations

import json
import os
import re
import sys

import appcap_store  # reuse the state dir only

STATE = appcap_store.STATE
OVERRIDES = os.path.join(STATE, "block-overrides.json")

# Seed signature set. Each entry: (category, host-substring-or-regex). Category
# 'tracker' and 'analytics' block by default; 'functional' never blocks. Real
# deployments refresh from EasyPrivacy + Exodus; this is the offline starter.
SIGNATURES = [
    ("tracker", "doubleclick.net"),
    ("tracker", "googlesyndication.com"),
    ("tracker", "google-analytics.com"),
    ("tracker", "googletagmanager.com"),
    ("tracker", "app-measurement.com"),      # Firebase Analytics
    ("tracker", "crashlytics.com"),
    ("tracker", "firebase-settings.crashlytics.com"),
    ("tracker", "graph.facebook.com/.*?/activities"),  # FB SDK app events
    ("tracker", "facebook.com/tr"),
    ("tracker", "appsflyer.com"),
    ("tracker", "adjust.com"),
    ("tracker", "app.adjust.com"),
    ("analytics", "branch.io"),
    ("analytics", "amplitude.com"),
    ("analytics", "mixpanel.com"),
    ("analytics", "segment.io"),
    ("analytics", "api.segment.io"),
    ("analytics", "sentry.io"),
    ("analytics", "bugsnag.com"),
    ("analytics", "nr-data.net"),            # New Relic
    ("analytics", "braze.com"),
    ("analytics", "sdk.iterable.com"),
    ("tracker", "ads."),
    ("tracker", "/analytics"),
    ("tracker", "/telemetry"),
    ("tracker", "/metrics/collect"),
]
_COMPILED = [(cat, re.compile(pat, re.I)) for cat, pat in SIGNATURES]
BLOCK_CATEGORIES = {"tracker", "analytics"}


def _overrides() -> dict:
    try:
        return json.load(open(OVERRIDES))
    except Exception:
        return {}


def _save_overrides(d: dict):
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    json.dump(d, open(OVERRIDES, "w"), indent=2)


def classify(host: str, path: str = "") -> tuple[str, str | None]:
    """Return (category, matched_pattern). category in
    functional|analytics|tracker."""
    target = f"{host}{path}"
    for cat, rx in _COMPILED:
        if rx.search(target):
            return cat, rx.pattern
    return "functional", None


def decide(host: str, path: str = "", app: str | None = None) -> dict:
    """Block/allow decision honoring the per-app allow override."""
    cat, rule = classify(host, path)
    forced = host in (_overrides().get(app or "", {}).get("allow", []))
    blocked = (cat in BLOCK_CATEGORIES) and not forced
    return {"host": host, "category": cat, "rule": rule,
            "blocked": blocked, "forced_allow": forced}


def report(flows: list[dict], app: str | None = None) -> dict:
    """flows: [{host, app, bytes}]. Per-app rollup of trackers vs functional."""
    out: dict = {}
    for f in flows:
        a = f.get("app", "?")
        if app and a != app:
            continue
        d = decide(f.get("host", ""), f.get("path", ""), a)
        slot = out.setdefault(a, {"blocked_calls": 0, "blocked_bytes": 0,
                                  "allowed_calls": 0, "allowed_bytes": 0, "by_host": {}})
        b = int(f.get("bytes", 0))
        key = "blocked" if d["blocked"] else "allowed"
        slot[f"{key}_calls"] += 1
        slot[f"{key}_bytes"] += b
        h = slot["by_host"].setdefault(d["host"], {"category": d["category"], "calls": 0, "bytes": 0, "blocked": d["blocked"]})
        h["calls"] += 1
        h["bytes"] += b
    return out


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: appcap_block.py {classify|report|allow|unallow|lists} …", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "classify":
        host = rest[0]
        path = rest[1] if len(rest) > 1 else ""
        print(json.dumps(decide(host, path)))
        return 0
    if cmd == "lists":
        for cat, pat in SIGNATURES:
            print(f"{cat:10} {pat}")
        print(f"\n{len(SIGNATURES)} seed signatures; block categories: {sorted(BLOCK_CATEGORIES)}", file=sys.stderr)
        return 0
    if cmd in ("allow", "unallow"):
        app = None
        for i, a in enumerate(rest):
            if a == "--app":
                app = rest[i + 1]
        hosts = [a for a in rest if not a.startswith("--") and a != app]
        if not app or not hosts:
            print("need --app NAME and a host", file=sys.stderr)
            return 2
        ov = _overrides()
        lst = ov.setdefault(app, {}).setdefault("allow", [])
        for h in hosts:
            if cmd == "allow" and h not in lst:
                lst.append(h)
            if cmd == "unallow" and h in lst:
                lst.remove(h)
        _save_overrides(ov)
        print(f"{cmd}: {app} allow-list now {lst}", file=sys.stderr)
        return 0
    if cmd == "report":
        src = None
        app = None
        for i, a in enumerate(rest):
            if a == "--from-json":
                src = rest[i + 1]
            if a == "--app":
                app = rest[i + 1]
        if not src:
            print("report needs --from-json FILE", file=sys.stderr)
            return 2
        flows = json.load(open(src))
        print(json.dumps(report(flows, app), indent=2))
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
