#!/usr/bin/env python3
"""appcap_render.py - render an App Capability Spec into its consumers' views.

This is the "view the resulting API" generator: given an <app>.appcap.json it
produces, for the same single source of truth, any of:

  --api      a human-readable API reference (Markdown) — what the app can do
  --tools    the MCP / PowOS-AI tool list (JSON) the AI would get
  --cli      the generated `powos app <app> …` command listing
  --widgets  the read actions a widget may bind to, with refresh hints

It is deliberately read-only and offline: it never contacts the app, never
resolves a token (handles are shown as handles), and refuses to render anything
a spec that fails appcap_validate.py's safety invariants. Disabled apps/actions
are shown struck through / omitted from tool+widget output, mirroring what the
real generators do.

Usage:
  appcap_render.py examples/hue.appcap.json --api
  appcap_render.py examples/hue.appcap.json --tools
  appcap_render.py examples/hue.appcap.json --cli --widgets
Stdlib only. Never prints a token value.
"""
from __future__ import annotations

import argparse
import json
import sys

import appcap_validate

SAFE_BADGE = {"read": "🟢 read", "reversible-write": "🟡 reversible", "spend": "🔴 spend"}


def load(path: str) -> dict:
    errs = [e for e in appcap_validate.validate(path, show_list=False) if "WARN" not in e]
    if errs:
        for e in errs:
            print("ERROR " + e, file=sys.stderr)
        sys.exit(f"refusing to render {path}: {len(errs)} safety error(s)")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def enabled_actions(spec: dict) -> dict:
    return {k: v for k, v in spec["actions"].items() if v.get("enabled", True)}


def render_api(spec: dict) -> str:
    toks = (spec.get("auth") or {}).get("tokens", {})
    tok_summary = ", ".join(f"`{k}` -> `{v['store']}` (value never shown)" for k, v in toks.items()) or "none"
    base = spec.get("base") or {}
    out = [f"# {spec['name']} — API ({spec['app']})",
           "", spec.get("description", ""), "",
           f"- base: `{base.get('url', '?')}` ({base.get('kind', '?')}, tls={base.get('tls', 'standard')})",
           f"- enabled: **{spec.get('enabled', False)}**",
           f"- auth tokens: {tok_summary}",
           ""]
    for aid, a in sorted(spec["actions"].items()):
        en = a.get("enabled", True)
        head = f"## `{aid}`" + ("" if en else "  _(disabled — not in allowlist)_")
        out.append(head)
        out.append(f"{SAFE_BADGE.get(a['safety'], a['safety'])} · origin: {a['origin']}"
                   + ("" if a['origin'] != 'captured' else (" · promoted" if a.get('promoted') else " · NOT promoted (read-only)"))
                   + (" · widget-bindable" if a.get("widget") else "")
                   + (" · needs confirmation" if a.get("confirm") else ""))
        out.append("")
        out.append(a.get("summary", ""))
        ep = a.get("endpoint", {})
        if ep.get("ui"):
            ui = ep["ui"]
            tgt = ui.get("deep_link") or ui.get("route") or f"{len(ui.get('steps', []))} scripted step(s)"
            out.append(f"- maps to: UI navigation -> `{tgt}`")
        elif ep.get("argv"):
            out.append(f"- maps to: CLI `{' '.join(ep['argv'])}`")
        else:
            out.append(f"- maps to: `{ep.get('method','?')} {ep.get('path') or ep.get('operationId','?')}`"
                       + (f" (auth `{ep['auth']}`)" if ep.get("auth") else ""))
        if a.get("refresh"):
            r = a["refresh"]
            out.append(f"- refresh: " + (f"event stream `{r['event_stream']}`" if r.get("event_stream")
                                         else f"poll every {r.get('poll_s','?')}s"))
        if a.get("undo"):
            out.append(f"- undo: `{a['undo']}`")
        if a.get("confirm_template"):
            out.append(f"- confirmation shown: _{a['confirm_template']}_")
        inp = (a.get("inputs") or {}).get("properties") or {}
        if inp:
            out.append(f"- inputs: " + ", ".join(f"`{k}`" for k in inp))
        out.append("")
    return "\n".join(out)


def render_tools(spec: dict) -> str:
    tools = []
    for aid, a in enabled_actions(spec).items():
        params = dict((a.get("inputs") or {"type": "object", "properties": {}}))
        params.setdefault("type", "object")
        props = dict(params.get("properties") or {})
        props["dry_run"] = {"type": "boolean", "description": "Show the request without sending it."}
        params["properties"] = props
        tool = {
            "name": f"{spec['app']}__{aid}",
            "description": a.get("summary", ""),
            "x-safety": a["safety"],
            "inputSchema": params,
        }
        if a["safety"] == "spend":
            tool["x-requires-confirmation"] = True
            tool["x-confirm-template"] = a.get("confirm_template")
        if a["safety"] == "reversible-write":
            tool["x-logged"] = True
            if a.get("undo"):
                tool["x-undo-tool"] = f"{spec['app']}__{a['undo']}" if a['undo'] != 'inverse' else "inverse"
        tools.append(tool)
    return json.dumps({"app": spec["app"], "enabled": spec.get("enabled", False), "tools": tools}, indent=2)


