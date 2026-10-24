#!/usr/bin/env python3
# bf-xframes.py: the body of bf-lib.sh's xframes() helper, split out to keep that shell function under the
# length budget (test-complexity.sh). Invoked as `python3 /var/tmp/powos-bf-xframes.py <mode> ...` - same argv
# positions as the old `python3 - "$@" <<PY`, since argv[0] (script path) takes the place of the old "-".
# See bf-lib.sh's xframes()/first_frame()/first_change() for the modes this implements.
import ctypes as C, sys, time
X = C.CDLL("libX11.so.6")
X.XOpenDisplay.restype = C.c_void_p; X.XOpenDisplay.argtypes = [C.c_char_p]
X.XDefaultRootWindow.restype = C.c_ulong; X.XDefaultRootWindow.argtypes = [C.c_void_p]
X.XQueryTree.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.POINTER(C.POINTER(C.c_ulong)), C.POINTER(C.c_uint)]
X.XFetchName.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.c_char_p)]
X.XFree.argtypes = [C.c_void_p]
X.XGetImage.restype = C.c_void_p
X.XGetImage.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_ulong, C.c_int]
class Attr(C.Structure):
    _fields_ = [(n, C.c_int) for n in ("x", "y", "width", "height", "border_width", "depth")] + [("visual", C.c_void_p),
        ("root", C.c_ulong), ("cls", C.c_int), ("bit_gravity", C.c_int), ("win_gravity", C.c_int), ("backing_store", C.c_int),
        ("backing_planes", C.c_ulong), ("backing_pixel", C.c_ulong), ("save_under", C.c_int), ("colormap", C.c_ulong),
        ("map_installed", C.c_int), ("map_state", C.c_int), ("all_event_masks", C.c_long), ("your_event_mask", C.c_long),
        ("do_not_propagate_mask", C.c_long), ("override_redirect", C.c_int), ("screen", C.c_void_p)]
class Img(C.Structure):
    _fields_ = [("width", C.c_int), ("height", C.c_int), ("xoffset", C.c_int), ("format", C.c_int), ("data", C.c_void_p),
        ("byte_order", C.c_int), ("bitmap_unit", C.c_int), ("bitmap_bit_order", C.c_int), ("bitmap_pad", C.c_int),
        ("depth", C.c_int), ("bytes_per_line", C.c_int), ("bits_per_pixel", C.c_int)]
X.XGetWindowAttributes.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(Attr)]
ERR = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)(lambda d, e: 0)  # a window gone or resized mid-sample: no exit
X.XSetErrorHandler(ERR)
d = X.XOpenDisplay(None)
if not d:
    print("none", end=""); sys.exit()
def find(w, name, out):  # every window of that name (Proton also has unmapped ones: "Steam" 400x300)
    n = C.c_char_p()
    if X.XFetchName(d, w, C.byref(n)) and n.value is not None:
        if n.value == name or n.value.startswith(name + b" "):  # gamewin's rule: the name, or "<name> ..."
            out.append(w)
        X.XFree(n)
    r, p, k, c = C.c_ulong(), C.c_ulong(), C.POINTER(C.c_ulong)(), C.c_uint()
    if not X.XQueryTree(d, w, C.byref(r), C.byref(p), C.byref(k), C.byref(c)):
        return out
    kids = [k[i] for i in range(c.value)]
    if c.value:
        X.XFree(k)
    for kid in kids:
        find(kid, name, out)
    return out
def sample(w):
    a = Attr()
    if not X.XGetWindowAttributes(d, w, C.byref(a)) or a.map_state != 2 or a.width < 1 or a.height < 1:
        return None
    px = []
    for i in range(16):
        p = X.XGetImage(d, w, 0, a.height * (2 * i + 1) // 32, a.width, 1, 0xFFFFFFFF, 2)  # ZPixmap
        if not p:
            return None
        im = Img.from_address(p)
        if im.bits_per_pixel == 32:
            row = C.string_at(im.data, im.bytes_per_line)
            px += [(row[x] + row[x + 1] + row[x + 2]) // 3 for x in range(0, a.width * 4, 256)]
        X.XFree(im.data); X.XFree(p)
    return px or None
def frame(w, step):  # the whole window, every <step>th pixel and row, as RGB rows (PNG filter byte 0 each)
    a = Attr()
    if not X.XGetWindowAttributes(d, w, C.byref(a)) or a.map_state != 2 or a.width < 1 or a.height < 1:
        return None
    p = X.XGetImage(d, w, 0, 0, a.width, a.height, 0xFFFFFFFF, 2)
    if not p:
        return None
    im = Img.from_address(p)
    if im.bits_per_pixel != 32:
        X.XFree(im.data); X.XFree(p); return None
    buf = C.string_at(im.data, im.bytes_per_line * a.height)
    X.XFree(im.data); X.XFree(p)
    W = (a.width + step - 1) // step
    out = bytearray()
    for y in range(0, a.height, step):
        r = buf[y * im.bytes_per_line:y * im.bytes_per_line + a.width * 4]
        row = bytearray(W * 3)
        row[0::3], row[1::3], row[2::3] = r[2::4 * step], r[1::4 * step], r[0::4 * step]  # BGRX -> RGB
        out += b"\0" + row
    return W, (a.height + step - 1) // step, bytes(out), a.width, a.height
def png(path, f):
    import struct, zlib
    W, H, raw = f[0], f[1], f[2]
    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
    with open(path, "wb") as o:
        o.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))
mode, end = sys.argv[1], time.time() + float(sys.argv[3])
if mode == "grab":
    import os
    out, n = sys.argv[4], 0
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "grab.log"), "a")
    while time.time() < end:
        t = time.time()
        ws = find(X.XDefaultRootWindow(d), sys.argv[2].encode(), [])
        f = w = None
        for w in ws:
            f = frame(w, 2)
            if f:
                break
        if n % 10 == 0:
            log.write("%d %s %s %s\n" % (n // 10 + 1, time.strftime("%T"), hex(w) if f else "-", "%dx%d" % (f[3], f[4]) if f else "no window")); log.flush()
            if f:
                g = frame(w, 1)
                if g:
                    png(os.path.join(out, "f%d.png" % (n // 10 + 1)), g)
        if f:
            png(os.path.join(out, "h%03d.png" % n), f)
        n += 1
        time.sleep(max(0.0, 1.0 - (time.time() - t)))
    log.write("done\n"); sys.exit()
gap = 1.0 / float(sys.argv[4]) if len(sys.argv) > 4 else 0.1
w, first, seen = (0 if mode == "first" else int(sys.argv[2], 0)), None, set()
while time.time() < end:
    t = time.time()
    s = None
    for w in (find(X.XDefaultRootWindow(d), sys.argv[2].encode(), []) if mode == "first" else [w]):
        s = sample(w)  # the first mapped one
        if s:
            break
    if s and mode == "count":
        seen.add(tuple(s))
    elif s:
        if (mode == "first" and max(s) - min(s) > 24) or (first is not None and s != first):
            print("%.3f" % t, end=""); sys.exit()
        if first is None:
            first = s
    time.sleep(max(0.0, gap - (time.time() - t)))
print(len(seen) if mode == "count" else "none", end="")
