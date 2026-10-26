#!/usr/bin/env python3
"""appcap_add.py - App API's "+ add app": drafts, kept apart from your apps until you add one.

A draft is a capability spec in <state>/drafts/<app>.appcap.json - never in specs/, so no consumer (the AI, the CLI, a
widget) sees it. It is only ever previewed (appcap_run.py --draft: a dry run, nothing sent). "Add to my apps" moves it
into specs/ with the whole app off; from there it is a normal app, switched on action by action.

Every source goes through ONE normalize(), then appcap_validate, before a draft is written:
  - the whole app enabled:false; reads enabled; every write enabled:false, promoted:false;
  - origin "drafted" (a capture keeps "captured"): S3 holds a write until the user promotes it by switching it on;
  - spend gets confirm:true and a confirm_template; widgets and views only on reads;
  - auth only as the handles store:<app>:session / secret:<app> - a value never, wherever it was put (a token's
    store, a URL's user:password, a secret-named query or body value is replaced by a {placeholder}).

Sources:
  describe  PowOS AI wrote it from the app's docs (the App API app hands PowOS AI the prompt; the model never runs here)
  openapi   an OpenAPI document (openapi2appcap.convert)       appcap   a capability spec as-is
  capture   the app's recordings (appcap_draft.py)              powos    an installed PowOS app (manifest + its own DB)
  android   an Android app's exported deep links (the bridge's apps.links, sent by the App API app)

CLI (as the session user; never prints a token):
  appcap_add.py put --source describe|openapi|appcap FILE [--app ID]
  appcap_add.py import URL|FILE [--app ID]       an OpenAPI or appcap document (http/https only, no credentials)
  appcap_add.py powos ID                          a draft from the installed PowOS app ID
  appcap_add.py list | show APP | add APP | discard APP
Routes (appcap_serve.py): GET /drafts, GET /draft?app=, GET /installed, POST /draft/import|installed|add|discard.
Stdlib only.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import tempfile
import urllib.request
from urllib.parse import quote, urlsplit

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import appcap_store  # noqa: E402
import appcap_validate  # noqa: E402
import openapi2appcap  # noqa: E402

STATE = appcap_store.STATE
DRAFTS = os.path.join(STATE, "drafts")
SPECS = os.path.join(STATE, "specs")
SAMPLES = os.path.join(HERE, "sample")
POWOS_APPS = os.path.expanduser(os.environ.get("POWOS_APPS_DIR", "~/.local/share/powos/apps"))
STDB = os.environ.get("POWOS_STDB", "http://127.0.0.1:3410")
APP_ID = re.compile(r"^[a-z][a-z0-9-]{1,40}$")
SECRET = re.compile(r"(token|secret|session|auth|cookie|password|passwd|apikey|api_key|api-key|signature)", re.I)
PLACEHOLDER = re.compile(r"^\{[A-Za-z_][A-Za-z0-9_]*\}$")
SOURCES = ("describe", "openapi", "appcap", "capture", "powos", "android")
FETCH_MAX = 1 << 20
TOP = ("name", "description", "base", "defaults")
ACTION = ("summary", "safety", "widget", "confirm", "confirm_template", "undo", "refresh", "view", "rate_limit",
          "cache_ttl_s", "inputs", "output")
ENDPOINT = ("method", "path", "operationId", "auth", "argv", "body", "ui")
UI = ("deep_link", "route", "steps")
TOKEN_TYPES = ("api-key", "bearer", "cookie", "basic")


def slug(s: str, sep: str = "-") -> str:
    s = re.sub(r"[^a-z0-9]+", sep, str(s).lower()).strip(sep)
    s = re.sub(r"^[^a-z]+", "", s)
    return s[:41].strip(sep)


def draft_path(app: str) -> str:
    if not APP_ID.match(app or ""):
        raise ValueError(f"not an app id: {app!r}")
    return os.path.join(DRAFTS, f"{app}.appcap.json")


# ---- normalize: one for every source ----

def _scrub_url(u: str) -> str:
    """No credential in a URL: user:password@ dropped, a secret-named query value made a {placeholder}."""
    if not isinstance(u, str):
        return ""
    u = re.sub(r"^([a-z][a-z0-9+.-]*://)[^/@]*@", r"\1", u, flags=re.I)
    return re.sub(r"([?&])([^=&#]+)=([^&#]*)",
                  lambda m: m.group(0) if not SECRET.search(m.group(2)) or PLACEHOLDER.match(m.group(3))
                  else f"{m.group(1)}{m.group(2)}={{{slug(m.group(2), '_') or 'value'}}}", u)


def _scrub_body(b):
    if isinstance(b, dict):
        return {k: (f"{{{slug(k, '_') or 'value'}}}" if SECRET.search(k) and isinstance(v, str) and not PLACEHOLDER.match(v)
                    else _scrub_body(v)) for k, v in b.items()}
    if isinstance(b, list):
        return [_scrub_body(v) for v in b]
    return b


def _tokens(spec: dict, app: str) -> dict:
    """Handles only: a token's store is store:<app>:session or secret:<app>; anything else (a value) is dropped."""
    out = {}
    for tid, t in ((spec.get("auth") or {}).get("tokens") or {}).items():
        t = t if isinstance(t, dict) else {}
        store = t.get("store") if t.get("store") in (f"secret:{app}", f"store:{app}:session") else f"store:{app}:session"
        tok = {"store": store, "type": t.get("type") if t.get("type") in TOKEN_TYPES else "bearer"}
        for k in ("header", "query"):
            if isinstance(t.get(k), str):
                tok[k] = t[k]
        out[slug(tid, "_") or "session"] = tok
    return out


