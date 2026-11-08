#!/usr/bin/env python3
# lanes: phone
"""bf-layers.py <OUT> <mode>...: (Mac; bf-pacing.sh runs it last) the per-layer rate table of a game's frame path, one
line per mode, from what bf-pacing.sh collected in OUT/<mode>/ (games-120, docs/research/broforce-fps.md "Toward 120"):

  layers <mode>: game <presents/s> > xwayland <commits/s> (cb <frame callbacks/s>, timeouts <n/s>) > kwin <drawn/s>
    (commit->drawn p50/p90 ms) > consumer <queued/s> (free-buffer wait p50/p90, producer wait p50 ms) > sf <latched/s>
    > panel <Hz> (render <lo-hi>[, render cap <fps> <source>]) ; skin <start>-><end> C

Every stage at once, so the one that caps the frame rate is the first whose rate drops. A stage with no data says "?".
Inputs: kgsl.txt (Xwayland's 30 s lines: Present flips/copies = the game's presents, surface commits, frame callbacks,
timeouts), kwin.txt (window task "frames:" 5 s lines), consumer.txt (the consumer's "pacing:" 5 s lines, logcat),
A<n>.txt (SurfaceFlinger actual present times of each layer; the layer with the most = the game's), displays.txt
(SurfaceFlinger --displays: the ON display's activeMode and render range), vrr.txt (ColorOS's CVT render cap),
prof.txt (skin).
"""
import os
import re
import statistics
import sys


def read(md, name):
    try:
        with open(os.path.join(md, name), errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def mean(xs):
    return statistics.mean(xs) if xs else None


def fmt(v, nd=1):
    return "?" if v is None else f"{v:.{nd}f}"


MARK = "== measuring"


def measured(t):
    """The lines after bf-pacing's measurement-start mark, and whether there was one. Xwayland's 30 s lines and KWin's 5 s
    lines are written only while something happens: a stall in the window leaves none there, and the lines before it
    must not stand in for it (11-08 02:02: "game 37 > xwayland 38" from before the stall, KWin 0 commits - read as the
    web window's consumer starving). Files without the mark (older runs, the tests' fixtures): all of it."""
    if MARK not in t:
        return t, False
    return t.split(MARK, 1)[1], True


def xwayland(md):
    t, mark = measured(read(md, "kgsl.txt"))
    if mark and "Xwayland KGSL" not in t:
        return 0.0, 0.0, 0.0, 0.0  # nothing in the window: Xwayland got no presents and made no commits
    flips = [int(a) + int(b) for a, b in re.findall(r"(\d+) Present flips, (\d+) copies", t)]
    commits = [int(x) for x in re.findall(r"(\d+) surface commits", t)]
    cbs = [int(x) for x in re.findall(r"frame callbacks (\d+)", t)]
    tos = [int(x) for x in re.findall(r"frame timeouts (\d+)", t)]
    per = lambda xs: None if not xs else mean(xs[-2:]) / 30.0  # the last two 30 s lines: the measured window
    return per(flips), per(commits), per(cbs), per(tos)


def kwin(md):
    t, mark = measured(read(md, "kwin.txt"))
    rows = re.findall(r"frames: last 5 s (\d+) commits, (\d+) drawn .*?median (\d+) ms, p90 (\d+) ms", t)[-6:]
    if not rows:
        return (0.0, None, None) if mark else (None, None, None)
    return mean([int(r[1]) / 5.0 for r in rows]), mean([int(r[2]) for r in rows]), mean([int(r[3]) for r in rows])


def consumer(md):
    t = read(md, "consumer.txt")
    rows = re.findall(r"\(([\d.]+)/s\), (\d+) bufs; free-buffer wait p50 (\d+) p90 (\d+) max (\d+) ms \((\d+) dequeue "
                      r"timeouts\).*?producer wait p50 (\d+)", t)[-6:]
    if not rows:
        return None
    return {"rate": mean([float(r[0]) for r in rows]), "bufs": rows[-1][1], "dq50": mean([int(r[2]) for r in rows]),
            "dq90": mean([int(r[3]) for r in rows]), "to": sum(int(r[5]) for r in rows) / (5.0 * len(rows)),
            "pr50": mean([int(r[6]) for r in rows])}


def sf(md):
    best = None
    for f in os.listdir(md):
        if re.fullmatch(r"A\d+\.txt", f):
            ts = sorted({int(x) for x in read(md, f).split() if x.isdigit()})
            if len(ts) > 1 and (best is None or len(ts) > len(best)):
                best = ts
    if not best:
        return None
    span = (best[-1] - best[0]) / 1e9
    return (len(best) - 1) / span if span > 0 else None


def panel(md):
    t = read(md, "displays.txt")
    # Per display block: powerMode=On ... activeMode={... vsyncRate=X Hz ...} ... render=[lo Hz, hi Hz]
    out = []
    for blk in re.split(r"\n(?=(?:Pacesetter )?Display \d+)", t):
        if "powerMode=On" not in blk:
            continue
        m = re.search(r"activeMode=\{[^}]*vsyncRate=([\d.]+) Hz", blk)
        r = re.search(r"primaryRanges=\{physical=\[[^]]*\], render=\[([\d.]+) Hz, ([\d.]+) Hz\]", blk)
        if m:
            out.append((float(m.group(1)), r and f"{float(r.group(1)):.0f}-{float(r.group(2)):.0f}"))
    return out[0] if out else (None, None)


def cvt(md):
    """ColorOS's render-rate cap (vrr.txt, `dumpsys SurfaceFlinger --oplus vrr`): "CVT: ... CurrentRate: [60, oti-adfr]"
    = SurfaceFlinger wakes at 60 under a 120 Hz panel (touch idle). None: no cap (rate 0) or no data."""
    m = re.search(r"^CVT:\s*\n(?:.*\n)*?\s*CurrentRate: \[(\d+), ([^\]]*)\]", read(md, "vrr.txt"), re.M)
    return f"{m.group(1)} {m.group(2)}" if m and int(m.group(1)) > 0 else None


def skin(md):
    m = re.search(r"^skin ([\d.]+) ([\d.]+)", read(md, "prof.txt"), re.M)
    return f"{m.group(1)}->{m.group(2)} C" if m else "? C"


def line(out, mode):
    md = os.path.join(out, mode)
    g, xc, cb, to = xwayland(md)
    kd, k50, k90 = kwin(md)
    c = consumer(md)
    hz, rr = panel(md)
    cs = "?" if not c else (f"{fmt(c['rate'])} ({c['bufs']} bufs, free-buffer wait p50 {fmt(c['dq50'], 0)} p90 "
                            f"{fmt(c['dq90'], 0)} ms, {fmt(c['to'])} timeouts/s, producer wait p50 {fmt(c['pr50'], 0)} ms)")
    return (f"layers {mode}: game {fmt(g)} > xwayland {fmt(xc)} (cb {fmt(cb)}, timeouts {fmt(to)}/s) > kwin {fmt(kd)} "
            f"(commit->drawn p50 {fmt(k50, 0)} p90 {fmt(k90, 0)} ms) > consumer {cs} > sf {fmt(sf(md))} > panel "
            f"{fmt(hz, 0)} Hz (render {rr or '?'}{', render cap ' + cvt(md) if cvt(md) else ''}) ; skin {skin(md)}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    for mode in sys.argv[2:]:
        if os.path.isdir(os.path.join(sys.argv[1], mode)):
            print(line(sys.argv[1], mode))
