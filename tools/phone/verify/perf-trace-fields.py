#!/usr/bin/env python3
"""perf-trace-fields.py <perf-*.json>: does a recording carry what react-scan shows? (board task
perf-traces-the-user-sends-must-show-what-react; perf-scenarios.sh --only trace records one on the phone).

Asserted, in the summary the mail and PowOS AI get inline: renders (count > 0, commits > 0), the components by count
and by time, the slow commits with their duration and components, home's long-frame verdicts and pre-roll; in the full
detail: the commit list with a duration and component names per commit. One line per field; exit 1 if any is missing."""
import json
import sys


def check(d):
    s, bad, ok = d.get("summary") or {}, [], []
    r = s.get("renders")
    if not isinstance(r, dict):
        return [f"summary.renders isn't a section: {str(r)[:160]}"], ok
    for k in ("renders", "commits"):
        (ok if isinstance(r.get(k), int) and r[k] > 0 else bad).append(f"summary.renders.{k} = {r.get(k)}")
    for k in ("byCount", "byTime", "slowCommits"):
        v = r.get(k)
        (ok if isinstance(v, list) and v else bad).append(f"summary.renders.{k}: {json.dumps(v)[:160]}")
    sc = r.get("slowCommits") or []
    if sc and not all("ms at" in x and ": " in x for x in sc):
        bad.append(f"summary.renders.slowCommits rows lack 'Nms at +Tms: Comp xN': {sc[:2]}")
    h = s.get("home")
    if not isinstance(h, dict) or "longFrames" not in h or "preRollMs" not in h:
        bad.append(f"summary.home lacks longFrames/preRollMs: {json.dumps(h)[:160]}")
    else:
        ok.append(f"summary.home: {len(h['longFrames'])} long frames, preRollMs {h['preRollMs']}")
    cl = (d.get("renders") or {}).get("commitList") or []
    good = [c for c in cl if isinstance(c.get("ms"), (int, float)) and c.get("names")]
    (ok if good else bad).append(f"renders.commitList: {len(cl)} commits, {len(good)} with ms + components")
    return bad, ok


def main():
    d = json.load(open(sys.argv[1]))
    bad, ok = check(d)
    for x in ok:
        print(f"ok {x}")
    for x in bad:
        print(f"MISSING {x}")
    sys.exit(1 if bad else 0)


main()
