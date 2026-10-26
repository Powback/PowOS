#!/usr/bin/env python3
"""openapi2appcap.py - turn a captured OpenAPI spec (har2openapi.py output) into
a DRAFT App Capability Spec.

The draft is deliberately conservative, per the safety model:
  - every action is origin:"captured";
  - GET/HEAD/OPTIONS -> safety "read", ENABLED (reads are immediately usable);
  - every mutating method -> its inferred safety but ENABLED:false (NOT in the
    allowlist) and promoted:false, so it cannot be called until the user reviews
    and promotes it. 'spend' is guessed from the path (checkout/pay/order/
    purchase/book/delete/send/message) and gets confirm:true + a template;
    everything else mutating is 'reversible-write' with an undo placeholder.
  - the auth scheme becomes one token HANDLE (store:<app>:session) — the VALUE is
    never read from the capture or written here; the store holds the app's own
    session, injected at call time.

So right after a capture you get all the app's reads for free, and its writes are
present but switched off until you promote them. Output validates under
appcap_validate.py.

Usage:
  openapi2appcap.py captured.openapi.json --app ubereats [-o ubereats.appcap.json]
Programmatic: convert(openapi_dict, app) -> the draft spec (appcap_add.py imports it).
"""
from __future__ import annotations

import argparse
import json
import re
import sys

READ = {"get", "head", "options"}
SPEND_PAT = re.compile(r"(checkout|payment|pay|order|purchase|book|delete|send|message|tip|charge)", re.I)


def _tokens(oa: dict, app: str) -> dict:
    sec = oa.get("components", {}).get("securitySchemes", {})
    if not sec:
        return {}
    s = next(iter(sec.values()))
    header, ttype = "authorization", "bearer"
    if s.get("type") == "apiKey":
        header, ttype = s.get("name", "x-api-key"), "api-key"
    return {"session": {"store": f"store:{app}:session", "type": ttype, "header": header}}


def _action(path: str, method: str, op: dict, authed: bool) -> tuple[str, dict]:
    is_read = method in READ
    aid = op.get("operationId") or (method + re.sub(r"[^a-zA-Z0-9]+", "_", path)).strip("_")
    aid = re.sub(r"_+", "_", aid).strip("_")[:48] or "root"
    spend = (not is_read) and bool(SPEND_PAT.search(path))
    safety = "read" if is_read else ("spend" if spend else "reversible-write")
    ep = {"method": method.upper(), "path": path}
    if op.get("security") or authed:
        ep["auth"] = "session"
    params = {p["name"]: {"type": "string"} for p in op.get("parameters", []) if p.get("in") in ("path", "query")}
    action = {
        "summary": op.get("summary") or f"{method.upper()} {path}",
        "safety": safety,
        "origin": "captured",
        "promoted": False,
        "enabled": is_read,                 # reads on; writes disabled until promoted
        "widget": is_read,
        "inputs": {"type": "object", "properties": params},
        "endpoint": ep,
    }
    if safety == "reversible-write":
        action["undo"] = "TODO-set-undo-action"
    if safety == "spend":
        action["confirm"] = True
        action["confirm_template"] = "Confirm: " + (op.get("summary") or aid) + " ? (review what & how much)"
    return aid, action


def convert(oa: dict, app: str) -> dict:
    """An OpenAPI document as a draft appcap (a dict; the caller writes it). Never reads a credential's value."""
    servers = oa.get("servers") or [{"url": ""}]
    base_url = servers[0].get("url", "")
    kind = "lan" if re.search(r"\b192\.168\.|\.pow\b|localhost", base_url) else "internet"
    tokens = _tokens(oa, app)
    actions = {}
    for path, item in (oa.get("paths") or {}).items():
        for method, op in (item or {}).items():
            if method in {"get", "post", "put", "patch", "delete", "head", "options"} and isinstance(op, dict):
                aid, action = _action(path, method, op, bool(tokens))
                actions[aid] = action
    return {
        "spec": "powos.appcap/v1",
        "app": app,
        "name": oa.get("info", {}).get("title", app),
        "description": "DRAFT from capture. Reads enabled; writes disabled until promoted.",
        "enabled": False,                           # whole app off until the user enables it
        "base": {"kind": kind, "url": base_url, "tls": "pinned" if kind == "lan" else "standard"},
        "auth": {"tokens": tokens},
        "defaults": {"rate_limit": {"per_minute": 30}, "cache_ttl_s": 60},
        "actions": actions,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="captured OpenAPI -> draft appcap")
    ap.add_argument("openapi")
    ap.add_argument("--app", required=True)
    ap.add_argument("-o", "--out")
    args = ap.parse_args()

    spec = convert(json.load(open(args.openapi, encoding="utf-8")), args.app)
    actions = spec["actions"]
    text = json.dumps(spec, indent=2)
    if args.out:
        open(args.out, "w", encoding="utf-8").write(text + "\n")
        reads = sum(1 for a in actions.values() if a["safety"] == "read")
        print(f"wrote {args.out}: {len(actions)} action(s) — {reads} read (enabled), "
              f"{len(actions)-reads} write (disabled until promoted)", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
