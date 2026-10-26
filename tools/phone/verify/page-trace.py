#!/usr/bin/env python3
"""tools/phone/verify/page-trace.py TRACE.pftrace: what home's frames cost during page swipes (window-rec.sh --trace).

Prints, for com.powos.app (HomeShell's process; WindowFrames lives on the same main thread):
- SurfaceFlinger's frame timeline per layer: frames, janky ones and their jank types, the worst durations;
- the main thread's Choreographer#doFrame slices: count, p50/p90/max;
- the main thread's long slices (>= 4 ms) by name: binder calls, relayouts, traversals - what blocks a frame;
- the main thread's time by state (running / binder / sleeping) inside the frames over 12 ms.
Run: uvx --with perfetto python3 tools/phone/verify/page-trace.py FILE
"""
import sys
from perfetto.trace_processor import TraceProcessor

APP = "com.powos.app"


def q(tp, sql):
    return list(tp.query(sql))


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else 0


def main(path):
    tp = TraceProcessor(trace=path)
    upid = q(tp, f"select upid, pid from process where name = '{APP}' order by upid desc limit 1")
    if not upid:
        print("no", APP, "in the trace")
        return
    u, pid = upid[0].upid, upid[0].pid
    utid = q(tp, f"select utid from thread where upid = {u} and is_main_thread = 1 limit 1")[0].utid
    print(f"{APP} pid {pid}")

    rows = q(tp, f"""select a.layer_name l, a.dur d, a.jank_type j, a.present_type p from actual_frame_timeline_slice a
        where a.upid = {u}""")
    by = {}
    for r in rows:
        by.setdefault(r.l, []).append(r)
    for layer, fr in sorted(by.items(), key=lambda kv: -len(kv[1])):
        janky = [r for r in fr if r.j not in (None, "None")]
        kinds = {}
        for r in janky:
            kinds[r.j] = kinds.get(r.j, 0) + 1
        ds = [r.d / 1e6 for r in fr]
        print(f"SF frames {layer[:70]}: {len(fr)} frames, {len(janky)} janky {kinds}, p50 {pct(ds, .5):.1f} p90 {pct(ds, .9):.1f} max {max(ds):.1f} ms")

    df = q(tp, f"""select s.ts, s.dur from slice s join thread_track t on s.track_id = t.id
        where t.utid = {utid} and s.name like 'Choreographer#doFrame%' and s.depth = 0""")
    ds = [r.dur / 1e6 for r in df]
    if ds:
        print(f"main thread doFrame: {len(ds)}, p50 {pct(ds, .5):.1f} p90 {pct(ds, .9):.1f} max {max(ds):.1f} ms, over 8.3 ms: {sum(d > 8.3 for d in ds)}")

    long = q(tp, f"""select s.name n, count(*) c, sum(s.dur) d, max(s.dur) m from slice s join thread_track t on s.track_id = t.id
        where t.utid = {utid} and s.dur >= 4000000 group by s.name order by d desc limit 25""")
    print("main thread slices >= 4 ms (name: count, total, max):")
    for r in long:
        print(f"  {r.n[:90]}: {r.c}x, {r.d / 1e6:.0f} ms, max {r.m / 1e6:.1f} ms")

    st = q(tp, f"""select ts.state s, sum(ts.dur) d from thread_state ts where ts.utid = {utid} group by ts.state order by d desc""")
    print("main thread states over the trace:", ", ".join(f"{r.s} {r.d / 1e6:.0f} ms" for r in st))
    tx = q(tp, f"""select coalesce(r.name, '?') n, count(*) c, sum(b.dur) d, max(b.dur) m from slice b join thread_track t on b.track_id = t.id
        left join flow f on f.slice_out = b.id left join slice r on r.id = f.slice_in
        where t.utid = {utid} and b.name = 'binder transaction' group by n order by d desc limit 12""")
    print("main thread binder calls (to whom: count, total, max):")
    for r in tx:
        print(f"  {r.n[:70]}: {r.c}x, {r.d / 1e6:.0f} ms, max {r.m / 1e6:.1f} ms")
    aidl = q(tp, f"""select s.name n, count(*) c, sum(s.dur) d, max(s.dur) m from slice s join thread_track t on s.track_id = t.id
        where t.utid = {utid} and (s.name like 'AIDL::%' or s.name like 'HIDL::%') group by s.name order by d desc limit 12""")
    for r in aidl:
        print(f"  {r.n[:90]}: {r.c}x, {r.d / 1e6:.0f} ms, max {r.m / 1e6:.1f} ms")


if __name__ == "__main__":
    main(sys.argv[1])