def _endpoint(ep: dict, tokens: dict) -> dict:
    out = {k: ep[k] for k in ENDPOINT if k in ep}
    if "path" in out:
        out["path"] = _scrub_url(out["path"])
    if "body" in out:
        out["body"] = _scrub_body(out["body"]) if isinstance(out["body"], (dict, str)) else {}
    if isinstance(out.get("ui"), dict):
        out["ui"] = {k: out["ui"][k] for k in UI if k in out["ui"]}
    if out.get("auth") not in tokens:
        out.pop("auth", None)
    return out


def _safety(a: dict, ep: dict) -> str:
    s = a.get("safety")
    if s is None:  # unsaid: what it does decides - a GET or a screen opened looks; anything else changes something
        return "read" if ep.get("ui") or ep.get("method", "GET") in ("GET", "HEAD") else "reversible-write"
    if s not in appcap_validate.SAFETY:
        raise ValueError(f"safety must be one of {sorted(appcap_validate.SAFETY)}, not {s!r}")
    return s


def _app_auth_handle(actions: dict, tokens: dict) -> str | None:
    """The app-level auth.handle normalize() sets: the one handle every action that needs auth resolves to
    (endpoint.auth -> tokens[...].store), or 'mixed' when they differ. None when no action needs auth - the
    detail page then shows no auth line, same as today."""
    handles = {tokens[a["endpoint"]["auth"]]["store"] for a in actions.values() if a["endpoint"].get("auth") in tokens}
    if not handles:
        return None
    return next(iter(handles)) if len(handles) == 1 else "mixed"


def _action(aid: str, a: dict, origin: str, tokens: dict, ids: set) -> dict:
    if not isinstance(a, dict):
        raise ValueError(f"action {aid!r} isn't an object")
    act = {k: a[k] for k in ACTION if k in a}
    act["endpoint"] = _endpoint(a.get("endpoint") or {}, tokens)
    act["safety"] = safety = _safety(a, act["endpoint"])
    act.setdefault("summary", aid.replace("_", " "))
    act.update(origin=origin, promoted=False, enabled=safety == "read")
    if safety != "read":
        act.pop("widget", None)
        act.pop("view", None)
    if safety == "spend":
        act["confirm"] = True
    if act.get("confirm") and not act.get("confirm_template"):
        act["confirm_template"] = f"{act['summary']}? (check what and how much first)"
    if act.get("undo") not in ids | {"inverse"}:
        act.pop("undo", None)
    return act


