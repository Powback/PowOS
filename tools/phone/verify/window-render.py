#!/usr/bin/env python3
"""tools/phone/verify/window-render.py: the pixel side of window-render.sh (stdlib only: the Mac has no PIL/numpy).

Shots are `screencap` RAW (RGBA after a 12/16-byte header), gzipped on the phone: no PNG decode needed here.
  window-render.py png SHOT.raw.gz OUT.png [l t r b CROP.png]   a viewable PNG of the shot (and of the body rect)
  window-render.py stats SHOT.raw.gz l t r b                     "dominant=<share> edges=<share> colours=<n>" of the rect
  window-render.py diff A.raw.gz B.raw.gz l t r b                "<share>" of the rect's pixels that differ (any channel > 24)
The rect is device px, sampled every STEP (2) px each way.
"""
import gzip
import struct
import sys
import zlib

STEP = 2
THRESH = 24


def load(path):
    with open(path, "rb") as f:
        blob = f.read()
    # screencap's own warnings ("[Warning] Multiple displays were found...") may come first on its stdout.
    at = blob.find(b"\x1f\x8b")
    if at < 0:
        raise SystemExit(f"window-render.py: {path}: no gzip stream ({blob[:80]!r})")
    data = gzip.decompress(blob[at:])
    w, h = struct.unpack_from("<II", data, 0)
    head = len(data) - w * h * 4
    if head not in (12, 16) or w <= 0 or h <= 0:
        raise SystemExit(f"window-render.py: {path}: not a raw screencap ({len(data)} bytes, {w}x{h})")
    return w, h, memoryview(data)[head:]


def clamp(w, h, l, t, r, b):
    return max(0, l), max(0, t), min(w, r), min(h, b)


def pixels(shot, l, t, r, b):
    w, h, px = shot
    l, t, r, b = clamp(w, h, l, t, r, b)
    for y in range(t, b, STEP):
        row = px[(y * w) * 4:(y * w + w) * 4]
        yield [tuple(row[x * 4:x * 4 + 3]) for x in range(l, r, STEP)]


def stats(shot, l, t, r, b):
    counts = {}
    n = edges = pairs = 0
    for row in pixels(shot, l, t, r, b):
        prev = None
        for p in row:
            q = (p[0] >> 4, p[1] >> 4, p[2] >> 4)
            counts[q] = counts.get(q, 0) + 1
            n += 1
            if prev is not None:
                pairs += 1
                if max(abs(p[0] - prev[0]), abs(p[1] - prev[1]), abs(p[2] - prev[2])) > 40:
                    edges += 1
            prev = p
    if not n:
        return "dominant=1.0000 edges=0.0000 colours=0"
    return f"dominant={max(counts.values()) / n:.4f} edges={edges / max(pairs, 1):.4f} colours={len(counts)}"


def diff(a, b_, l, t, r, b):
    if a[:2] != b_[:2]:
        return "1.0000"
    n = d = 0
    for ra, rb in zip(pixels(a, l, t, r, b), pixels(b_, l, t, r, b)):
        for p, q in zip(ra, rb):
            n += 1
            if max(abs(p[0] - q[0]), abs(p[1] - q[1]), abs(p[2] - q[2])) > THRESH:
                d += 1
    return f"{d / max(n, 1):.4f}"


def png(shot, out, l=None, t=None, r=None, b=None):
    w, h, px = shot
    if l is None:
        l, t, r, b = 0, 0, w, h
    l, t, r, b = clamp(w, h, l, t, r, b)
    raw = bytearray()
    for y in range(t, b):
        raw.append(0)
        raw += px[(y * w + l) * 4:(y * w + r) * 4]

    def chunk(kind, body):
        c = kind + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    with open(out, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", r - l, b - t, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 3)))
        f.write(chunk(b"IEND", b""))


def main(a):
    if len(a) >= 3 and a[0] == "png":
        s = load(a[1])
        png(s, a[2])
        if len(a) >= 8:
            png(s, a[7], *map(int, a[3:7]))
    elif len(a) == 6 and a[0] == "stats":
        print(stats(load(a[1]), *map(int, a[2:6])))
    elif len(a) == 7 and a[0] == "diff":
        print(diff(load(a[1]), load(a[2]), *map(int, a[3:7])))
    else:
        print(__doc__.strip())
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
