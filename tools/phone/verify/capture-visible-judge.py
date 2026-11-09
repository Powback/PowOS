#!/usr/bin/env python3
"""capture-visible-judge.py RAW [SF_DUMP]: is a raw `screencap -d <id>` (no -p) of home near-black?

RAW: Android's raw screencap - a 16-byte header (u32 width, height, format, colorspace; 12 bytes before Android 12),
then RGBA_8888 rows. The status bar and the navigation bar are left out (top/bottom 7 %): on 11-09 home captures were
black apart from them. A pixel is lit when any channel is over 24; fewer than 1 % lit pixels is near-black.

SF_DUMP (optional, `dumpsys SurfaceFlinger` text): the HWC layers of the display; a SOLID_COLOR layer that covers the
whole display is named as the likely cover (11-09: a stopped window task's leash, shown uncropped - WM Shell's black
task colour over home).

Prints one line `lit=<pct> dark=<0|1> WxH` and, if found, `cover=<layer>` lines. Exit 0 lit, 1 near-black, 2 bad input.
"""
import re
import struct
import sys

LIT_MIN = 24
LIT_PCT_MIN = 1.0


def lit_pct(data: bytes):
    if len(data) < 16:
        return None
    w, h, fmt = struct.unpack_from("<III", data, 0)
    if fmt != 1 or w == 0 or h == 0:
        return None
    for head in (16, 12):
        if len(data) - head >= w * h * 4:
            break
    else:
        return None
    y0, y1 = int(h * 0.07), int(h * 0.93)
    lit = n = 0
    for y in range(y0, y1, 6):
        row = head + y * w * 4
        for x in range(0, w, 6):
            o = row + x * 4
            n += 1
            if data[o] > LIT_MIN or data[o + 1] > LIT_MIN or data[o + 2] > LIT_MIN:
                lit += 1
    return w, h, 100.0 * lit / max(n, 1)


def covers(sf: str, w: int, h: int):
    """SOLID_COLOR HWC layers spanning the whole w x h display."""
    out = []
    name = None
    for line in sf.splitlines():
        s = line.strip()
        if not s or s.startswith("---") or s.startswith("Layer name"):
            continue
        if "|" not in s:
            name = s
            continue
        cols = [c.strip() for c in s.split("|")]
        if len(cols) > 5 and cols[3] == "SOLID_COLOR" and name:
            m = re.match(r"(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)", cols[5])
            if m:
                l, t, r, b = map(int, m.groups())
                if l <= 0 and t <= 0 and r >= w and b >= h:
                    out.append(name)
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[0])
        return 2
    with open(argv[1], "rb") as f:
        r = lit_pct(f.read())
    if r is None:
        print("bad raw capture")
        return 2
    w, h, pct = r
    dark = pct < LIT_PCT_MIN
    print(f"lit={pct:.2f} dark={int(dark)} {w}x{h}")
    if len(argv) > 2:
        with open(argv[2], encoding="utf-8", errors="replace") as f:
            for c in covers(f.read(), w, h):
                print(f"cover={c}")
    return 1 if dark else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
