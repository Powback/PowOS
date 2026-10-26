#!/usr/bin/env python3
"""bf-checker.py <dir> <variant>...: (Mac) black-checkerboard score of a bf-checker.sh run. Per <dir>/<variant>/:
  h*.png / f*.png = Xwayland's copy of the game window (x11grab, half-res nearest / full-res), s*.png = the screen
  (shot.sh), L*.txt = SurfaceFlinger present times on the menu (bf-present.sh) -> fps.
Checker score of a frame: b = luma < 16; for a cell size k in 1..32, the share of pixels where b[y,x] and b[y+k,x+k]
are black but b[y,x+k] and b[y+k,x] are not (a black checker of cell k), x2 = the share of the frame it covers. The
frame's score = the best k. A variant's score = its worst frame (x = X copy, s = screen). A variant FIXES it when
both are < max(0.5 %, base / 10). Last line = the board result; exit 0 only when base itself is clean (< 0.5 %)."""
import importlib.util, os, subprocess, sys
import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bf_frames", os.path.join(here, "bf-frames.py"))
bff = importlib.util.module_from_spec(spec); spec.loader.exec_module(bff)
KS = (1, 2, 4, 8, 16, 32)
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


def score(g):
    b = g < 16
    best = (0.0, 0)
    for k in KS:
        if g.shape[0] <= k or g.shape[1] <= k:
            continue
        s = 200.0 * (b[:-k, :-k] & b[k:, k:] & ~b[:-k, k:] & ~b[k:, :-k]).mean()
        best = max(best, (s, k))
    return best[0], best[1], 100.0 * b.mean()


def main():
    d, vs = sys.argv[1], sys.argv[2:]
    res, lines = {}, []
    for v in vs:
        md = os.path.join(d, v)
        if not os.path.isdir(md):
            continue
        fr = decode(md)
        x = [(score(g), f) for f, g in fr.items() if f[0] in "hf"]
        s = [(score(g), f) for f, g in fr.items() if f[0] == "s"]
        wx = max(x) if x else ((0, 0, 0), "-")
        ws = max(s) if s else ((0, 0, 0), "-")
        p = bff.presents(md)
        fps = "%.1f fps (p95 %.1f ms)" % (p["fps"], p["p95"]) if p else "no fps"
        # frames over 0.5 %: how long it shows
        nbad = sum(1 for (sc, _, _), _ in x if sc >= 0.5)
        res[v] = max(wx[0][0], ws[0][0])
        line = ("%s: X %.2f%% (k%d, %s; %d/%d frames >0.5%%) screen %.2f%% (k%d, %s; %d shots), %s"
                % (v, wx[0][0], wx[0][1], wx[1], nbad, len(x), ws[0][0], ws[0][1], ws[1], len(s), fps))
        print(line)
        lines.append("%s X%.2f/S%.2f%s" % (v, wx[0][0], ws[0][0], " %.0ffps" % p["fps"] if p else ""))
    base = res.get("base")
    if base is None:
        print("no base run"); sys.exit(2)
    lim = max(0.5, base / 10)
    fixed = [v for v, r in res.items() if v != "base" and r < lim]
    summary = "checker base %.2f%%; %s" % (base, "clean - nothing to fix" if base < 0.5 else
                                            "fixed by: " + (", ".join(fixed) or "none"))
    print(" | ".join(lines) + " | " + summary)
    sys.exit(0 if base < 0.5 else 1)


main()
