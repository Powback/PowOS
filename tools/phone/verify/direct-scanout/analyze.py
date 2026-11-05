#!/usr/bin/env python3
"""analyze.py <dir> <tag>...: direct-scanout step-1 verdict from what ds-phone.sh captured (see dstest.c).
Per tag: the dstest RESULT lines, the clone layer's HWC composition (active display) while shown and while flipping,
and the screencap compared pixel for pixel with dstest.c's pattern A. Prints PASS/FAIL lines; exit 1 on any FAIL."""
import re, sys, os

W, H = 1116, 2484
BARS = [0xffffff, 0xffff00, 0x00ffff, 0x00ff00, 0xff00ff, 0xff0000, 0x0000ff, 0x000000]


def pat(b, x, y):
    rgb = BARS[x * 8 // W] if y < H // 2 else ((x & 255) << 16) | ((y & 255) << 8) | (((x + y) >> 3) & 255)
    return rgb ^ 0xffffff if b else rgb


def expected_row(b, y):
    out = bytearray(W * 4)
    for x in range(W):
        v = pat(b, x, y)
        out[4 * x:4 * x + 4] = bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255, 255))
    return bytes(out)


def hwc_comp(path, name="powos-ds-clone"):
    """(composition, line) of the layer named <name>* in the ACTIVE display's HWC list."""
    if not os.path.exists(path):
        return None, "no dump"
    act, n = False, None
    for ln in open(path, errors="replace"):
        if re.match(r"^Display \d+ \((active|inactive)\) HWC layers", ln):
            act = "(active)" in ln
            continue
        if act and ln.startswith("Display "):
            act = False
        if not act:
            continue
        if ln.startswith(" ") and not ln.startswith("  ") and "|" not in ln:
            n = ln.strip()
        elif "|" in ln and n:
            if n.startswith(name):
                c = ln.split("|")
                return c[3].strip(), "%s: %s" % (n, " | ".join(x.strip() for x in c[3:6]))
            n = None
    return None, "layer %s not in the active HWC list" % name


def cmp_raw(path):
    """(bad pixels, max channel delta, which pattern matched best) of a raw screencap vs patterns A and B."""
    if not os.path.exists(path):
        return None
    d = open(path, "rb").read()
    w, h, f = (int.from_bytes(d[i:i + 4], "little") for i in (0, 4, 8))
    off = 16 if len(d) >= 16 + w * h * 4 else 12
    if (w, h) != (W, H):
        return "size %dx%d" % (w, h)
    best = None
    for b in (0, 1):
        bad = 0
        md = 0
        for y in range(H):
            got = d[off + y * W * 4: off + (y + 1) * W * 4]
            exp = expected_row(b, y)
            if got != exp:
                for x in range(W):
                    g, e = got[4 * x:4 * x + 3], exp[4 * x:4 * x + 3]
                    if g != e:
                        bad += 1
                        md = max(md, max(abs(g[i] - e[i]) for i in range(3)))
            if bad > 200000:
                break
        if best is None or bad < best[0]:
            best = (bad, md, "AB"[b])
    return best


def main():
    dd, tags = sys.argv[1], sys.argv[2:]
    fail = 0
    for t in tags:
        lg = os.path.join(dd, t + ".log")
        res = [l.strip() for l in open(lg, errors="replace")] if os.path.exists(lg) else ["(no log)"]
        print("== %s" % t)
        for l in res:
            if l.startswith(("RESULT", "rc=", "EXIT")) or "Exception" in l or "Error" in l:
                print("  " + l)
        txt = "\n".join(res)
        imp = re.findall(r"import_rc=(-?\d+) buffer=(\w+)", txt)
        ok_imp = len(imp) == 2 and all(r == "0" and b == "ok" for r, b in imp)
        print("%s %s import: %s" % ("PASS" if ok_imp else "FAIL", t, imp or "none"))
        fail += not ok_imp
        for when in ("shown", "flip"):
            c, ln = hwc_comp(os.path.join(dd, "%s.sf-%s.txt" % (t, when)))
            print("%s %s hwc %s: %s" % ("PASS" if c == "DEVICE" else "FAIL", t, when, ln))
            fail += c != "DEVICE"
        for when, want in (("shown", "A"), ("end", "A")):
            r = cmp_raw(os.path.join(dd, "%s.%s.raw" % (t, when)))
            if not isinstance(r, tuple):
                print("FAIL %s screencap %s: %s" % (t, when, r or "missing"))
                fail += 1
                continue
            bad, md, which = r
            ok = bad == 0 and which == want
            print("%s %s screencap %s: closest pattern %s, %d of %d pixels differ (max delta %d)" %
                  ("PASS" if ok else "FAIL", t, when, which, bad, W * H, md))
            fail += not ok
        m = re.search(r"lock_mismatch=(-?\d+)", txt)
        mb = re.search(r"lock_mismatch_b=(-?\d+)", txt)
        ok = bool(m and mb and m.group(1) == "0" and mb.group(1) == "0")
        print("%s %s cpu lock compare: A=%s B=%s" % ("PASS" if ok else "FAIL", t, m and m.group(1), mb and mb.group(1)))
        fail += not ok
        f = re.search(r"flip_sent=(\d+) flip_completes=(\d+) releases=(\d+) release_timeouts=(\d+)", txt)
        ok = bool(f and int(f.group(2)) > 0 and f.group(4) == "0")
        print("%s %s flips: %s" % ("PASS" if ok else "FAIL", t, f.group(0) if f else "none"))
        fail += not ok
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
