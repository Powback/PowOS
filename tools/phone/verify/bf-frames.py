#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""bf-frames.py <dir> <mode>...: (Mac) frame pacing + stale frames of a bf-pacing.sh run. Per <dir>/<mode>/:
  L<n>.txt (bf-present.sh: SurfaceFlinger present times, ns) - the layer with the most presents = the game's surface:
    fps, frame-time percentiles, % of frames at one 60 Hz period (14.7-18.7 ms), % short (<12 ms), % long (>25 ms).
  kgsl.txt (the session log's "Xwayland KGSL" lines) - commits per 30 s and how many were forced (no frame callback).
  rec.mp4 (screenrecord) - every composited frame, downscaled 8x to grey: dup = same as the previous frame,
    stale = a frame that goes BACK to one of the 2-4 frames before it (the "jittering back and forth" bug).
Prints one line per mode; the last line is the summary for the board. PASS (exit 0) only when every mode has the
GAME's presents (>= MIN_PRESENTS on a layer that can carry its buffers); else the summary starts "FAIL" and exit 1.
The 2026-11-05 02:45 base run PASSed on "no presents" - it had measured leftover leash layers, not the game."""
import os, re, subprocess, sys

# The game's surface: KWin's window task draws into the task's BLAST SurfaceView. These never carry its buffers:
# containers, leftover start-animation leashes of earlier tasks, the SurfaceView's bounds/background layers.
NOT_GAME = re.compile(r"animation-leash|^Bounds for|^Background for|ActivityRecord|InputSink|Gesture Monitor")
MIN_PRESENTS = 30  # 30 s of measuring: under 1 fps is no game on the screen

# The mode's dir (env:K=V,...) has ':' and ',' in its name, which docker's -v / --mount can't take (02:48: ffprobe
# saw no file, printed nothing, int('') threw): mount the run dir (bfp-<date>) and name the mode's files from it.
FF = ["docker", "run", "--rm", "-v", "{d}:/w", "-w", "/w", "--entrypoint", "{e}", "linuxserver/ffmpeg:latest"]


def ff(d, exe, *args):
    return subprocess.run([a.format(d=d, e=exe) for a in FF] + list(args), capture_output=True, text=True).stdout


def pct(v, q):
    """numpy.percentile's default (linear) on a sorted list - no numpy for the parser (tier1 has none)."""
    k = (len(v) - 1) * q / 100.0
    i = int(k)
    return v[i] if i + 1 >= len(v) else v[i] + (v[i + 1] - v[i]) * (k - i)


def presents(md):
    """The game layer's present stats, or None. Layer n of <md>/layers = L<n>.txt; only names that can be the game."""
    lp = os.path.join(md, "layers")
    names = [l.rstrip("\n") for l in open(lp)] if os.path.exists(lp) else []
    best, period, name = None, None, None
    for f in sorted(os.listdir(md)):
        m = re.fullmatch(r"L(\d+)\.txt", f)
        if not m:
            continue
        nm = names[int(m.group(1)) - 1] if int(m.group(1)) <= len(names) else "?"
        if NOT_GAME.search(nm):
            continue
        ts, p = set(), None
        for line in open(os.path.join(md, f)):
            if line.startswith("P"):
                p = int(line.split()[1])
            elif line.strip():
                ts.add(int(line))
        if best is None or len(ts) > len(best):
            best, period, name = ts, p, nm
    if not best or len(best) < MIN_PRESENTS:
        return None
    t = sorted(best)
    d = sorted((b - a) / 1e6 for a, b in zip(t, t[1:]))
    frac = lambda ok: 100.0 * sum(1 for x in d if ok(x)) / len(d)
    return dict(n=len(d), fps=len(d) / ((t[-1] - t[0]) / 1e9), p50=pct(d, 50), p95=pct(d, 95), p99=pct(d, 99),
                max=d[-1], at60=frac(lambda x: 14.7 < x < 18.7), short=frac(lambda x: x < 12),
                long=frac(lambda x: x > 25), vsync=(period or 0) / 1e6, layer=re.sub(r"#\d+$", "", name))


def stale(d, mode):
    """Dup / stale-back frames of <d>/<mode>/rec.mp4, None without one; dict(err=...) when ffmpeg can't read it."""
    md = os.path.join(d, mode)
    if not os.path.exists(os.path.join(md, "rec.mp4")):
        return None
    import numpy as np
    rec, gray = "./%s/rec.mp4" % mode, "./%s/rec.gray" % mode  # ./ : ffmpeg would read "env:" as a protocol
    wh = ff(d, "ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height", "-of",
            "csv=p=0", rec).strip().split(",")
    if len(wh) < 2 or not (wh[0].isdigit() and wh[1].isdigit()):
        return dict(err="ffprobe read no size from rec.mp4 (%r)" % ",".join(wh))
    w, h = int(wh[0]) // 16 * 2, int(wh[1]) // 16 * 2
    ff(d, "ffmpeg", "-v", "error", "-y", "-i", rec, "-vf", "scale=%d:%d,format=gray" % (w, h), "-fps_mode",
       "passthrough", "-f", "rawvideo", gray)
    g = os.path.join(md, "rec.gray")
    if not os.path.exists(g):
        return dict(err="ffmpeg decoded nothing from rec.mp4")
    f = np.fromfile(g, np.uint8)
    os.remove(g)
    f = f[: len(f) // (w * h) * w * h].reshape(-1, h, w).astype(np.int16)
    if len(f) < 6:
        return None
    dist = lambda a, b: float(np.abs(f[a] - f[b]).mean())
    dup = back = 0
    for n in range(1, len(f)):
        d1 = dist(n, n - 1)
        if d1 < 0.3:
            dup += 1
        elif d1 > 1.0 and n >= 4 and min(dist(n, n - k) for k in (2, 3, 4)) < 0.35 * d1:
            back += 1
    pts = [float(x) for x in ff(d, "ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                "-of", "csv=p=0", rec).split() if x.strip()]
    return dict(frames=len(f), dup=dup, back=back, secs=(pts[-1] - pts[0]) if len(pts) > 1 else 0)


def xwl(md):
    """Xwayland's last KGSL line of the run (kgsl.txt): its commits and how many went out past a frame callback that
    never came - the frame callbacks KWin sends after each frame it draws of the window (a task drawn = none forced)."""
    f = os.path.join(md, "kgsl.txt")
    lines = [l for l in open(f)] if os.path.exists(f) else []
    m = re.search(r"last (\d+)s: (\d+) commits \((\d+) forced", lines[-1]) if lines else None
    return "xwl %s commits/%ss, %s forced" % (m.group(2), m.group(1), m.group(3)) if m else None


def line_for(d, m, rec=True):
    """(board line of mode m, has the game's presents)."""
    md = os.path.join(d, m)
    wf = os.path.join(md, "window.txt")
    win = " ".join(open(wf).read().split()) if os.path.exists(wf) else "?"
    p = presents(md)
    s = stale(d, m) if rec else None
    line = "%s [%s]:" % (m, win)
    if p:
        line += (" %(fps).1f fps, frame ms p50 %(p50).1f p95 %(p95).1f p99 %(p99).1f max %(max).0f, %(at60).0f%% at 16.7"
                 " (%(short).0f%% <12, %(long).1f%% >25; n=%(n)d, vsync %(vsync).2f; %(layer)s)" % p)
    else:
        line += " no game presents (no layer that can be the game had >= %d)" % MIN_PRESENTS
    if s and "err" in s:
        line += ", rec: " + s["err"]
    elif s:
        line += ", rec %(frames)d fr/%(secs).0fs: dup %(dup)d, stale-back %(back)d" % s
    x = xwl(md)
    if x:
        line += ", " + x
    return line, bool(p)


def main():
    d, modes, out, bad = sys.argv[1], sys.argv[2:], [], []
    for m in modes:
        line, ok = line_for(d, m)
        print(line)
        out.append(line)
        if not ok:
            bad.append(m)
    summary = " | ".join(out)
    if bad:
        print("FAIL no game presents in %s: %s" % (" ".join(bad), summary))
        sys.exit(1)
    print(summary)


if __name__ == "__main__":
    main()