def normalize(spec: dict, source: str, app: str | None = None) -> dict:
    """[spec] from [source] as a draft: whole app off, reads on, writes off and unpromoted, spend confirmed, auth only
    as handles. Raises ValueError when it can't be one."""
    if source not in SOURCES:
        raise ValueError(f"source: one of {', '.join(SOURCES)}")
    if not isinstance(spec, dict) or not isinstance(spec.get("actions"), dict) or not spec["actions"]:
        raise ValueError("a draft needs an object with actions")
    app = slug(app or spec.get("app") or spec.get("name") or "")
    if not APP_ID.match(app):
        raise ValueError("a draft needs an app id: lowercase letters, digits, dashes")
    out = {k: spec[k] for k in TOP if k in spec}
    out.update(spec="powos.appcap/v1", app=app, enabled=False)
    out["name"] = str(out.get("name") or app)
    if isinstance(out.get("base"), dict):
        out["base"] = {k: out["base"][k] for k in ("kind", "url", "tls") if k in out["base"]}
        out["base"]["url"] = _scrub_url(out["base"].get("url", ""))
        out["base"].setdefault("kind", "internet")
    tokens = _tokens(spec, app)
    out["auth"] = {"tokens": tokens}
    origin = "captured" if source == "capture" else "drafted"
    ids = {slug(k, "_") or "action" for k in spec["actions"]}
    out["actions"] = {slug(k, "_") or "action": _action(slug(k, "_") or "action", a, origin, tokens, ids)
                      for k, a in spec["actions"].items()}
    # App-level origin/auth (schema/appcap.schema.json): every action here shares [origin] (normalize() is one
    # source per draft); the handle is the one every action that needs auth resolves to, or 'mixed'. The detail
    # page (apps/app-api/ui/pages/main.tsx) reads these instead of deriving them client-side.
    out["origin"] = origin
    handle = _app_auth_handle(out["actions"], tokens)
    if handle:
        out["auth"]["handle"] = handle
    return out


# ---- the store ----

def _write(path: str, data: dict) -> str:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    return tmp


def _commit(tmp: str, dst: str):
    try:
        errs = [e for e in appcap_validate.validate(tmp, show_list=False) if "WARN" not in e]
        if errs:
            raise ValueError("; ".join(e.split(": ", 1)[-1] for e in errs)[:300])
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def put(spec: dict, source: str, app: str | None = None) -> dict:
    """[spec] normalized, validated and written as a draft: its summary."""
    d = normalize(spec, source, app)
    os.makedirs(DRAFTS, mode=0o700, exist_ok=True)
    dst = draft_path(d["app"])
    _commit(_write(dst, d), dst)
    return info(d["app"])


def load(app: str) -> dict:
    p = draft_path(app)
    if not os.path.exists(p):
        raise LookupError(f"no draft '{app}'")
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def info(app: str) -> dict:
    s = load(app)
    acts = s["actions"]
    reads = sum(1 for a in acts.values() if a["safety"] == "read")
    return {"app": app, "name": s.get("name", app), "description": s.get("description", ""), "actions": len(acts),
            "reads": reads, "writes": len(acts) - reads, "exists": os.path.exists(os.path.join(SPECS, f"{app}.appcap.json"))}


def drafts() -> list:
    out = []
    for p in sorted(glob.glob(os.path.join(DRAFTS, "*.appcap.json"))):
        try:
            out.append(info(os.path.basename(p)[: -len(".appcap.json")]))
        except (OSError, ValueError, KeyError, LookupError):
            pass
    return out


def discard(app: str) -> dict:
    p = draft_path(app)
    if not os.path.exists(p):
        raise LookupError(f"no draft '{app}'")
    os.unlink(p)
    return {"discarded": app}


def add(app: str) -> dict:
    """The draft into specs/ with the whole app off (validated again); refused when an app of that id is there."""
    s = load(app)
    dst = os.path.join(SPECS, f"{app}.appcap.json")
    if os.path.exists(dst):
        raise ValueError(f"'{app}' is in your apps already - discard this draft or import it under another id")
    s["enabled"] = False
    os.makedirs(SPECS, mode=0o700, exist_ok=True)
    _commit(_write(dst, s), dst)
    os.unlink(draft_path(app))
    return {"added": app}


def migrate():
    """specs/<app>.draft.appcap.json (where appcap_draft.py once wrote) moved to drafts/: apps() listed them as apps."""
    for p in glob.glob(os.path.join(SPECS, "*.draft.appcap.json")):
        try:
            with open(p, encoding="utf-8") as f:
                put(json.load(f), "capture")
            os.unlink(p)
        except (OSError, ValueError, KeyError):
            pass


# ---- sources ----

def from_doc(doc: dict, app: str | None = None) -> dict:
    """An imported document: a capability spec as-is, or an OpenAPI one converted."""
    if not isinstance(doc, dict):
        raise ValueError("not a JSON object")
    if doc.get("openapi") or doc.get("swagger"):
        app = slug(app or (doc.get("info") or {}).get("title") or "")
        if not APP_ID.match(app):
            raise ValueError("name the app: its OpenAPI document has no usable title")
        spec = openapi2appcap.convert(doc, app)
        spec["description"] = "Drafted from its OpenAPI document. Reads on; writes off until you switch one on."
        return put(spec, "openapi", app)
    if doc.get("spec") == "powos.appcap/v1" or "actions" in doc:
        return put(doc, "appcap", app)
    raise ValueError("neither an OpenAPI document nor a capability spec")


