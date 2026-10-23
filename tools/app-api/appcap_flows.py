#!/usr/bin/env python3
"""appcap_flows.py - rewrite rules and recorded flows (HAR) for the App API app; served by appcap_serve.py.

Rules: <state>/rules.json = {"rules": [{id, enabled, app?, host, path?, action: "block"|"rewrite",
  header?: {name, value}, body?: {find, replace}}]}. Written here, APPLIED by the capture proxy (tools/app-api's
  capture side) - nothing here intercepts traffic. host is a glob ("*.doubleclick.net"), path a glob ("/v1/*").

Recordings: <state>/recordings/*.har - what the capture proxy records (HAR is the interchange, har2openapi.py reads
  the same files). A HAR holds live tokens, so every value that looks secret (a header, query parameter or JSON field
  whose name matches SECRET) leaves this module as HIDDEN and nothing else: an edit that leaves a hidden value alone
  keeps the recorded one, and a replay injects it server-side. Editing writes the HAR in place after keeping the
  original once (<name>.orig.har). Replay: dry run by default (the exact request, secrets hidden); a send only for
  GET/HEAD (the first slice's `read`), audited like every call (audit/replay.jsonl).
"""
from __future__ import annotations

import fnmatch
import glob
import json
import os
import re
import shutil
import time
import urllib.parse
import urllib.request

import appcap_run
import appcap_store

STATE = appcap_store.STATE
RULES = os.path.join(STATE, "rules.json")
RECS = os.path.join(STATE, "recordings")
HERE = os.path.dirname(os.path.realpath(__file__))
SECRET = re.compile(r"(authorization|cookie|token|secret|session|auth|password|passwd|api[-_]?key|signature|sig|key)", re.I)
HIDDEN = "<hidden>"
READ_METHODS = {"GET", "HEAD"}
MAX_BODY = 4000


# ---- rules -------------------------------------------------------------------------------------------------------

def _rule(r: dict, i: int) -> dict:
    act = r.get("action")
    if act not in ("block", "rewrite"):
        raise ValueError(f"rule {i + 1}: action is block or rewrite")
    host = str(r.get("host") or "").strip()
    if not host:
        raise ValueError(f"rule {i + 1}: a host (or a glob like *.example.com) is needed")
    out = {"id": str(r.get("id") or f"r{int(time.time() * 1000)}{i}"), "enabled": bool(r.get("enabled", True)),
           "app": str(r.get("app") or ""), "host": host, "path": str(r.get("path") or "*"), "action": act}
    if act == "rewrite":
        hd, bd = r.get("header") or {}, r.get("body") or {}
        if hd.get("name"):
            out["header"] = {"name": str(hd["name"]), "value": str(hd.get("value", ""))}
        if bd.get("find"):
            out["body"] = {"find": str(bd["find"]), "replace": str(bd.get("replace", ""))}
        if "header" not in out and "body" not in out:
            raise ValueError(f"rule {i + 1}: a rewrite sets a header or replaces text in the body")
    return out


def get_rules(_q, _b):
    try:
        with open(RULES, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"rules": []}


def set_rules(_q, b):
    rules = [_rule(r, i) for i, r in enumerate(b.get("rules") or [])]
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    tmp = RULES + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"rules": rules}, f, indent=2)
    os.replace(tmp, RULES)
    return {"rules": rules}


def rule_for(host: str, path: str, rules: list) -> dict | None:
    """The first enabled rule matching host + path (what the proxy applies; also used to preview a replay)."""
    for r in rules:
        if r.get("enabled") and fnmatch.fnmatch(host, r["host"]) and fnmatch.fnmatch(path or "/", r.get("path") or "*"):
            return r
    return None


# ---- recordings --------------------------------------------------------------------------------------------------

def seed():
    """The committed public sample (Open-Meteo: no account, no token) once, so replay has something safe to try."""
    os.makedirs(RECS, mode=0o700, exist_ok=True)
    src = os.path.join(HERE, "sample", "open-meteo.har")
    dst = os.path.join(RECS, "open-meteo-sample.har")
    if os.path.exists(src) and not os.path.exists(dst) and not os.path.exists(dst + ".removed"):
        shutil.copyfile(src, dst)


def _path(name: str) -> str:
    p = os.path.join(RECS, os.path.basename(name))
    if not p.endswith(".har") or p.endswith(".orig.har") or not os.path.exists(p):
        raise LookupError(f"no recording '{name}'")
    return p


def _load(p: str) -> dict:
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def recordings(_q, _b):
    out = []
    for p in sorted(glob.glob(os.path.join(RECS, "*.har")), key=os.path.getmtime, reverse=True):
        if p.endswith(".orig.har"):
            continue
        try:
            n = len(_load(p)["log"]["entries"])
        except (OSError, ValueError, KeyError):
            n = -1
        out.append({"name": os.path.basename(p), "flows": n, "edited": os.path.exists(p[:-4] + ".orig.har"),
                    "time": time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(p)))})
    return {"recordings": out}


def _hide_json(v):
    if isinstance(v, dict):
        return {k: (HIDDEN if SECRET.search(k) else _hide_json(x)) for k, x in v.items()}
    if isinstance(v, list):
        return [_hide_json(x) for x in v]
    return v


