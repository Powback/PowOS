#!/usr/bin/env python3
"""test-capture-visible-judge.py: capture-visible-judge.py's verdict on raw screencaps (11-09: home captures black but
the status bar). A home with content passes, a black one with only lit status/nav bars fails, and a SOLID_COLOR HWC
layer spanning the display is named as the cover."""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
JUDGE = os.path.join(HERE, "..", "..", "tools", "phone", "verify", "capture-visible-judge.py")
W, H = 120, 260


def raw(lit_rows):
    px = bytearray(W * H * 4)
    for y in lit_rows:
        for x in range(W):
            o = (y * W + x) * 4
            px[o:o + 4] = b"\xc0\xc0\xc0\xff"
    return struct.pack("<IIII", W, H, 1, 0) + bytes(px)


SF = f"""Display 1 (active) HWC layers:
---------------------------------------------------------------------------------------------------------------------------------------------------------------
 Layer name
           Z |  Window Type |  Layer Class | Comp Type |  Transform |   Disp Frame (LTRB) |          Source Crop (LTRB) |     Frame Rate (Explicit) (Seamlessness) [Focused]
---------------------------------------------------------------------------------------------------------------------------------------------------------------
 Task=3191#826
           8 |            0 |            0 | SOLID_COLOR |          0 |    0    0 {W} {H} |    0.0    0.0    0.0    0.0 |                 NoVote           Default    [ ]
---------------------------------------------------------------------------------------------------------------------------------------------------------------
 StatusBar#108
          18 |         2000 |            0 |     DEVICE |          0 |    0    0 {W}  10 |    0.0    0.0 {W}.0   10.0 |        Cat::NoPreference           Default    [ ]
"""


def run(data, sf=None):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "x.raw")
        open(p, "wb").write(data)
        args = [sys.executable, "-I", JUDGE, p]
        if sf is not None:
            s = os.path.join(d, "x.sf")
            open(s, "w").write(sf)
            args.append(s)
        r = subprocess.run(args, capture_output=True, text=True)
        return r.returncode, r.stdout


fails = 0


def case(name, want, got, needle=None):
    global fails
    rc, out = got
    ok = rc == want and (needle is None or needle in out)
    print(f"{'PASS' if ok else 'FAIL'} {name} (rc {rc}: {out.strip()})")
    fails += not ok


case("home-drawn", 0, run(raw(range(40, 200))))
case("black-but-bars", 1, run(raw(list(range(0, 12)) + list(range(250, 260)))))
case("black-names-cover", 1, run(raw(range(0, 12)), SF), "cover=Task=3191#826")
case("bad-input", 2, run(b"\x00" * 8))
sys.exit(1 if fails else 0)
