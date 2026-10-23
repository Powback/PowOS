#!/usr/bin/env python3
"""appcap_validate.py - validate a PowOS App Capability Spec and enforce its
safety invariants.

A plain JSON Schema (schema/appcap.schema.json) covers the structure. This tool
adds the cross-field SAFETY rules that every consumer (AI tools, CLI, SDK,
widget) relies on being true before it is generated. If this passes, a consumer
generated from the spec cannot violate the safety model by construction.

Invariants enforced (each a hard error unless marked warn):
  S1  every action's `endpoint.auth` names a token that exists in auth.tokens
  S2  no token `store` is an inline value — it must be a secret:/store: handle
      (defence in depth: a real token must never land in the spec file)
  S3  a `captured`-origin action may only be `read` unless `promoted: true`
      (capture-generated actions start read-only until the user promotes them)
  S4  a `spend` action MUST have confirm:true and MUST NOT have widget:true
  S5  only `read` actions may set widget:true
  S6  confirm:true requires a confirm_template (what + how much is shown)
  S7  (warn) a reversible-write action should declare `undo`
  S8  a disabled app or disabled action is reported (not an error) so a
      generator knows to skip it

Usage:
  appcap_validate.py hue.appcap.json [more.json ...]
  appcap_validate.py --list hue.appcap.json     # print the action/safety table
Exit 0 if all valid, 1 otherwise. Stdlib only; never prints a token value.
"""
from __future__ import annotations

import json
import re
import sys

HANDLE = re.compile(r"^(secret|store):[A-Za-z0-9_.:-]+$")
SAFETY = {"read", "reversible-write", "spend"}
ORIGIN = {"official", "captured"}


def validate(path: str, show_list: bool) -> list[str]:
    errs: list[str] = []
    try:
        with open(path, encoding="utf-8") as f:
            spec = json.load(f)
    except (OSError, ValueError) as e:
        return [f"{path}: cannot read/parse: {e}"]

    if spec.get("spec") != "powos.appcap/v1":
        errs.append(f"{path}: spec must be 'powos.appcap/v1'")
    app = spec.get("app", "?")
    tokens = (spec.get("auth") or {}).get("tokens") or {}

    # S2: token handles, never inline values
    for tid, t in tokens.items():
        store = (t or {}).get("store", "")
        if not HANDLE.match(store):
            errs.append(f"{path}: token '{tid}' store must be a secret:/store: handle, not an inline value [S2]")

    actions = spec.get("actions") or {}
    if not actions:
        errs.append(f"{path}: no actions")

    rows = []
    for aid, a in actions.items():
        safety = a.get("safety")
        origin = a.get("origin")
        enabled = a.get("enabled", True)
        promoted = a.get("promoted", False)
        widget = a.get("widget", False)
        confirm = a.get("confirm", False)
        if safety not in SAFETY:
            errs.append(f"{path}:{aid}: safety must be one of {sorted(SAFETY)}")
        if origin not in ORIGIN:
            errs.append(f"{path}:{aid}: origin must be one of {sorted(ORIGIN)}")

        # S1: auth reference resolves
        ep = a.get("endpoint") or {}
        auth = ep.get("auth")
        if auth and auth not in tokens:
            errs.append(f"{path}:{aid}: endpoint.auth '{auth}' not in auth.tokens [S1]")

        # S9: endpoint must map to something (HTTP, CLI argv, captured op, or UI)
        if not (ep.get("method") or ep.get("argv") or ep.get("operationId") or ep.get("ui")):
            errs.append(f"{path}:{aid}: endpoint maps to nothing (need method / argv / operationId / ui) [S9]")

        # S3: captured starts read-only until promoted
        if origin == "captured" and safety != "read" and not promoted:
            errs.append(f"{path}:{aid}: captured action with safety='{safety}' needs promoted=true "
                        f"(capture-generated actions start read-only) [S3]")

        # S4: spend => confirm, never widget
        if safety == "spend":
            if not confirm:
                errs.append(f"{path}:{aid}: safety='spend' requires confirm=true [S4]")
            if widget:
                errs.append(f"{path}:{aid}: safety='spend' must not set widget=true [S4]")

        # S5: widget only for read
        if widget and safety != "read":
            errs.append(f"{path}:{aid}: widget=true only allowed for safety='read' [S5]")

        # S6: confirm needs a template
        if confirm and not a.get("confirm_template"):
            errs.append(f"{path}:{aid}: confirm=true requires confirm_template [S6]")

        # S7: reversible-write should declare undo (warn)
        if safety == "reversible-write" and not a.get("undo"):
            errs.append(f"{path}:{aid}: WARN reversible-write without 'undo' [S7]")

        rows.append((aid, safety, origin, "on" if enabled else "OFF",
                     "widget" if widget else "", "confirm" if confirm else ""))

    if show_list:
        print(f"# {app}: {len(rows)} action(s)  (app enabled={spec.get('enabled', False)})")
        for aid, safety, origin, en, w, c in sorted(rows):
            print(f"  {aid:20} {safety:16} {origin:9} {en:3} {w:7} {c}")
    return errs


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--list"]
    show_list = "--list" in sys.argv[1:]
    if not args:
        print(__doc__.strip().splitlines()[0])
        print("usage: appcap_validate.py [--list] SPEC.json ...", file=sys.stderr)
        return 2
    all_errs: list[str] = []
    for path in args:
        errs = validate(path, show_list)
        all_errs += errs
    hard = [e for e in all_errs if "WARN" not in e]
    for e in all_errs:
        print(("  " if "WARN" in e else "ERROR ") + e, file=sys.stderr)
    if hard:
        print(f"\n{len(hard)} error(s)", file=sys.stderr)
        return 1
    print("ok: all specs valid" + (f" ({len(all_errs)} warning(s))" if all_errs else ""), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
