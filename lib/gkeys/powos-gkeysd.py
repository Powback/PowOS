#!/usr/bin/env python3
"""powos-gkeysd — map Logitech G-keys (G915 et al) to real keycodes.

WHY THIS EXISTS
---------------
On G-key keyboards (G915/G913/G815/G610...) the G-keys ship a *duplicate* of
an existing scancode -- on the G915 in its default onboard profile G1..G5 emit
exactly the F1..F5 HID usages (0x7003a..). That makes them indistinguishable
from the real F-keys at the evdev layer, so keyd/hwdb/kmonad CANNOT remap G1
without also remapping F1.

The fix is HID++ feature GKEY (0x8010). Writing function 0x20 with value 0x01
puts the G-keys into "diverted" mode: they stop emitting F-key scancodes and
instead send HID++ notifications. This daemon holds that diversion, listens for
those notifications, and injects the configured keycode via /dev/uinput -- which
works identically under Wayland, X11 and on a TTY, because it is a kernel-level
virtual input device rather than session key synthesis.

Protocol details (feature id, write fnid 0x20, notification bitmask layout)
were taken from Solaar's logitech_receiver implementation rather than guessed.

IMPORTANT BEHAVIOUR: while diversion is active, EVERY G-key stops sending its
default F-key. A G-key with no mapping in the config does nothing at all.
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import os
import select
import struct
import sys
import time

# ── HID++ ────────────────────────────────────────────────────────────────
SHORT, LONG = 0x10, 0x11
ROOT_IDX = 0x00
GETFEATURE_FN = 0x00
GKEY_FEATURE = 0x8010
GKEY_SET_DIVERT_FN = 0x20     # write function; value 0x01 = divert, 0x00 = off
SWID = 0x01
ERROR_FEATURE_IDX = 0x8F

# ── uinput ───────────────────────────────────────────────────────────────
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN, EV_KEY = 0x00, 0x01
SYN_REPORT = 0x00

# Minimal keycode table -- extend as needed. Values from linux/input-event-codes.h
KEYCODES = {
    "KEY_ESC": 1, "KEY_TAB": 15, "KEY_ENTER": 28, "KEY_SPACE": 57,
    "KEY_LEFTCTRL": 29, "KEY_LEFTSHIFT": 42, "KEY_LEFTALT": 56,
    "KEY_CAPSLOCK": 58, "KEY_BACKSPACE": 14, "KEY_DELETE": 111,
    "KEY_HOME": 102, "KEY_END": 107, "KEY_PAGEUP": 104, "KEY_PAGEDOWN": 109,
    "KEY_F1": 59, "KEY_F2": 60, "KEY_F3": 61, "KEY_F4": 62, "KEY_F5": 63,
    "KEY_F6": 64, "KEY_F7": 65, "KEY_F8": 66, "KEY_F9": 67, "KEY_F10": 68,
    "KEY_F11": 87, "KEY_F12": 88,
    "KEY_F13": 183, "KEY_F14": 184, "KEY_F15": 185, "KEY_F16": 186,
    "KEY_F17": 187, "KEY_F18": 188, "KEY_F19": 189, "KEY_F20": 190,
    "KEY_F21": 191, "KEY_F22": 192, "KEY_F23": 193, "KEY_F24": 194,
    "KEY_MUTE": 113, "KEY_VOLUMEDOWN": 114, "KEY_VOLUMEUP": 115,
    "KEY_PLAYPAUSE": 164, "KEY_PREVIOUSSONG": 165, "KEY_NEXTSONG": 163,
}

# Config is searched in order; first hit wins. The user-level path lets a
# machine override the image-shipped default without touching read-only /usr.
CONFIG_SEARCH = [
    os.path.expanduser("~/.config/powos/gkeys.conf"),
    "/etc/powos/gkeys.conf",
]


def resolve_config(explicit: str | None) -> str | None:
    if explicit:
        return explicit
    for candidate in CONFIG_SEARCH:
        if os.path.exists(candidate):
            return candidate
    return None


def log(msg: str) -> None:
    print(f"[powos-gkeysd] {msg}", flush=True)


# ── config ───────────────────────────────────────────────────────────────
def load_config(path: str) -> dict[int, int]:
    """Parse 'G1=KEY_ESC' lines into {gkey_number: keycode}."""
    mapping: dict[int, int] = {}
    if not os.path.exists(path):
        log(f"no config at {path}; nothing mapped")
        return mapping
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if "=" not in line:
                log(f"{path}:{lineno}: ignoring malformed line: {raw.strip()!r}")
                continue
            lhs, rhs = (p.strip() for p in line.split("=", 1))
            if not lhs.upper().startswith("G") or not lhs[1:].isdigit():
                log(f"{path}:{lineno}: ignoring non-G-key {lhs!r}")
                continue
            gnum = int(lhs[1:])
            if not 1 <= gnum <= 32:
                log(f"{path}:{lineno}: G{gnum} out of range 1..32")
                continue
            keycode = KEYCODES.get(rhs.upper())
            if keycode is None:
                log(f"{path}:{lineno}: unknown keycode {rhs!r} (see KEYCODES)")
                continue
            mapping[gnum] = keycode
    return mapping


# ── HID++ transport ──────────────────────────────────────────────────────
class HidppDevice:
    def __init__(self, path: str, devidx: int, quiet: bool = False):
        self.path = path
        self.devidx = devidx
        # quiet=True during probing: non-HID++ hidraw nodes reject our reports
        # with EPIPE, which is expected and must not spam the service log.
        self.quiet = quiet
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.gkey_idx: int | None = None

    def close(self) -> None:
        try:
            os.close(self.fd)
        except OSError:
            pass

    def _write(self, payload: bytes) -> bool:
        try:
            os.write(self.fd, payload)
            return True
        except OSError as e:
            if not self.quiet:
                log(f"write failed: {e.strerror}")
            return False

    def request(self, feat_idx: int, fnid: int, params: bytes = b"",
                timeout: float = 2.0):
        """Send a request and wait for its reply. Returns payload or None."""
        params = params + b"\x00" * (3 - len(params))
        if not self._write(bytes([SHORT, self.devidx, feat_idx, fnid | SWID]) + params):
            return None
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if not r:
                continue
            try:
                rsp = os.read(self.fd, 64)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                return None
            if len(rsp) < 4 or rsp[1] != self.devidx:
                continue
            if rsp[2] == ERROR_FEATURE_IDX:
                return None
            if rsp[2] == feat_idx and (rsp[3] & 0xF0) == (fnid & 0xF0):
                return rsp[4:]
        return None

    def find_gkey_feature(self) -> bool:
        payload = self.request(ROOT_IDX, GETFEATURE_FN,
                               struct.pack(">H", GKEY_FEATURE))
        if not payload or payload[0] == 0x00:
            return False
        self.gkey_idx = payload[0]
        return True

    def set_diverted(self, on: bool) -> bool:
        """Enable/disable G-key diversion. No readback exists -- the device
        offers no getter, so success here means 'the write was accepted'."""
        if self.gkey_idx is None:
            return False
        return self._write(
            bytes([SHORT, self.devidx, self.gkey_idx, GKEY_SET_DIVERT_FN | SWID,
                   0x01 if on else 0x00, 0x00, 0x00])
        )


# ── uinput sink ──────────────────────────────────────────────────────────
class UinputKeyboard:
    def __init__(self, keycodes: set[int], name: str = "PowOS G-Keys"):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for kc in keycodes:
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, kc)
        # legacy uinput_user_dev: name[80], input_id(8), ff_effects_max, 4*64 abs
        payload = (name.encode()[:79].ljust(80, b"\x00")
                   + struct.pack("HHHH", 0x03, 0x046D, 0xC33E, 1)
                   + struct.pack("i", 0)
                   + b"\x00" * (4 * 64 * 4))
        os.write(self.fd, payload)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def emit(self, keycode: int, pressed: bool) -> None:
        now = time.time()
        sec, usec = int(now), int((now % 1) * 1_000_000)
        ev = struct.pack("llHHi", sec, usec, EV_KEY, keycode, 1 if pressed else 0)
        syn = struct.pack("llHHi", sec, usec, EV_SYN, SYN_REPORT, 0)
        os.write(self.fd, ev + syn)

    def close(self) -> None:
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


# ── main loop ────────────────────────────────────────────────────────────
def run(path: str, devidx: int, mapping: dict[int, int], rearm: float,
        verbose: bool) -> int:
    dev = HidppDevice(path, devidx)
    if not dev.find_gkey_feature():
        log(f"{path} devidx=0x{devidx:02x}: no GKEY (0x8010) feature -- wrong "
            f"device? run with --probe to search")
        dev.close()
        return 1
    log(f"GKEY feature index 0x{dev.gkey_idx:02x} on {path} devidx=0x{devidx:02x}")

    if not mapping:
        log("refusing to divert with an empty mapping -- every G-key would go "
            "dead and nothing would be injected. Populate the config first.")
        dev.close()
        return 1

    ui = UinputKeyboard(set(mapping.values()))
    log("mapping: " + ", ".join(f"G{g}->{c}" for g, c in sorted(mapping.items())))

    dev.set_diverted(True)
    log("diversion enabled (G-keys no longer emit their default F-keys)")
    last_rearm = time.monotonic()
    prev_mask = 0
    try:
        while True:
            r, _, _ = select.select([dev.fd], [], [], 1.0)
            now = time.monotonic()
            # Re-arm: diversion is not persisted by the device across
            # disconnect/sleep, and there is no getter to check it, so we
            # simply re-assert it on a timer. Cheap, idempotent.
            if now - last_rearm >= rearm:
                dev.set_diverted(True)
                last_rearm = now
            if not r:
                continue
            try:
                rsp = os.read(dev.fd, 64)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                log(f"read error: {e.strerror}; retrying")
                time.sleep(0.5)
                continue
            if len(rsp) < 8 or rsp[1] != dev.devidx or rsp[2] != dev.gkey_idx:
                continue
            if (rsp[3] & 0xF0) != 0x00:      # address 0x00 == G-key notification
                continue
            mask = struct.unpack("<I", rsp[4:8])[0]
            if verbose:
                log(f"gkey mask 0x{mask:08x}")
            changed = mask ^ prev_mask
            for bit in range(32):
                if not changed & (1 << bit):
                    continue
                gnum = bit + 1
                keycode = mapping.get(gnum)
                if keycode is None:
                    if verbose:
                        log(f"G{gnum} {'down' if mask & (1 << bit) else 'up'} "
                            f"(unmapped)")
                    continue
                ui.emit(keycode, bool(mask & (1 << bit)))
            prev_mask = mask
    except KeyboardInterrupt:
        pass
    finally:
        log("restoring G-keys to their default (undiverted) behaviour")
        dev.set_diverted(False)
        ui.close()
        dev.close()
    return 0


def find_gkey_device() -> tuple[str, int] | None:
    """Scan hidraw nodes for one that answers ROOT.getFeature(GKEY).

    Node numbers are not stable across reboots or replugs, so the daemon
    resolves the device at startup rather than trusting a hardcoded path.
    Nodes that reject HID++ short reports raise EPIPE; that is expected and
    simply means "not this one".
    """
    def _sort_key(name: str) -> int:
        return int(name[len("hidraw"):] or 0)

    try:
        nodes = sorted((n for n in os.listdir("/dev") if n.startswith("hidraw")),
                       key=_sort_key)
    except OSError:
        return None
    for name in nodes:
        path = f"/dev/{name}"
        for devidx in (0x01, 0xFF, 0x02):
            try:
                dev = HidppDevice(path, devidx, quiet=True)
            except OSError:
                break
            try:
                if dev.find_gkey_feature():
                    return (path, devidx)
            finally:
                dev.close()
    return None


def probe() -> int:
    found = find_gkey_device()
    if not found:
        print("no GKEY-capable device found")
        return 1
    print(f"{found[0]} devidx=0x{found[1]:02x}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Map Logitech G-keys to keycodes")
    ap.add_argument("--device", default=None,
                    help="hidraw node (default: auto-detect)")
    ap.add_argument("--devidx", type=lambda s: int(s, 0), default=None,
                    help="HID++ device index (default: auto-detect)")
    ap.add_argument("--config", default=None,
                    help=f"config file (default: first of {CONFIG_SEARCH})")
    ap.add_argument("--rearm", type=float, default=30.0,
                    help="seconds between re-asserting diversion (0=never)")
    ap.add_argument("--probe", action="store_true",
                    help="scan hidraw nodes for a GKEY-capable device and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if args.probe:
        return probe()

    path, devidx = args.device, args.devidx
    if path is None or devidx is None:
        found = find_gkey_device()
        if not found:
            log("no GKEY-capable device found (is the keyboard on/paired?)")
            return 1
        path = path or found[0]
        devidx = devidx if devidx is not None else found[1]
        log(f"auto-detected {path} devidx=0x{devidx:02x}")

    cfg = resolve_config(args.config)
    if cfg is None:
        log(f"no config found in {CONFIG_SEARCH}; nothing to map")
        return 1

    return run(path, devidx, load_config(cfg),
               args.rearm if args.rearm > 0 else 1e9, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
