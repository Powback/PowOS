#!/usr/bin/env python3
"""perf-summary.py <label> <perf-*.json>: one recording's numbers in a few lines (perf-scenarios.sh).

fps p50/p5 and frames over 33.4 ms (home's main-shell frames), the native frame counts (MainStallWatch: missed, slow
frames with their phase), long animation frames, UI-thread messages > 24 ms, and the render scan's top components."""
import json
import sys


def active(d):
    """The refresh rate while something moves: home's frames from each gesture's down to its up + SETTLE_TAIL_MS (the
    fling/settle the vote must hold). The recording's fps p50 counts the idle seconds between reps too, where 60 Hz is
    the rule (HighRefresh.kt gives the vote back), so a 48 s run of three pulls read p50 60 (perf-1793639664326)."""
    times, deltas = d.get("frameTimes") or [], d.get("frameDeltas") or []
    inputs = ((d.get("home") or {}).get("inputs")) or []
    spans, down = [], {}
    for e in inputs:
        if len(e) < 6 or e[4] != "touch":
            continue
        if e[1] == "d":
            down[e[5]] = e[0]
        elif e[1] == "u" and e[5] in down:
            spans.append((down.pop(e[5]), e[0] + SETTLE_TAIL_MS))
    if not spans or not times:
        return
    n = min(len(deltas), len(times) - 1)
    inside = [deltas[i] for i in range(n) if any(a <= times[i + 1] <= b for a, b in spans)]
    if not inside:
        return
    fast = sum(1 for x in inside if x < 12.5)
    print(f"  while moving ({len(spans)} gestures, down -> up + {SETTLE_TAIL_MS} ms): {len(inside)} frames, "
          f"{round(100 * fast / len(inside))}% at 120 Hz (< 12.5 ms), >33 ms {sum(1 for x in inside if x > 33.4)}")


SETTLE_TAIL_MS = 600


def main():
    label, path = sys.argv[1], sys.argv[2]
    d = json.load(open(path))
    s = d.get("summary", {})
    f = s.get("fps", {})
    print(f"[{label}] {s.get('durationMs')} ms, {s.get('frames')} frames: fps p50 {f.get('p50')} p5 {f.get('p5')} "
          f"min {f.get('min')}, >33 ms frames {s.get('jank')}")
    deltas = (d.get("main") or {}).get("frameDeltas") or d.get("frameDeltas") or []
    if deltas:
        over = [x for x in deltas if x > 12.5]
        print(f"  frames over 12.5 ms (a missed 120 Hz vsync): {len(over)} of {len(deltas)}; "
              f"over 16.7 ms: {sum(1 for x in deltas if x > 16.7)}")
    active(d)
    n = s.get("native") or {}
    fr = n.get("frames") or {}
    print(f"  native: {fr.get('count')} frames, missed {fr.get('missed')}, slow {json.dumps(fr.get('slow', [])[:5])}")
    for k in ("msgs", "messages", "longest", "gapSeen"):
        if n.get(k):
            print(f"  native {k}: {json.dumps(n[k])[:600]}")
    lt = s.get("longTasks") or []
    if lt:
        print(f"  long tasks: {json.dumps(lt[:6])}")
    print(f"  home: {json.dumps(s.get('home'))[:400]}")
    r = s.get("renders") or {}
    if r:
        print(f"  renders: {r.get('renders')} ({r.get('needless')} needless, {r.get('renderMs')} ms, {r.get('commits')} commits)")
        print(f"    by time: {r.get('byTime')}")
        print(f"    by count: {r.get('byCount')}")
        if r.get("slowCommits"):
            print(f"    slow commits: {r.get('slowCommits')}")
    if s.get("surfaces"):
        print(f"  surfaces: {json.dumps(s['surfaces'])[:800]}")


main()
