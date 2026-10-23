#!/usr/bin/env python3
"""har2openapi.py - turn a captured HAR into a typed OpenAPI 3.1 spec.

Part of the PowOS "app -> API" pipeline (docs/APP-API-CAPTURE.md). This is the
capture -> spec step: it reads a HAR file (the universal export format that
mitmproxy, HTTP Toolkit, reqable and Chrome DevTools all produce) and infers an
OpenAPI document from the observed requests and responses.

What it does
  - groups requests by host + method + templated path
  - templates volatile path segments (numeric ids, UUIDs, long hashes) -> {id}
  - infers a JSON Schema for request and response bodies by merging every
    observed sample (a field absent in any sample is marked not-required)
  - records query parameters and their example values
  - detects the auth scheme (Bearer / cookie / api-key header) and emits it as a
    securityScheme WITHOUT ever recording the secret value
  - classifies each operation read vs write (GET/HEAD/OPTIONS = read; everything
    else is a mutation) and tags mutations x-powos-mutation: true so the tool
    generator downstream can gate them behind user confirmation

Secrets: Authorization, Cookie, Set-Cookie, x-api-key and any header/param whose
name matches the secret pattern are NEVER copied into the output. Their presence
is noted (the security scheme), their value is dropped. Response bodies are
schema-inferred, not embedded, so tokens in bodies do not leak into the spec
either (a token field becomes {"type": "string"} with no example).

Usage
  har2openapi.py capture.har -o openapi.json [--title NAME] [--host HOST]
  har2openapi.py capture.har --host api.example.com        # one host only
  har2openapi.py capture.har --stats                       # summary, no write

Stdlib only. No network. Never prints a captured secret.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from typing import Any
from urllib.parse import urlsplit, parse_qsl

# Header / param names whose VALUES are secrets and must never be written out.
SECRET_NAMES = re.compile(
    r"(authorization|cookie|set-cookie|x-api-key|api[-_]?key|token|secret|"
    r"session|auth|bearer|x-csrf|x-xsrf|signature|x-sig|password|passwd)",
    re.I,
)
# Path segments that are volatile ids and should be templated to {id}.
NUMERIC = re.compile(r"^\d+$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
LONGHEX = re.compile(r"^[0-9a-f]{16,}$", re.I)
SLUG_WITH_ID = re.compile(r"^.*[-_][0-9a-f]{8,}$", re.I)

READ_METHODS = {"GET", "HEAD", "OPTIONS"}


def template_path(path: str) -> tuple[str, list[str]]:
    """Return (templated_path, [param_names]) with volatile segments -> {id}."""
    out, params, n = [], [], 0
    for seg in path.split("/"):
        if seg and (NUMERIC.match(seg) or UUID.match(seg) or LONGHEX.match(seg) or SLUG_WITH_ID.match(seg)):
            n += 1
            name = "id" if n == 1 else f"id{n}"
            out.append("{" + name + "}")
            params.append(name)
        else:
            out.append(seg)
    return "/".join(out), params


def infer_schema(value: Any) -> dict:
    """A JSON Schema for one value. No example values are attached (avoids leaking
    secret-bearing response fields into the spec)."""
    if value is None:
        return {"type": "null"}
    if isinstance(value, bool):
        return {"type": "boolean"}
    if isinstance(value, int):
        return {"type": "integer"}
    if isinstance(value, float):
        return {"type": "number"}
    if isinstance(value, str):
        return {"type": "string"}
    if isinstance(value, list):
        if not value:
            return {"type": "array", "items": {}}
        merged: dict = {}
        for item in value[:50]:
            merged = merge_schema(merged, infer_schema(item))
        return {"type": "array", "items": merged}
    if isinstance(value, dict):
        props = {}
        for k, v in value.items():
            props[k] = infer_schema(v)
        return {"type": "object", "properties": props, "required": sorted(value.keys())}
    return {}


def merge_schema(a: dict, b: dict) -> dict:
    """Merge two inferred schemas from different samples. A property missing in
    either sample drops out of `required` (so it becomes optional)."""
    if not a:
        return b
    if not b:
        return a
    ta, tb = a.get("type"), b.get("type")
    if ta != tb:
        # Union of scalar types, or null + T -> nullable T.
        types = {t for t in (ta, tb) if t}
        if types == {"null"} or len(types) == 0:
            return a
        return {"type": sorted(types), "properties": {**a.get("properties", {}), **b.get("properties", {})}}
    if ta == "object":
        pa, pb = a.get("properties", {}), b.get("properties", {})
        props = {}
        for k in set(pa) | set(pb):
            if k in pa and k in pb:
                props[k] = merge_schema(pa[k], pb[k])
            else:
                props[k] = pa.get(k) or pb.get(k)
        req = sorted(set(a.get("required", [])) & set(b.get("required", [])))
        return {"type": "object", "properties": props, "required": req}
    if ta == "array":
        return {"type": "array", "items": merge_schema(a.get("items", {}), b.get("items", {}))}
    return a


def parse_body(text: str | None, mime: str | None) -> Any:
    if not text:
        return None
    if mime and "json" not in mime.lower():
        return None
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return None


def detect_auth(headers: list[dict]) -> str | None:
    """Return a security-scheme name for the auth present, value never read."""
    for h in headers:
        name = (h.get("name") or "").lower()
        if name == "authorization":
            val = (h.get("value") or "")
            return "bearerAuth" if val.lower().startswith("bearer") else "httpAuth"
        if name == "cookie":
            return "cookieAuth"
        if name == "x-api-key" or (name.endswith("-key") and "api" in name):
            return "apiKeyAuth"
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="HAR -> OpenAPI 3.1 (secret-safe).")
    ap.add_argument("har")
    ap.add_argument("-o", "--out")
    ap.add_argument("--title", default="Captured API")
    ap.add_argument("--host", help="restrict to one host")
    ap.add_argument("--stats", action="store_true", help="print a summary, write nothing")
    args = ap.parse_args()

    with open(args.har, encoding="utf-8") as f:
        har = json.load(f)
    entries = har.get("log", {}).get("entries", [])

    # op key -> aggregation
    ops: dict[tuple, dict] = {}
    hosts: set[str] = set()
    security: dict[str, dict] = {}

    for e in entries:
        req, resp = e.get("request", {}), e.get("response", {})
        url = req.get("url", "")
        if not url:
            continue
        u = urlsplit(url)
        host = u.netloc
        if args.host and host != args.host:
            continue
        hosts.add(host)
        method = (req.get("method") or "GET").upper()
        tpath, path_params = template_path(u.path)

        scheme = detect_auth(req.get("headers", []))
        if scheme:
            if scheme == "bearerAuth":
                security[scheme] = {"type": "http", "scheme": "bearer"}
            elif scheme == "httpAuth":
                security[scheme] = {"type": "http", "scheme": "basic"}
            elif scheme == "cookieAuth":
                security[scheme] = {"type": "apiKey", "in": "cookie", "name": "session"}
            else:
                security[scheme] = {"type": "apiKey", "in": "header", "name": "x-api-key"}

        key = (host, tpath, method)
        op = ops.setdefault(key, {
            "host": host, "path": tpath, "method": method,
            "path_params": path_params, "query": {}, "req_schema": {},
            "responses": defaultdict(dict), "count": 0, "security": scheme,
        })
        op["count"] += 1

        for q in req.get("queryString", []) or parse_qsl(u.query):
            name = q["name"] if isinstance(q, dict) else q[0]
            val = q.get("value") if isinstance(q, dict) else q[1]
            if SECRET_NAMES.search(name):
                op["query"][name] = "<redacted>"
            else:
                op["query"].setdefault(name, val)

        body = parse_body((req.get("postData") or {}).get("text"), (req.get("postData") or {}).get("mimeType"))
        if body is not None:
            op["req_schema"] = merge_schema(op["req_schema"], infer_schema(body))

        status = str(resp.get("status") or "default")
        rbody = parse_body((resp.get("content") or {}).get("text"), (resp.get("content") or {}).get("mimeType"))
        if rbody is not None:
            op["responses"][status] = merge_schema(op["responses"][status], infer_schema(rbody))

    if args.stats:
        print(f"hosts: {', '.join(sorted(hosts)) or '(none)'}")
        print(f"operations: {len(ops)}  entries: {len(entries)}")
        for (host, path, method), op in sorted(ops.items()):
            kind = "read " if method in READ_METHODS else "WRITE"
            print(f"  [{kind}] {method:6} {host}{path}  x{op['count']}")
        if security:
            print(f"auth: {', '.join(sorted(security))}")
        return 0

    # Build OpenAPI 3.1
    paths: dict[str, dict] = {}
    for (host, path, method), op in sorted(ops.items()):
        item = paths.setdefault(path, {})
        operation: dict = {
            "operationId": f"{method.lower()}_{re.sub(r'[^a-zA-Z0-9]+', '_', path).strip('_') or 'root'}",
            "x-powos-host": host,
            "x-powos-samples": op["count"],
            "responses": {},
        }
        if method not in READ_METHODS:
            operation["x-powos-mutation"] = True  # downstream: require user confirm
        params = []
        for pname in op["path_params"]:
            params.append({"name": pname, "in": "path", "required": True, "schema": {"type": "string"}})
        for qname, qex in op["query"].items():
            p = {"name": qname, "in": "query", "schema": {"type": "string"}}
            if qex and qex != "<redacted>":
                p["example"] = qex
            params.append(p)
        if params:
            operation["parameters"] = params
        if op["req_schema"]:
            operation["requestBody"] = {"content": {"application/json": {"schema": op["req_schema"]}}}
        for status, sch in op["responses"].items():
            operation["responses"][status] = {
                "description": "captured",
                "content": {"application/json": {"schema": sch}} if sch else {},
            }
        if not operation["responses"]:
            operation["responses"]["default"] = {"description": "captured"}
        if op["security"]:
            operation["security"] = [{op["security"]: []}]
        item[method.lower()] = operation

    servers = [{"url": f"https://{h}"} for h in sorted(hosts)]
    spec = {
        "openapi": "3.1.0",
        "info": {"title": args.title, "version": "0.0.0",
                 "description": "Inferred from captured traffic by har2openapi.py. "
                                "Operations with x-powos-mutation require explicit user confirmation."},
        "servers": servers,
        "paths": paths,
    }
    if security:
        spec["components"] = {"securitySchemes": security}

    text = json.dumps(spec, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"wrote {args.out}: {len(paths)} path(s), {len(ops)} operation(s), "
              f"{len(security)} security scheme(s)", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