def _hide_body(text: str) -> str:
    try:
        return json.dumps(_hide_json(json.loads(text)))[:MAX_BODY]
    except ValueError:
        pass
    if "=" in text and "&" in text or "=" in text and " " not in text:  # a form body
        return _hide_url("?" + text)[1:][:MAX_BODY]
    return HIDDEN if SECRET.search(text) else text[:MAX_BODY]


def _hide_url(url: str) -> str:
    u = urllib.parse.urlsplit(url)
    q = [(k, HIDDEN if SECRET.search(k) else v) for k, v in urllib.parse.parse_qsl(u.query, keep_blank_values=True)]
    return urllib.parse.urlunsplit(u._replace(query=urllib.parse.urlencode(q, safe="<>")))


def _flow(i: int, e: dict) -> dict:
    rq, rs = e.get("request") or {}, e.get("response") or {}
    body = (rq.get("postData") or {}).get("text")
    return {"i": i, "method": rq.get("method", "GET"), "url": _hide_url(rq.get("url", "")),
            "status": rs.get("status"),
            "headers": [{"name": h["name"], "value": HIDDEN if SECRET.search(h["name"]) else h.get("value", "")}
                        for h in rq.get("headers") or []],
            "body": _hide_body(body) if body else ""}


def recording(q, _b):
    log = _load(_path(q["name"]))["log"]
    return {"name": os.path.basename(_path(q["name"])), "flows": [_flow(i, e) for i, e in enumerate(log["entries"])]}


def _merge_url(old: str, new: str) -> str:
    """The edited URL with every hidden query value put back from the recorded one."""
    rec = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(old).query, keep_blank_values=True))
    u = urllib.parse.urlsplit(new)
    q = [(k, rec.get(k, "") if v == HIDDEN else v) for k, v in urllib.parse.parse_qsl(u.query, keep_blank_values=True)]
    return urllib.parse.urlunsplit(u._replace(query=urllib.parse.urlencode(q)))


def edit(_q, b):
    p = _path(b["name"])
    har = _load(p)
    rq = har["log"]["entries"][int(b["i"])]["request"]
    old = {h["name"].lower(): h.get("value", "") for h in rq.get("headers") or []}
    if b.get("method"):
        rq["method"] = str(b["method"]).upper()
    if b.get("url"):
        rq["url"] = _merge_url(rq.get("url", ""), str(b["url"]))
    if isinstance(b.get("headers"), list):
        rq["headers"] = [{"name": h["name"], "value": old.get(h["name"].lower(), "") if h.get("value") == HIDDEN else str(h.get("value", ""))}
                         for h in b["headers"] if h.get("name")]
    if "body" in b and b["body"] != HIDDEN and HIDDEN not in str(b["body"]):
        rq.setdefault("postData", {"mimeType": "application/json"})["text"] = str(b["body"])
    orig = p[:-4] + ".orig.har"
    if not os.path.exists(orig):
        shutil.copyfile(p, orig)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(har, f, indent=1)
    os.replace(tmp, p)
    return _flow(int(b["i"]), har["log"]["entries"][int(b["i"])])


def replay(_q, b):
    p = _path(b["name"])
    e = _load(p)["log"]["entries"][int(b["i"])]
    rq = e["request"]
    method, url = rq.get("method", "GET").upper(), rq.get("url", "")
    u = urllib.parse.urlsplit(url)
    rule = rule_for(u.hostname or "", u.path, get_rules({}, {})["rules"])
    shown = _flow(int(b["i"]), e)
    out = {"request": f"{method} {shown['url']}", "headers": shown["headers"], "body": shown["body"],
           "rule": rule and f"{rule['action']} ({rule['host']}{rule['path']})", "dry_run": True}
    send = bool(b.get("send"))
    if send and method not in READ_METHODS:
        out["refused"] = "only GET/HEAD replays are sent for now; this one stays a dry run"
        send = False
    if send and rule and rule["action"] == "block":
        out["refused"] = "a block rule matches this request"
        send = False
    if send:
        out.update(_send(method, url, rq))
    appcap_run._audit("replay", {"consumer": "app", "app": "replay", "action": f"{b['name']}#{b['i']}",
                                 "safety": "read" if method in READ_METHODS else "reversible-write",
                                 "sent": not out["dry_run"], "status": out.get("status"), "refused": out.get("refused")})
    return out


def _send(method: str, url: str, rq: dict) -> dict:
    hop = {"host", "content-length", "connection", "accept-encoding"}
    headers = {h["name"]: h.get("value", "") for h in rq.get("headers") or [] if h["name"].lower() not in hop
               and not h["name"].startswith(":")}
    t0 = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers, method=method), timeout=20) as r:
            status, text = r.status, r.read(MAX_BODY).decode("utf-8", "replace")
    except Exception as e:  # a failed replay is a result, not a crash
        status, text = "error", str(e)[:200]
    return {"dry_run": False, "status": status, "duration_ms": int((time.time() - t0) * 1000),
            "response_sample": _hide_body(text)}


ROUTES = {("GET", "/rules"): get_rules, ("POST", "/rules"): set_rules, ("GET", "/recordings"): recordings,
          ("GET", "/recording"): recording, ("POST", "/recording/edit"): edit, ("POST", "/recording/replay"): replay}
