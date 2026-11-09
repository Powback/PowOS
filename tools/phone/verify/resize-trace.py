#!/usr/bin/env python3
"""tools/phone/verify/resize-trace.py TRACE.pftrace [CSV]: which layer misses frames during a window resize drag
(ww-resize.sh, one way of a drag under perfetto). Trace-grade attribution per frame, from SurfaceFlinger's own frame
timeline (android.surfaceflinger.frametimeline) and the scheduler:

- home's layer (com.powos.app HomeShell): every surface frame's jank type (App Deadline Missed = the shell's own
  layout/paint/render was late; Buffer Stuffing = it queued ahead of what SF took; SurfaceFlinger * = composition),
  present type (on time / late / dropped);
- SF's display frames over the same span: jank types and how many were GPU (client) composited - a display frame SF
  composed late takes every layer's frame with it, the shell's included;
- SF main thread + RenderEngine slices over 4 ms (what composition spent its time on), and the CPU time per process
  while the finger moved (KWin, the Linux app, the shell, SF);
- verdict: the layer that owns the missed frames: shell | surfaceflinger-gpu | surfaceflinger-cpu | display-hal | none
  (buffer stuffing and SF stuffing are printed as consequences, not sources).
CSV (optional): one row per home surface frame: ts_ms,dur_ms,jank,present,on_time,display_jank,display_gpu.
Run: uvx --with perfetto python3 tools/phone/verify/resize-trace.py FILE [CSV]
"""
import sys
from perfetto.trace_processor import TraceProcessor

APP = "com.powos.app"
HOME = "HomeShell"


def q(tp, sql):
    return list(tp.query(sql))


def main(path, csv=None):
    tp = TraceProcessor(trace=path)
    app = q(tp, f"select upid from process where name = '{APP}' order by upid desc limit 1")
    sf = q(tp, "select upid from process where name like '%surfaceflinger' order by upid desc limit 1")
    if not app or not sf:
        print("verdict: none (no", APP if not app else "surfaceflinger", "in the trace)")
        return
    au, su = app[0].upid, sf[0].upid
    home = q(tp, f"""select a.ts, a.dur, a.jank_type j, a.present_type p, a.on_time_finish o, a.display_frame_token t,
        a.layer_name l from actual_frame_timeline_slice a where a.upid = {au} and a.layer_name like '%{HOME}%' order by a.ts""")
    disp = {r.t: r for r in q(tp, f"""select a.display_frame_token t, a.jank_type j, a.gpu_composition g, a.ts, a.dur
        from actual_frame_timeline_slice a where a.upid = {su}""")}
    if not home:
        print("verdict: none (no home surface frames in the trace)")
        return
    t0, t1 = home[0].ts, home[-1].ts + home[-1].dur
    kinds, dkinds, late = {}, {}, 0
    rows = []
    for r in home:
        d = disp.get(r.t)
        j = r.j or "None"
        kinds[j] = kinds.get(j, 0) + 1
        if r.p and r.p != "On-time Present":
            late += 1
        rows.append((r.ts / 1e6, r.dur / 1e6, j, r.p, r.o, d.j if d else "", d.g if d else ""))
    span = [d for d in disp.values() if t0 <= d.ts <= t1]
    gpu = sum(1 for d in span if d.g)
    for d in span:
        dkinds[d.j or "None"] = dkinds.get(d.j or "None", 0) + 1
    print(f"home {home[0].l[:60]}: {len(home)} surface frames, {late} not on time, jank {kinds}")
    print(f"SF display frames over the drag: {len(span)}, GPU-composited {gpu}, jank {dkinds}")

    def has(k, s):
        return sum(v for n, v in k.items() if s in n)

    app_late = has(kinds, "App Deadline Missed")
    sf_gpu, sf_cpu = has(kinds, "SurfaceFlinger GPU") + has(dkinds, "SurfaceFlinger GPU"), has(kinds, "SurfaceFlinger CPU") + has(dkinds, "SurfaceFlinger CPU")
    hal, stuff = has(dkinds, "Display HAL") + has(kinds, "Display HAL"), has(kinds, "Buffer Stuffing")
    sf_behind = has(dkinds, "SurfaceFlinger Stuffing")
    # Buffer Stuffing (the shell queued ahead of what SF took) and SurfaceFlinger Stuffing (SF's previous frame late)
    # are consequences, never a source: they point at whoever is behind, so they only break a tie.
    score = {"shell": app_late, "surfaceflinger-gpu": sf_gpu, "surfaceflinger-cpu": sf_cpu, "display-hal": hal}
    top = max(score, key=score.get)
    print(f"verdict: {top if score[top] else 'none'} ({', '.join(f'{k} {v}' for k, v in score.items())}; consequences: buffer-stuffing {stuff}, sf-stuffing {sf_behind}; SF GPU-composited {gpu}/{len(span)})")

    for who, cond in (("SF main", f"t.upid = {su} and t.is_main_thread = 1"), ("SF RenderEngine", f"t.upid = {su} and t.name like '%RenderEngine%'"),
                      ("home main", f"t.upid = {au} and t.is_main_thread = 1"), ("home RenderThread", f"t.upid = {au} and t.name = 'RenderThread'")):
        sl = q(tp, f"""select s.name n, count(*) c, sum(s.dur) d, max(s.dur) m from slice s join thread_track tt on s.track_id = tt.id
            join thread t using(utid) where {cond} and s.ts between {t0} and {t1} and s.dur >= 4000000 group by s.name order by d desc limit 6""")
        if sl:
            print(f"{who} slices >= 4 ms: " + "; ".join(f"{r.n[:48]} {r.c}x max {r.m / 1e6:.1f}" for r in sl))
    cpu = q(tp, f"""select coalesce(p.name, t.name) n, sum(min(ss.ts + ss.dur, {t1}) - max(ss.ts, {t0})) d from sched ss join thread t using(utid)
        left join process p using(upid) where ss.ts < {t1} and ss.ts + ss.dur > {t0} and t.utid != 0 group by n order by d desc limit 8""")
    if cpu:
        print(f"CPU over the drag ({(t1 - t0) / 1e6:.0f} ms): " + ", ".join(f"{(r.n or '?')[:28]} {r.d / 1e6:.0f}" for r in cpu))
    if csv:
        with open(csv, "w") as f:
            f.write("ts_ms,dur_ms,jank,present,on_time,display_jank,display_gpu\n")
            for r in rows:
                f.write(",".join(str(x) for x in r) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