def render_cli(spec: dict) -> str:
    out = [f"powos app {spec['app']} <action> [--arg value …] [--dry-run]", ""]
    for aid, a in sorted(enabled_actions(spec).items()):
        flags = " ".join(f"--{k} <{(v.get('type','str'))}>" for k, v in ((a.get("inputs") or {}).get("properties") or {}).items())
        extra = ""
        if a["safety"] == "reversible-write":
            extra = "   [--undo]"
        if a["safety"] == "spend":
            extra = "   [--confirm]  (prints the confirmation first; refuses without it)"
        out.append(f"  powos app {spec['app']} {aid} {flags}{extra}")
        out.append(f"      {SAFE_BADGE.get(a['safety'], a['safety'])}  {a.get('summary','')}")
    return "\n".join(out)


def render_widgets(spec: dict) -> str:
    out = [f"# {spec['name']} — widget-bindable data sources (read-only by rule S5)", ""]
    any_ = False
    for aid, a in sorted(enabled_actions(spec).items()):
        if not a.get("widget"):
            continue
        any_ = True
        r = a.get("refresh") or {}
        hint = (f"event stream `{r['event_stream']}`" if r.get("event_stream")
                else f"poll {r.get('poll_s', '?')}s" if r.get("poll_s")
                else f"cache {a.get('cache_ttl_s', (spec.get('defaults') or {}).get('cache_ttl_s', 0))}s")
        out.append(f"- `{aid}` — {a.get('summary','')}  ·  refresh: {hint}")
    if not any_:
        out.append("_(no widget-bindable read actions)_")
    return "\n".join(out)


def _fill(obj, args: dict):
    """Substitute {key} placeholders from args into a path string or body dict."""
    if isinstance(obj, str):
        for k, v in args.items():
            obj = obj.replace("{" + k + "}", str(v))
        return obj
    if isinstance(obj, dict):
        return {k: _fill(v, args) for k, v in obj.items()}
    return obj


def render_call(spec: dict, action: str, args: dict) -> str:
    """Build the EXACT request an action would send, and print it WITHOUT sending.
    This is dry-run only: appcap_render never issues a request, so it can never
    change anything (e.g. never touches the Hue bridge)."""
    a = spec["actions"].get(action)
    if not a:
        return f"no such action '{action}'"
    ep = a.get("endpoint", {})
    toks = (spec.get("auth") or {}).get("tokens", {})
    out = [f"DRY-RUN — building request for {spec['app']}.{action} ({SAFE_BADGE.get(a['safety'], a['safety'])})",
           "                 ↳ NOTHING IS SENT. This is a preview only.", ""]
    if a["safety"] == "spend":
        tmpl = _fill(a.get("confirm_template", "(no template)"), args)
        out += [f"  ⚠ spend action — a real call would FIRST require your confirmation:",
                f"      \"{tmpl}\"", "      and refuse without an explicit yes.", ""]
    if ep.get("ui"):
        ui = _fill(ep["ui"], args)
        out.append(f"  UI navigation: {ui.get('deep_link') or ui.get('route') or ui.get('steps')}")
        return "\n".join(out)
    base = (spec.get("base") or {}).get("url", "")
    path = _fill(ep.get("path", ""), args)
    out.append(f"  {ep.get('method','GET')} {base}{path}")
    auth = ep.get("auth")
    if auth and auth in toks:
        t = toks[auth]
        where = t.get("header") or ("cookie" if t.get("type") == "cookie" else t.get("query", "?"))
        # The app's OWN header, value resolved from the store at real call time.
        out.append(f"  {where}: <resolved from {t['store']} — value never shown>")
    if ep.get("body"):
        out.append("  body: " + json.dumps(_fill(ep["body"], args)))
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="Render an App Capability Spec into its consumer views.")
    ap.add_argument("spec")
    ap.add_argument("--api", action="store_true")
    ap.add_argument("--tools", action="store_true")
    ap.add_argument("--cli", action="store_true")
    ap.add_argument("--widgets", action="store_true")
    ap.add_argument("--call", metavar="ACTION", help="preview (dry-run) the request for ACTION; never sends")
    ap.add_argument("--arg", action="append", default=[], metavar="k=v", help="argument for --call")
    args = ap.parse_args()
    spec = load(args.spec)
    if args.call:
        kv = {}
        for pair in args.arg:
            k, _, v = pair.partition("=")
            kv[k] = v
        print(render_call(spec, args.call, kv))
        return 0
    if not (args.api or args.tools or args.cli or args.widgets):
        args.api = True
    parts = []
    if args.api:
        parts.append(render_api(spec))
    if args.tools:
        parts.append(render_tools(spec))
    if args.cli:
        parts.append(render_cli(spec))
    if args.widgets:
        parts.append(render_widgets(spec))
    print("\n\n".join(parts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
