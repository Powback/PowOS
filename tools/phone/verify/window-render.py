#!/usr/bin/env python3
"""tools/phone/verify/window-render.py: the pixel side of window-render.sh (stdlib only: the Mac has no PIL/numpy).

Shots are `screencap` RAW (RGBA after a 12/16-byte header), gzipped on the phone: no PNG decode needed here.
  window-render.py png SHOT.raw.gz OUT.png [l t r b CROP.png]   a viewable PNG of the shot (and of the body rect)
  window-render.py stats SHOT.raw.gz l t r b                     "dominant=<share> edges=<share> colours=<n>" of the rect
  window-render.py diff A.raw.gz B.raw.gz l t r b                "<share>" of the rect's pixels that differ (any channel > 24)
  window-render.py drawnall SHOT.raw[.gz] step l t r b [l t r b ...]   the same for several rects: 0 when every one is
  window-render.py drawn SHOT.raw[.gz] l t r b [step]             stats; exit 0 when the rect is a picture, not a flat fill
                                                                 (dominant < 0.97, colours >= 4) - run ON the phone by
                                                                 window-bench.sh's wb-drawn.sh (plain raw, step 8)
The rect is device px, sampled every STEP (2) px each way.
  window-render.py calc UI.xml DISPLAY PKG     the hidden check's tap plan, read from `uiautomator dump --windows` (the
                                              app's real layout on that display, any width/layout): line 1
                                              "KEY X Y UNDO UX UY" (the judged key and its centre, then the key that
                                              undoes it or "- - -"), line 2 the formula's text as JSON. KEY is "del"
                                              when the formula ends in a char with a visible key (UNDO = that key: the
                                              char typed back), else digit_7/op_add (UNDO = del). Exit 1 (a reason)
                                              when the display has no such app or key.
  window-render.py calcdisp UI.xml PKG        "DISPLAY W H": the display PKG's nodes are on and its size (the visible
                                              check's own window: it refuses to run while the app has a task), exit 1 none
  window-render.py calcjudge A.xml B.xml DISPLAY PKG changed|same   exit 0 when the formula text went from A to B as
                                              asked ("formula 'a' -> 'b'" printed either way), 1 not, 2 unreadable
"""
import gzip
import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib

STEP = 2
THRESH = 24


def load(path):
    with open(path, "rb") as f:
        blob = f.read()
    # screencap's own warnings ("[Warning] Multiple displays were found...") may come first on its stdout.
    at = blob.find(b"\x1f\x8b")
    if at < 0:
        # Plain raw (on the phone, no gzip): skip any warning text before the header - the offset where w*h*4 plus a
        # 12/16-byte header is exactly what is left.
        for off in range(0, min(len(blob) - 8, 2048)):
            w, h = struct.unpack_from("<II", blob, off)
            if 0 < w < 10000 and 0 < h < 10000 and len(blob) - off - w * h * 4 in (12, 16):
                return w, h, memoryview(blob)[len(blob) - w * h * 4:]
        raise SystemExit(f"window-render.py: {path}: no gzip stream, not a raw screencap ({blob[:80]!r})")
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


# The hidden check's Calculator (com.android.calculator2 ids, the OnePlus build too): the key it taps and the text it
# judges. The formula keeps every earlier keystroke (the app persists it), can scroll and its layout differs by width
# (11-11 ea2933b3: a fixed 0.14,0.69 tap hit the scientific layout's "log" key, the appended "log(" was off-screen and
# the pixel diff read 0.0005 -> a false "WINDOWS BROKEN"). So the key is found by id and the effect read as text.
DIGIT_LIMIT = 10  # a trailing number this long may be at the app's digit limit (a 7 there changes nothing): tap "+".


def ui_nodes(path, display, pkg):
    """{resource-id suffix or 'text:<t>': (bounds, text)} of PKG's nodes on DISPLAY in a uiautomator dump."""
    with open(path, "rb") as f:
        blob = f.read()
    at = blob.find(b"<?xml")  # uiautomator's own "UI hierchary dumped to" line may come first
    root = ET.fromstring(blob[max(at, 0):].strip())
    scopes = [d for d in root.iter("display") if d.get("id") == str(display)] if root.tag == "displays" else [root]
    out = {}
    for scope in scopes:
        for n in scope.iter("node"):
            if n.get("package") != pkg:
                continue
            m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", n.get("bounds", ""))
            if not m:
                continue
            b = tuple(map(int, m.groups()))
            rid = n.get("resource-id", "").rsplit(":id/", 1)[-1]
            text = n.get("text", "")
            if rid:
                out.setdefault(rid, (b, text))
            if text and n.get("clickable") == "true":
                out.setdefault("text:" + text, (b, text))
    return out


def visible(b):
    return b[2] > b[0] and b[3] > b[1] and b[0] >= 0 and b[1] >= 0


def centre(b):
    return (b[0] + b[2]) // 2, (b[1] + b[3]) // 2


def formula(nodes):
    """The expression the user/check typed (the formula; the result line where an app has no formula id), or None."""
    for rid in ("formula", "result"):
        if rid in nodes:
            return nodes[rid][1]
    return None