def fetch(url: str) -> dict:
    """GET [url] (http/https, no credentials in it, none sent), up to 1 MB of JSON."""
    u = urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("an http or https URL")
    if u.username or u.password or re.search(r"[?&][^=&]*(" + SECRET.pattern + r")[^=&]*=", url, re.I):
        raise ValueError("no credentials in the URL: App API never takes one")
    req = urllib.request.Request(url, headers={"accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        body = r.read(FETCH_MAX + 1)
    if len(body) > FETCH_MAX:
        raise ValueError("bigger than 1 MB")
    try:
        return json.loads(body)
    except ValueError:
        raise ValueError("not JSON (YAML isn't read here: export the document as JSON)") from None


def sample(name: str) -> dict:
    p = os.path.join(SAMPLES, f"{os.path.basename(name)}.openapi.json")
    if not os.path.exists(p):
        raise LookupError(f"no sample '{name}'")
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def installed() -> list:
    """The installed PowOS apps: id, name, database (their manifests)."""
    out = []
    for m in sorted(glob.glob(os.path.join(POWOS_APPS, "*", "current", "powos-app.json"))):
        try:
            with open(m, encoding="utf-8") as f:
                j = json.load(f)
        except (OSError, ValueError):
            continue
        out.append({"id": j.get("id", ""), "name": j.get("name", j.get("id", "")),
                    "database": (j.get("module") or {}).get("database", "")})
    return [a for a in out if a["id"] and a["id"] != "local.app-api"]


STDB_TYPES = {"String": "string", "Bool": "boolean", "F32": "number", "F64": "number"}


def _stdb_type(t) -> str:
    k = next(iter(t), "") if isinstance(t, dict) else ""
    return STDB_TYPES.get(k) or ("integer" if re.match(r"^[IU]\d+$", k) else "string")


def _stdb_schema(db: str) -> dict:
    with urllib.request.urlopen(f"{STDB}/v1/database/{quote(db)}/schema?version=9", timeout=5) as r:
        return json.loads(r.read(FETCH_MAX))


def _public(t: dict) -> bool:
    return "Public" in (t.get("table_access") or {})


def _lifecycle(r: dict) -> bool:
    lc = r.get("lifecycle")
    return bool(lc) and "none" not in lc


def _stdb_actions(db: str, schema: dict) -> dict:
    """The app's own database only (one DB per app): its public tables as SQL reads, its reducers as writes - which
    normalize() leaves off until the user switches one on. Never a write to a table, never another app's database."""
    acts = {}
    for t in schema.get("tables") or []:
        name = t.get("name")
        if isinstance(name, str) and _public(t):
            acts[f"list_{slug(name, '_')}"] = {
                "summary": f"Every row of {name}.", "safety": "read", "inputs": {"type": "object", "properties": {}},
                "endpoint": {"method": "POST", "path": f"/v1/database/{db}/sql", "body": f"SELECT * FROM {name}"}}
    for r in schema.get("reducers") or []:
        name = r.get("name")
        if not isinstance(name, str) or _lifecycle(r):
            continue
        params = [((e.get("name") or {}).get("some"), e.get("algebraic_type")) for e in (r.get("params") or {}).get("elements", [])]
        props = {p: {"type": _stdb_type(t)} for p, t in params if p}
        acts[slug(name, "_")] = {
            "summary": f"Run {name}.", "safety": "reversible-write", "inputs": {"type": "object", "properties": props},
            "endpoint": {"method": "POST", "path": f"/v1/database/{db}/call/{name}", "body": {p: f"{{{p}}}" for p in props}}}
    return acts


def from_powos(app_id: str) -> dict:
    a = next((x for x in installed() if x["id"] == app_id), None)
    if not a:
        raise LookupError(f"no installed PowOS app '{app_id}'")
    acts = {"open": {"summary": f"Open {a['name']}.", "safety": "read", "endpoint": {"ui": {"route": f"app://{app_id}"}}}}
    note = "the app's page"
    if a["database"]:
        try:
            acts.update(_stdb_actions(a["database"], _stdb_schema(a["database"])))
            note = f"the app's page and its database {a['database']}"
        except (OSError, ValueError):
            note = f"the app's page (its database {a['database']} didn't answer)"
    spec = {"app": slug(app_id), "name": a["name"], "description": f"Drafted from {note}.",
            "base": {"kind": "on-device", "url": STDB, "tls": "none"}, "actions": acts}
    return put(spec, "powos")


def _link_action(link: dict) -> tuple[str, dict] | None:
    uri = str(link.get("uri") or "")
    if not re.match(r"^[a-z][a-z0-9+.-]*:", uri, re.I):
        return None
    deep = uri.replace(".*", "{rest}")
    props = {"rest": {"type": "string"}} if "{rest}" in deep else {}
    return "open_" + slug(re.sub(r"^[a-z0-9+.-]*:/*", "", uri, flags=re.I).replace(".*", ""), "_")[:40], {
        "summary": f"Open {uri}" + (f" ({link['activity']})" if link.get("activity") else ""), "safety": "read",
        "inputs": {"type": "object", "properties": props}, "endpoint": {"ui": {"deep_link": deep}}}


def from_android(pkg: str, label: str, links: list) -> dict:
    """An Android app's exported VIEW/BROWSABLE links (the bridge's apps.links) as UI reads: screens it opens."""
    if not re.match(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$", pkg or ""):
        raise ValueError("an Android package name")
    acts = {"open": {"summary": f"Open {label or pkg}.", "safety": "read", "endpoint": {"ui": {"deep_link": f"android-app://{pkg}"}}}}
    for link in (links or [])[:40]:
        got = _link_action(link if isinstance(link, dict) else {})
        if got and got[0] not in acts:
            acts[got[0]] = got[1]
    spec = {"app": slug(label) or slug(pkg.split(".")[-1]), "name": label or pkg,
            "description": f"Drafted from the screens {pkg} opens from a link.", "base": {"kind": "on-device"}, "actions": acts}
    return put(spec, "android")


# ---- routes (appcap_serve.py) ----

def r_drafts(_q, _b):
    return {"drafts": drafts()}


def r_installed(_q, _b):
    return {"powos": installed()}


def r_import(_q, b):
    if b.get("sample"):
        return from_doc(sample(b["sample"]), b.get("app"))
    if b.get("url"):
        return from_doc(fetch(str(b["url"])), b.get("app"))
    doc = b.get("doc")
    if isinstance(doc, str):
        try:
            doc = json.loads(doc)
        except ValueError:
            raise ValueError("not JSON (YAML isn't read here: export the document as JSON)") from None
    return from_doc(doc, b.get("app"))


def r_from_installed(_q, b):
    if b.get("kind") == "android":
        return from_android(str(b.get("pkg") or ""), str(b.get("label") or ""), b.get("links") or [])
    return from_powos(str(b.get("id") or ""))


ROUTES = {("GET", "/drafts"): r_drafts, ("GET", "/installed"): r_installed,
          ("POST", "/draft/import"): r_import, ("POST", "/draft/installed"): r_from_installed,
          ("POST", "/draft/add"): lambda _q, b: add(str(b.get("app"))),
          ("POST", "/draft/discard"): lambda _q, b: discard(str(b.get("app")))}
BIG = {"/draft/import"}  # a pasted/picked document: up to 1 MB, not the 64 KB other bodies get


def main() -> int:
    ap = argparse.ArgumentParser(description="App API drafts: + add app")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("put")
    p.add_argument("--source", required=True, choices=SOURCES)
    p.add_argument("file")
    p.add_argument("--app")
    p = sub.add_parser("import")
    p.add_argument("where")
    p.add_argument("--app")
    sub.add_parser("powos").add_argument("id")
    sub.add_parser("list")
    for c in ("show", "add", "discard"):
        sub.add_parser(c).add_argument("app")
    a = ap.parse_args()
    try:
        if a.cmd == "put":
            with open(a.file, encoding="utf-8") as f:
                doc = json.load(f)
            out = from_doc(doc, a.app) if a.source == "openapi" else put(doc, a.source, a.app)
        elif a.cmd == "import":
            if re.match(r"^https?://", a.where):
                out = from_doc(fetch(a.where), a.app)
            else:
                with open(a.where, encoding="utf-8") as f:
                    out = from_doc(json.load(f), a.app)
        elif a.cmd == "powos":
            out = from_powos(a.id)
        elif a.cmd == "list":
            out = {"drafts": drafts()}
        else:
            out = {"show": lambda x: load(x), "add": add, "discard": discard}[a.cmd](a.app)
    except (OSError, ValueError, LookupError) as e:
        print(f"refused: {e}", file=sys.stderr)
        return 1
    print(json.dumps(out, indent=2))
    if a.cmd in ("put", "import", "powos"):
        print(f"draft '{out['app']}' ready: {out['reads']} read(s) on, {out['writes']} write(s) off - review it in "
              f"App API (Apps, + add app, Drafts)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
