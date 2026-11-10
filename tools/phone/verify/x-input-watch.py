#!/usr/bin/env python3
# tools/phone/verify/x-input-watch.py <window> <seconds>: a passive X input log for one X window (ww-popups.sh runs it on
# the phone, in the session, during its menu-bar taps). Nothing is sent or grabbed; it only listens:
#   raw      XI2 raw events on the root (every device): RawTouchBegin/End, RawButtonPress/Release, RawMotion - Xwayland
#            made X input out of a wl_touch (no raw touch = KWin's touch never reached Xwayland)
#   window   EnterNotify / LeaveNotify / FocusIn / FocusOut on <window> (selectable by many clients, unlike button
#            presses): the emulated pointer entered it, it got or lost the X focus
#   focus    the X input focus (XGetInputFocus) at each raw touch/button event
# One line per event: "<t> <kind> <detail>". Exit after <seconds>. Needs only libX11 + libXi (no python-xlib).
import ctypes
import select
import sys
import time

X = ctypes.CDLL("libX11.so.6")
Xi = ctypes.CDLL("libXi.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultRootWindow.restype = ctypes.c_ulong
X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XConnectionNumber.argtypes = [ctypes.c_void_p]
X.XPending.argtypes = [ctypes.c_void_p]
X.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
X.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
X.XFlush.argtypes = [ctypes.c_void_p]
X.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
X.XQueryExtension.argtypes = [ctypes.c_void_p, ctypes.c_char_p] + [ctypes.POINTER(ctypes.c_int)] * 3
Xi.XIQueryVersion.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]


class XIEventMask(ctypes.Structure):
    _fields_ = [("deviceid", ctypes.c_int), ("mask_len", ctypes.c_int), ("mask", ctypes.POINTER(ctypes.c_ubyte))]


Xi.XISelectEvents.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XIEventMask), ctypes.c_int]

RAW = {15: "RawButtonPress", 16: "RawButtonRelease", 17: "RawMotion", 22: "RawTouchBegin", 23: "RawTouchUpdate", 24: "RawTouchEnd"}
CORE = {7: "EnterNotify", 8: "LeaveNotify", 9: "FocusIn", 10: "FocusOut"}


def main():
    win = int(sys.argv[1], 0)
    secs = float(sys.argv[2])
    d = X.XOpenDisplay(None)
    if not d:
        print("0 error no X display")
        return 1
    op, ev, err = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
    if not X.XQueryExtension(d, b"XInputExtension", ctypes.byref(op), ctypes.byref(ev), ctypes.byref(err)):
        print("0 error no XInputExtension")
        return 1
    major, minor = ctypes.c_int(2), ctypes.c_int(2)
    Xi.XIQueryVersion(d, ctypes.byref(major), ctypes.byref(minor))
    bits = bytearray(4)
    for e in RAW:
        bits[e >> 3] |= 1 << (e & 7)
    buf = (ctypes.c_ubyte * 4).from_buffer(bits)
    m = XIEventMask(0, 4, ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte)))  # XIAllDevices
    Xi.XISelectEvents(d, X.XDefaultRootWindow(d), ctypes.byref(m), 1)
    X.XSelectInput(d, win, (1 << 4) | (1 << 5) | (1 << 21))  # Enter, Leave, FocusChange
    X.XFlush(d)
    print("0 start xi %d.%d window 0x%x" % (major.value, minor.value, win), flush=True)
    fd = X.XConnectionNumber(d)
    xev = (ctypes.c_long * 24)()
    raw = ctypes.cast(xev, ctypes.POINTER(ctypes.c_int))
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs:
        if not X.XPending(d):
            select.select([fd], [], [], 0.5)
            continue
        X.XNextEvent(d, xev)
        t = "%.2f" % (time.monotonic() - t0)
        kind = raw[0]
        if kind == 35 and raw[8] == op.value:  # GenericEvent (xcookie: extension at int 8, evtype at int 9)
            name = RAW.get(raw[9])
            if not name or name in ("RawMotion", "RawTouchUpdate"):
                continue
            fw, rv = ctypes.c_ulong(), ctypes.c_int()
            X.XGetInputFocus(d, ctypes.byref(fw), ctypes.byref(rv))
            print("%s raw %s focus 0x%x" % (t, name, fw.value), flush=True)
        elif kind in CORE:
            print("%s window %s" % (t, CORE[kind]), flush=True)
    print("%.2f end" % (time.monotonic() - t0), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
