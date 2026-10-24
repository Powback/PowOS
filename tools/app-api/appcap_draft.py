#!/usr/bin/env python3
"""appcap_draft.py - turn an app's recordings into a READ-ONLY draft appcap.

Chains the capture->spec pipeline for one app: its recordings/<app>*.har -> har2openapi.py -> openapi2appcap.convert
-> appcap_add.put (normalized, validated) -> drafts/<app>.appcap.json, App API's drafts (never specs/, where apps()
would list it as an app). The draft is conservative by construction: the whole app is `enabled: false`, reads are
enabled, every write is disabled-until-promoted. Nothing calls it: it is only previewed until the user adds it in the
App API app ("+ add app", Drafts) and switches its actions on. Runs on PowOS, offline, stdlib only, never prints a token.

  appcap_draft.py --app NAME            # draft from all of the app's recordings
  appcap_draft.py --har FILE --app NAME # draft from one recording
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import appcap_add  # noqa: E402
import appcap_flows  # noqa: E402
import openapi2appcap  # noqa: E402


def _merge_hars(hars: list[str], out: str):
    entries = []
    for h in hars:
        try:
            entries += json.load(open(h, encoding="utf-8"))["log"]["entries"]
        except (OSError, ValueError, KeyError):
            pass
    json.dump({"log": {"version": "1.2", "creator": {"name": "appcap_draft", "version": "1"}, "entries": entries}},
              open(out, "w", encoding="utf-8"))
    return len(entries)


def main() -> int:
    ap = argparse.ArgumentParser(description="recordings -> read-only draft appcap")
    ap.add_argument("--app", required=True)
    ap.add_argument("--har", help="one recording; default = all of the app's recordings")
    args = ap.parse_args()

    hars = [args.har] if args.har else [
        p for p in sorted(glob.glob(os.path.join(appcap_flows.RECS, f"{args.app}*.har"))) if not p.endswith(".orig.har")]
    if not hars:
        print(f"no recordings for '{args.app}' in {appcap_flows.RECS}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as td:
        merged = os.path.join(td, "merged.har")
        n = _merge_hars(hars, merged)
        oa = os.path.join(td, "oa.json")
        subprocess.run([sys.executable, os.path.join(HERE, "har2openapi.py"), merged, "-o", oa,
                        "--title", args.app], check=True)
        with open(oa, encoding="utf-8") as f:
            spec = openapi2appcap.convert(json.load(f), args.app)
    try:
        d = appcap_add.put(spec, "capture", args.app)
    except ValueError as e:
        print(f"refused: {e}", file=sys.stderr)
        return 1
    print(f"wrote {appcap_add.draft_path(d['app'])}: {d['actions']} action(s) from {n} flow(s) — "
          f"{d['reads']} read (enabled), {d['writes']} write (disabled until promoted); app enabled=False",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
