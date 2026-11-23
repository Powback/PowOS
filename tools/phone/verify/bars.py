#!/usr/bin/env python3
"""bars.py [--mid] <png>...: (Mac) the black bars at each edge of a screencap - "top=N bottom=N left=N right=N" per file
(game-resize.sh G3 / bf-resize.sh, bf-fold.sh's notes: a letterbox / pillarbox = bars on BOTH opposite edges,
game-resize.sh boxed()). The full side when nothing is lit (a wholly black frame: G3-black-frame).

A bar row (column) is FLAT black: pure black (grey 0) except at most OVERLAY_FRAC (0.40) of its pixels - PowOS's own
overlays drawn over a real bar (status bar clock/icons + the fps HUD: at most 0.28 of a row in every saved frame,
0.277 at the 1116-wide cover portrait; the pad / keyboard buttons). The screen-edge handle (an 8 px strip 4-11 px in
from the right edge, lit over 31-67 % of the column) is bridged: a lit stretch of < HANDLE lines that starts within
HANDLE lines of the edge, with bar lines after it. Counting stops at the first other non-bar line.

Why (11-19, Besiege 346010 folded-landscape, letterbox-47/66 every run since 11-18 22:00 = false FAIL): the old
bars() called a row black when its average grey was <= 12, and took that average from ffmpeg `scale=1:ih:flags=area`,
which on a 2484-wide row does NOT average the row (that menu's top rows came out 4, their real mean is 19). Besiege's
menu is navy space with stars: 70-80 % of each top row above grey 4. Every real bar in the saved frames (Proton's
fullscreen hack centring a smaller mode; KWin/Android centring a smaller buffer) is exactly 0 under the overlays -
the letterboxes measure symmetric to the row (192/192, 420/420, 198/198) at grey 0 and lopsided at <= 3 (192/212:
a game's near-black art runs on into the bar). So this is stricter than before, not looser: it also finds the real
bars the old average missed (My Friend Pedro 557340 unfolded pillarbox-586/586, 11-18 22:39 and 23:17; Besiege
11-18 23:32 unfolded letterbox-434/434; Broforce cover portrait 11-07 04:39 letterbox-642/641).
Regression: test/tier1/test-game-bars.py (real saved frames, fixtures/game-bars/).
"""
import os
import subprocess
import sys

BLACK = int(os.environ.get("BARS_BLACK", 0))
OVERLAY_FRAC = float(os.environ.get("BARS_OVERLAY_FRAC", 0.40))
HANDLE = 12
_LIT = bytes(1 if v > BLACK else 0 for v in range(256))


def grey(path):
    """(w, h, bytes) - the frame as 8-bit grey, one byte per pixel, row-major."""
    wh = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                  "stream=width,height", "-of", "csv=p=0:s=x", path]).decode().strip()
    w, h = (int(v) for v in wh.split("x")[:2])
    raw = subprocess.check_output(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", path,
                                   "-vf", "format=gray", "-f", "rawvideo", "-"])
    if len(raw) != w * h:
        raise ValueError(f"{path}: {len(raw)} grey bytes for {w}x{h}")
    return w, h, raw


def edges(w, h, raw):
    """{top, bottom, left, right}: bar rows/columns from each edge; the full side when nothing is lit."""
    lit = raw.translate(_LIT)  # 1 per pixel brighter than BLACK

    def run(seq_len, line, order):
        k, n = 0, len(order)
        while k < n:
            if sum(line(order[k])) <= OVERLAY_FRAC * seq_len:
                k += 1
                continue
            # The screen-edge handle (docstring): bridged only right at the edge. A game's own lit line ends the bar.
            j = k
            while j < n and j - k < HANDLE and sum(line(order[j])) > OVERLAY_FRAC * seq_len:
                j += 1
            if k < HANDLE and j < n and j - k < HANDLE and sum(line(order[j])) <= OVERLAY_FRAC * seq_len:
                k = j
                continue
            return k
        return n

    row = lambda y: lit[y * w:(y + 1) * w]
    col = lambda x: lit[x::w]
    return {"top": run(w, row, range(h)), "bottom": run(w, row, range(h - 1, -1, -1)),
            "left": run(h, col, range(w)), "right": run(h, col, range(w - 1, -1, -1))}


def line(path, mid=False):
    w, h, raw = grey(path)
    out = "top=%(top)d bottom=%(bottom)d left=%(left)d right=%(right)d" % edges(w, h, raw)
    if mid:  # bf-fold.sh: the centre row's mean grey (is anything drawn at all)
        out += " mid=%d" % (sum(raw[h // 2 * w:(h // 2 + 1) * w]) // w)
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rc, mid, paths = 0, "--mid" in sys.argv[1:], [a for a in sys.argv[1:] if a != "--mid"]
    for p in paths:
        try:
            print(line(p, mid))
        except (subprocess.CalledProcessError, ValueError) as err:
            print(f"bars: {p}: {err}", file=sys.stderr)
            rc = 1
    sys.exit(rc)
