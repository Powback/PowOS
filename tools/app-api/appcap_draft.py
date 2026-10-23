#!/usr/bin/env python3
"""appcap_draft.py - turn an app's recordings into a READ-ONLY draft appcap.

Chains the capture->spec pipeline for one app: its recordings/<app>*.har -> har2openapi.py -> openapi2appcap.py ->
specs/<app>.draft.appcap.json. The draft is conservative by construction (openapi2appcap): the whole app is
`enabled: false`, reads are enabled, every write is disabled-until-promoted. A draft is READ-ONLY until the user
promotes it in the App API app; nothing calls it meanwhile. Runs on PowOS, offline, stdlib only, never prints a token.

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
import appcap_flows  # noqa: E402
import appcap_store  # noqa: E402

STATE = appcap_store.STATE
SPECS = os.path.join(STATE, "specs")


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
        os.makedirs(SPECS, mode=0o700, exist_ok=True)
        draft = os.path.join(SPECS, f"{args.app}.draft.appcap.json")
        p = subprocess.run([sys.executable, os.path.join(HERE, "openapi2appcap.py"), oa, "--app", args.app],
                           check=True, stdout=subprocess.PIPE, text=True)
        open(draft, "w", encoding="utf-8").write(p.stdout)

    spec = json.load(open(draft, encoding="utf-8"))
    reads = sum(1 for a in spec["actions"].values() if a["safety"] == "read")
    print(f"wrote {draft}: {len(spec['actions'])} action(s) from {n} flow(s) — "
          f"{reads} read (enabled), {len(spec['actions']) - reads} write (disabled until promoted); "
          f"app enabled={spec['enabled']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