# The key that types each formula char back (11-11: the judged keystroke is a delete when the formula ends in one of
# these - a delete changes ANY non-empty formula, even one at the app's max length, and its char is typed back after).
# The OnePlus build stores functions as one char ("L" = log(, "c" = cos(): those have no key in the basic layout and are
# typed back only when their key is visible.
CHAR_KEYS = {**{str(d): ["digit_%d" % d, "text:%d" % d] for d in range(10)}, ".": ["dec_point", "text:."],
             "+": ["op_add", "text:+"], "-": ["op_sub"], "\u2212": ["op_sub"], "*": ["op_mul"], "\u00d7": ["op_mul"],
             "/": ["op_div"], "\u00f7": ["op_div"], "%": ["op_pct"], "(": ["lparen"], ")": ["rparen"],
             "L": ["fun_log"], "c": ["fun_cos"], "s": ["fun_sin"], "t": ["fun_tan"], "l": ["fun_ln"]}


def calc_plan(path, display, pkg):
    nodes = ui_nodes(path, display, pkg)
    if not nodes:
        return 1, f"no {pkg} node on display {display} in the accessibility dump"
    f = formula(nodes)
    if f is None:
        return 1, f"no formula/result text of {pkg} on display {display} (ids: {' '.join(sorted(nodes)[:12])})"

    def key(ids):
        return next(((k, *centre(nodes[k][0])) for k in ids if k in nodes and visible(nodes[k][0])), None)

    dl = key(["del", "delete_button"])
    back = key(CHAR_KEYS.get(f[-1], [])) if f and dl else None
    if back:  # the delete, judged; its char typed back by its own key
        return 0, f"del {dl[1]} {dl[2]} {back[0]} {back[1]} {back[2]}\n{json.dumps(f)}"
    run = re.search(r"[0-9][0-9.,' \u00a0\u202f]*$", f)
    digits = len(re.sub(r"[^0-9]", "", run.group(0))) if run else 0
    want = [("op_add", "text:+"), ("digit_7", "text:7")] if digits >= DIGIT_LIMIT else [("digit_7", "text:7")]
    for ids in want:
        k = key(ids)
        if k:
            u = f"del {dl[1]} {dl[2]}" if dl else "- - -"
            return 0, f"{ids[0]} {k[1]} {k[2]} {u}\n{json.dumps(f)}"
    return 1, f"no visible {' or '.join(i[0] for i in want)} key of {pkg} on display {display}"


def calc_disp(path, pkg):
    with open(path, "rb") as f:
        blob = f.read()
    root = ET.fromstring(blob[max(blob.find(b"<?xml"), 0):].strip())
    for d in root.iter("display"):
        bs = [tuple(map(int, re.findall(r"-?\d+", n.get("bounds", "")))) for n in d.iter("node") if n.get("package") == pkg]
        bs = [b for b in bs if len(b) == 4]
        if bs:
            return 0, f"{d.get('id')} {max(b[2] for b in bs)} {max(b[3] for b in bs)}"
    return 1, f"no display with {pkg} nodes"


def calc_judge(a, b, display, pkg, want):
    fa, fb = (formula(ui_nodes(p, display, pkg)) for p in (a, b))
    if fa is None or fb is None:
        return 2, f"formula unreadable (before {fa!r}, after {fb!r})"
    msg = f"formula {fa!r} -> {fb!r}"
    return (0 if (fa != fb) == (want == "changed") else 1), msg


def main(a):
    global STEP
    if len(a) >= 3 and a[0] == "png":
        s = load(a[1])
        png(s, a[2])
        if len(a) >= 8:
            png(s, a[7], *map(int, a[3:7]))
    elif len(a) == 6 and a[0] == "stats":
        print(stats(load(a[1]), *map(int, a[2:6])))
    elif len(a) in (6, 7) and a[0] == "drawn":
        if len(a) == 7:
            STEP = int(a[6])
        st = stats(load(a[1]), *map(int, a[2:6]))
        print(st)
        kv = dict(x.split("=") for x in st.split())
        return 0 if float(kv["dominant"]) < 0.97 and int(kv["colours"]) >= 4 else 1
    elif len(a) >= 7 and a[0] == "drawnall" and (len(a) - 3) % 4 == 0:
        # drawnall SHOT step l t r b [l t r b ...]: exit 0 when every rect is drawn; prints the first flat one's stats.
        STEP = int(a[2])
        shot = load(a[1])
        for i in range(3, len(a), 4):
            st = stats(shot, *map(int, a[i:i + 4]))
            kv = dict(x.split("=") for x in st.split())
            if not (float(kv["dominant"]) < 0.97 and int(kv["colours"]) >= 4):
                print(f"rect {(i - 3) // 4 + 1}: {st}")
                return 1
        print(f"all {(len(a) - 3) // 4} drawn")
        return 0
    elif len(a) == 4 and a[0] == "calc":
        try:
            rc, msg = calc_plan(a[1], a[2], a[3])
        except (OSError, ET.ParseError) as e:
            rc, msg = 1, f"dump unreadable: {e}"
        print(msg)
        return rc
    elif len(a) == 3 and a[0] == "calcdisp":
        try:
            rc, msg = calc_disp(a[1], a[2])
        except (OSError, ET.ParseError) as e:
            rc, msg = 1, f"dump unreadable: {e}"
        print(msg)
        return rc
    elif len(a) == 6 and a[0] == "calcjudge" and a[5] in ("changed", "same"):
        try:
            rc, msg = calc_judge(*a[1:])
        except (OSError, ET.ParseError) as e:
            rc, msg = 2, f"dump unreadable: {e}"
        print(msg)
        return rc
    elif len(a) == 7 and a[0] == "diff":
        print(diff(load(a[1]), load(a[2]), *map(int, a[3:7])))
    else:
        print(__doc__.strip())
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
