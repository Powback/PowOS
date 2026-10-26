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
Prints one line per mode; the last line is the summary for the board."""
import os, re, subprocess, sys
import numpy as np

FF = ["docker", "run", "--rm", "-v", "{d}:/w", "-w", "/w", "--entrypoint", "{e}", "linuxserver/ffmpeg:latest"]


def ff(d, exe, *args):
    return subprocess.run([a.format(d=d, e=exe) for a in FF] + list(args), capture_output=True, text=True).stdout


def presents(md):
    best, period = None, None
    for f in sorted(os.listdir(md)):
        if not (f.startswith("L") and f.endswith(".txt")):
            continue
        ts, p = set(), None
        for line in open(os.path.join(md, f)):
            if line.startswith("P"):
                p = int(line.split()[1])
            elif line.strip():
                ts.add(int(line))
        if best is None or len(ts) > len(best):
            best, period = ts, p
    if not best or len(best) < 10:
        return None
    t = np.array(sorted(best), dtype=np.int64)
    d = np.diff(t) / 1e6
    pc = lambda q: np.percentile(d, q)
    return dict(n=len(d), fps=len(d) / ((t[-1] - t[0]) / 1e9), p50=pc(50), p95=pc(95), p99=pc(99), max=d.max(),
                at60=100 * ((d > 14.7) & (d < 18.7)).mean(), short=100 * (d < 12).mean(), long=100 * (d > 25).mean(),
                vsync=(period or 0) / 1e6)


def stale(md):
    mp4 = os.path.join(md, "rec.mp4")
    if not os.path.exists(mp4):
        return None
    wh = ff(md, "ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height", "-of",
            "csv=p=0", "rec.mp4").strip().split(",")
    w, h = int(wh[0]) // 16 * 2, int(wh[1]) // 16 * 2
    ff(md, "ffmpeg", "-v", "error", "-y", "-i", "rec.mp4", "-vf", "scale=%d:%d,format=gray" % (w, h), "-fps_mode",
       "passthrough", "-f", "rawvideo", "rec.gray")
    g = os.path.join(md, "rec.gray")
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
    pts = [float(x) for x in ff(md, "ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                "-of", "csv=p=0", "rec.mp4").split() if x.strip()]
    return dict(frames=len(f), dup=dup, back=back, secs=(pts[-1] - pts[0]) if len(pts) > 1 else 0)


def xwl(md):
    """Xwayland's last KGSL line of the run (kgsl.txt): its commits and how many went out past a frame callback that
    never came - the frame callbacks KWin sends after each frame it draws of the window (a task drawn = none forced)."""
    f = os.path.join(md, "kgsl.txt")
    lines = [l for l in open(f)] if os.path.exists(f) else []
    m = re.search(r"last (\d+)s: (\d+) commits \((\d+) forced", lines[-1]) if lines else None
    return "xwl %s commits/%ss, %s forced" % (m.group(2), m.group(1), m.group(3)) if m else None


def main():
    d, modes, out = sys.argv[1], sys.argv[2:], []
    for m in modes:
        md = os.path.join(d, m)
        win = " ".join(open(os.path.join(md, "window.txt")).read().split()) if os.path.exists(os.path.join(md, "window.txt")) else "?"
        p, s = presents(md), stale(md)
        line = "%s [%s]:" % (m, win)
        if p:
            line += (" %(fps).1f fps, frame ms p50 %(p50).1f p95 %(p95).1f p99 %(p99).1f max %(max).0f, %(at60).0f%% at 16.7"
                     " (%(short).0f%% <12, %(long).1f%% >25; n=%(n)d, vsync %(vsync).2f)" % p)
        else:
            line += " no presents"
        if s:
            line += ", rec %(frames)d fr/%(secs).0fs: dup %(dup)d, stale-back %(back)d" % s
        x = xwl(md)
        if x:
            line += ", " + x
        print(line)
        out.append(line)
    print(" | ".join(out))


if __name__ == "__main__":
    main()
