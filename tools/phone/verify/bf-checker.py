#!/usr/bin/env python3
"""bf-checker.py <dir> <variant>...: (Mac) black-checkerboard score of a bf-checker.sh run. Per <dir>/<variant>/:
  h*.png / f*.png = Xwayland's copy of the game window (x11grab, half-res nearest / full-res), s*.png = the screen
  (shot.sh), L*.txt = SurfaceFlinger present times on the menu (bf-present.sh) -> fps.
Checker score of a frame (dashes, per 10k px): the artefact is short black dashes (2-16 px wide at full res, 2-row
steps) inside bright areas, in 16-px columns: a black run of <= 16 px (8 at half res) bounded left and right by bright
pixels (luma > 110) with a bright pixel 2 rows (1 at half res) above or below its start, weighted by run length. Clean
frames score ~0-3 (pixel-art outlines), checkered ones 30-800; a frame is checkered at > 20. A variant's score = the
share of its frames that are checkered (x = X copy h*/f*, s = screen). A variant FIXES it when both shares are <=
max(0, base / 10) and its frames are not all black. Last line = the board result; exit 0 only when base itself is clean.
The old score (a black 2x2 checker of cell 1..32 px) fired on the menu's sunburst and called every variant 6-8 %
(clean or not) - it hid that TU_DEBUG=noubwc removes the dashes (2026-11-04, docs/research/broforce-black-columns.md).
"""
import importlib.util, os, subprocess, sys
import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bf_frames", os.path.join(here, "bf-frames.py"))
bff = importlib.util.module_from_spec(spec); spec.loader.exec_module(bff)
DECODE = r'''for f in *.png; do [ -e "$f" ] || continue
  d=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$f")
  ffmpeg -v error -y -i "$f" -f rawvideo -pix_fmt gray "${f%.png}.gray" && echo "$f $d" >> dims.txt; done'''


def decode(md):
    if os.path.exists(os.path.join(md, "dims.txt")):
        os.remove(os.path.join(md, "dims.txt"))
    subprocess.run(["docker", "run", "--rm", "-v", md + ":/w", "-w", "/w", "--entrypoint", "sh",
                    "linuxserver/ffmpeg:latest", "-c", DECODE], capture_output=True)
    out = {}
    for line in open(os.path.join(md, "dims.txt")) if os.path.exists(os.path.join(md, "dims.txt")) else []:
        f, wh = line.split()
        w, h = map(int, wh.split(","))
        g = os.path.join(md, f[:-4] + ".gray")
        a = np.fromfile(g, np.uint8); os.remove(g)
        if a.size == w * h:
            out[f] = a.reshape(h, w)
    return out


DASH = 20.0  # dash score above which a frame is checkered


def score(g, half=False):
    """(dash score per 10k px, max run checked, % black)."""
    g = g.astype(np.int16)
    b, br = g < 20, g > 110
    h, w = g.shape
    maxr, dv = (8, 1) if half else (16, 2)
    n = 0
    for r in range(1, maxr + 1):
        if w <= r + 1 or h <= dv:
            break
        m = br[:, :w - r - 1] & br[:, r + 1:]
        for k in range(1, r + 1):
            m = m & b[:, k:w - r - 1 + k]
        vb = np.zeros_like(m)
        vb[dv:] |= br[:-dv, 1:w - r]
        vb[:-dv] |= br[dv:, 1:w - r]
        n += int((m & vb).sum()) * r
    return 1e4 * n / g.size, maxr, 100.0 * b.mean()


def frame_times(xd):
    """h<n>.png -> seconds of the day: grab.log stamps every 10th frame ("<n//10+1> HH:MM:SS ..."); the grab is 1 fps."""
    stamps, log = {}, os.path.join(xd, "grab.log")
    for line in open(log) if os.path.exists(log) else []:
        p = line.split()
        if len(p) > 1 and p[0].isdigit():
            h, m, s = map(int, p[1].split(":"))
            stamps[int(p[0]) - 1] = h * 3600 + m * 60 + s
    return lambda n: (stamps[n // 10] + n % 10) if n // 10 in stamps else None


def frames(xd, timeline):
    """--frames <x dir> <timeline.txt> (bf-overlay-watch.sh): each X frame's checker score, and whether an overlay
    was up within 1 s of it (timeline lines "HH:MM:SS overlay=<layers|none> ...")."""
    up = {}
    for line in open(timeline):
        p = line.split()
        if len(p) > 1 and p[1].startswith("overlay="):
            h, m, s = map(int, p[0].split(":"))
            up[h * 3600 + m * 60 + s] = p[1] != "overlay=none"
    at, rows = frame_times(xd), []
    for f, g in sorted(decode(xd).items()):
        if f[0] != "h":
            continue
        t = at(int(f[1:-4]))
        near = [up[u] for u in (t - 1, t, t + 1) if u in up] if t is not None else []
        rows.append((f, score(g, True)[0], any(near) if near else None))
        print("%s dash %.1f overlay=%s" % (f, rows[-1][1], {True: "up", False: "none", None: "?"}[rows[-1][2]]))
    on = [r for r in rows if r[2]]
    off = [r for r in rows if not r[2]]
    print("X frames %d: overlay up %d (checkered: %d), no overlay %d (checkered %d)"
          % (len(rows), len(on), sum(r[1] > DASH for r in on), len(off), sum(r[1] > DASH for r in off)))


def main():
    if sys.argv[1:2] == ["--frames"]:
        frames(sys.argv[2], sys.argv[3])
        return
    d, vs = sys.argv[1], sys.argv[2:]
    res, lines = {}, []
    for v in vs:
        md = os.path.join(d, v)
        if not os.path.isdir(md):
            continue
        fr = decode(md)
        if not fr:
            print("%s: no frames decoded (docker/ffmpeg?)" % v); continue
        x = [(score(g, f[0] == "h"), f) for f, g in fr.items() if f[0] in "hf"]
        s = [(score(g), f) for f, g in fr.items() if f[0] == "s"]
        bx = [f for (sc, _, _), f in x if sc > DASH]
        bs = [f for (sc, _, _), f in s if sc > DASH]
        px = 100.0 * len(bx) / len(x) if x else 0.0
        ps = 100.0 * len(bs) / len(s) if s else 0.0
        black = all(bl > 99 for (_, _, bl), _ in x + s)  # nothing drawn at all is not "fixed"
        p = bff.presents(md)
        fps = "%.1f fps (p95 %.1f ms)" % (p["fps"], p["p95"]) if p else "no fps"
        wx = max(x) if x else ((0, 0, 0), "-")
        res[v] = (max(px, ps), black)
        line = ("%s: X %d/%d frames checkered (%.0f%%, worst %s dash %.0f) screen %d/%d (%.0f%%)%s, %s"
                % (v, len(bx), len(x), px, wx[1], wx[0][0], len(bs), len(s), ps, " ALL BLACK" if black else "", fps))
        print(line)
        lines.append("%s X%.0f%%/S%.0f%%%s" % (v, px, ps, " %.0ffps" % p["fps"] if p else ""))
    base = res.get("base", (None, False))[0]
    if base is None:
        print(" | ".join(lines) + " | no base run"); sys.exit(2)
    fixed = [v for v, (r, black) in res.items() if v != "base" and r <= base / 10 and not black]
    summary = "checkered frames base %.0f%%; %s" % (base, "clean - nothing to fix" if base == 0 else
                                                    "fixed by: " + (", ".join(fixed) or "none"))
    print(" | ".join(lines) + " | " + summary)
    sys.exit(0 if base == 0 else 1)

main()
