#!/usr/bin/env python3
"""appcap_files.py - which files an app reads and writes, and overrides for them; served by appcap_serve.py.

The contract (the recording side is a later step: tracing another app's file access needs the root/Frida tooling the
user hasn't said yes to yet - until it writes, the App API app shows an empty state):
  <state>/files/<app>.jsonl         one line per access: {"ts", "app", "path", "op": "open"|"read"|"write", "bytes"?}
  <state>/files/overrides.json      {"apps": {"<app>": {"<path>": {"enabled": true, "file": "<sha>"}}}}
  <state>/files/override/<app>/<sha> the content served instead of <path> (written here, applied by that tracer)
Nothing here touches another app's files: it keeps the record and the replacement content, that's all.
"""
from __future__ import annotations

import glob
import hashlib
import json
import os

import appcap_store

FILES = os.path.join(appcap_store.STATE, "files")
POLICY = os.path.join(FILES, "overrides.json")
MAX = 256 << 10


def _policy() -> dict:
    try:
        with open(POLICY, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"apps": {}}


def _save(pol: dict):
    os.makedirs(FILES, mode=0o700, exist_ok=True)
    with open(POLICY + ".tmp", "w", encoding="utf-8") as f:
        json.dump(pol, f, indent=2)
    os.replace(POLICY + ".tmp", POLICY)


def _accesses(p: str) -> dict:
    seen = {}
    try:
        with open(p, encoding="utf-8") as f:
            lines = f.readlines()[-5000:]
    except OSError:
        return seen
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        s = seen.setdefault(r.get("path", "?"), {"path": r.get("path", "?"), "reads": 0, "writes": 0, "last": ""})
        s["writes" if r.get("op") == "write" else "reads"] += 1
        s["last"] = max(s["last"], r.get("ts", ""))
    return seen


def files(_q, _b):
    pol = _policy().get("apps", {})
    apps = {os.path.basename(p)[:-6]: _accesses(p) for p in glob.glob(os.path.join(FILES, "*.jsonl"))}
    for app, ov in pol.items():  # an override for a file not seen (yet) still shows
        for path in ov:
            apps.setdefault(app, {}).setdefault(path, {"path": path, "reads": 0, "writes": 0, "last": ""})
    out = [{"app": a, "files": [{**f, "override": bool((pol.get(a) or {}).get(f["path"], {}).get("enabled"))}
                                for f in sorted(fs.values(), key=lambda f: f["last"], reverse=True)]}
           for a, fs in sorted(apps.items())]
    return {"apps": out}


def get_override(q, _b):
    ov = (_policy().get("apps", {}).get(q["app"]) or {}).get(q["path"])
    if not ov:
        return {"content": None}
    with open(os.path.join(FILES, "override", os.path.basename(q["app"]), ov["file"]), encoding="utf-8", errors="replace") as f:
        return {"content": f.read(MAX), "enabled": ov.get("enabled", True)}


def set_override(_q, b):
    """{app, path, content}: content replaces the file for that app; content null removes the override."""
    app, path = os.path.basename(str(b["app"])), str(b["path"])
    pol = _policy()
    mine = pol.setdefault("apps", {}).setdefault(app, {})
    if b.get("content") is None:
        mine.pop(path, None)
    else:
        data = str(b["content"]).encode()[:MAX]
        sha = hashlib.sha256(data).hexdigest()[:32]
        d = os.path.join(FILES, "override", app)
        os.makedirs(d, mode=0o700, exist_ok=True)
        with open(os.path.join(d, sha), "wb") as f:
            f.write(data)
        mine[path] = {"enabled": bool(b.get("enabled", True)), "file": sha}
    _save(pol)
    return files({}, {})


ROUTES = {("GET", "/files"): files, ("GET", "/files/override"): get_override, ("POST", "/files/override"): set_override}
