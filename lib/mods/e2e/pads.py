#!/usr/bin/env python3
"""Virtual gamepads for end-to-end game testing.

Creates N independent Xbox-360-compatible pads through /dev/uinput. Every game
that reads evdev — which under Proton means SDL2, which means effectively all of
them — sees real controllers indistinguishable from plugged-in hardware.

Why in-process instead of a daemon per pad
------------------------------------------
The obvious design (one process per pad, commands over a FIFO) does not scale
past one: a FIFO path is a global name, so the second instance collides with the
first. Naming them apart then leaves the harness coordinating N subprocesses and
N pipes to test a two-player feature. Pads are cheap objects; a PadFarm owns
them all in the harness process and addresses them by index.

A `serve()` entry point keeps the daemon shape available for shell callers, with
per-pad FIFOs derived from the farm name so instances never collide.

Permissions
-----------
/dev/uinput is root-owned. Access comes from a POSIX ACL or an `input` group
membership plus a udev rule; `probe()` reports which, and says exactly what is
missing rather than failing at the first write.
"""
from __future__ import annotations

import os
import time

try:
    from evdev import UInput, AbsInfo, ecodes as e
    EVDEV_ERROR = None
except Exception as _ex:                                    # pragma: no cover
    UInput = None
    EVDEV_ERROR = f"{type(_ex).__name__}: {_ex}"


# ── Control map ───────────────────────────────────────────────────────────────
# Names are the harness's vocabulary, deliberately pad-neutral: a scenario says
# "press A", never "press BTN_SOUTH".

BUTTONS = {
    "A": "BTN_SOUTH", "B": "BTN_EAST", "X": "BTN_NORTH", "Y": "BTN_WEST",
    "START": "BTN_START", "SELECT": "BTN_SELECT", "BACK": "BTN_SELECT",
    "TL": "BTN_TL", "TR": "BTN_TR", "LB": "BTN_TL", "RB": "BTN_TR",
    "THUMBL": "BTN_THUMBL", "THUMBR": "BTN_THUMBR",
}

# The d-pad is a hat, not four keys — SDL maps ABS_HAT0X/Y to the d-pad and
# would not see BTN_DPAD_* on a device that also declares a hat.
HAT = {"DU": ("ABS_HAT0Y", -1), "DD": ("ABS_HAT0Y", 1),
       "DL": ("ABS_HAT0X", -1), "DR": ("ABS_HAT0X", 1)}

AXES = ("ABS_X", "ABS_Y", "ABS_RX", "ABS_RY", "ABS_Z", "ABS_RZ")

STICK_MAX = 32767


def probe():
    """(ok, message) — can this machine create virtual pads, and if not, why."""
    if UInput is None:
        return False, (f"python-evdev is not importable ({EVDEV_ERROR}). "
                       "Install it: pip install --user evdev")
    if not os.path.exists("/dev/uinput"):
        return False, ("/dev/uinput does not exist. Load the module: "
                       "sudo modprobe uinput  (persist via /etc/modules-load.d/)")
    if not os.access("/dev/uinput", os.W_OK):
        return False, (
            "/dev/uinput is not writable by this user. Either grant an ACL "
            "(sudo setfacl -m u:$USER:rw /dev/uinput) or add a udev rule:\n"
            '  KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"\n'
            "in /etc/udev/rules.d/99-uinput.rules, then add yourself to `input`.")
    return True, "ok"


class Pad:
    """One virtual controller."""

    def __init__(self, name: str, index: int = 0):
        ok, why = probe()
        if not ok:
            raise RuntimeError(why)

        stick = AbsInfo(value=0, min=-STICK_MAX - 1, max=STICK_MAX,
                        fuzz=16, flat=128, resolution=0)
        trigger = AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0)
        hat = AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0)

        caps = {
            e.EV_KEY: sorted({getattr(e, c) for c in BUTTONS.values()}),
            e.EV_ABS: [
                (e.ABS_X, stick), (e.ABS_Y, stick),
                (e.ABS_RX, stick), (e.ABS_RY, stick),
                (e.ABS_Z, trigger), (e.ABS_RZ, trigger),
                (e.ABS_HAT0X, hat), (e.ABS_HAT0Y, hat),
            ],
        }
        # Identify as a wired Xbox 360 pad: the profile every engine, SDL
        # mapping database and controller-config UI already knows. A novel
        # vid/pid lands in SDL's "unknown controller" path, where button
        # positions are guesswork and a test would fail for the wrong reason.
        self.ui = UInput(caps, name=name, vendor=0x045E, product=0x028E,
                         version=0x0110, bustype=0x03)
        self.name = name
        self.index = index
        self._down = set()
        # udev has to notice the node and SDL has to run its hotplug scan
        # before the game will list this pad; a pad created and used in the
        # same millisecond is simply not there yet.
        time.sleep(0.2)

    # ── raw ───────────────────────────────────────────────────────────────
    def _key(self, code, value):
        self.ui.write(e.EV_KEY, code, value)
        self.ui.syn()

    def _abs(self, code, value):
        self.ui.write(e.EV_ABS, code, value)
        self.ui.syn()

    def _resolve(self, name):
        n = name.upper()
        if n in BUTTONS:
            return ("key", getattr(e, BUTTONS[n]), 1)
        if n in HAT:
            axis, value = HAT[n]
            return ("abs", getattr(e, axis), value)
        raise KeyError(f"unknown control '{name}' "
                       f"(have {sorted(BUTTONS)} + {sorted(HAT)})")

    # ── verbs ─────────────────────────────────────────────────────────────
    def down(self, control):
        kind, code, value = self._resolve(control)
        (self._key if kind == "key" else self._abs)(code, value)
        self._down.add(control.upper())
        return self

    def up(self, control):
        kind, code, _ = self._resolve(control)
        (self._key if kind == "key" else self._abs)(code, 0)
        self._down.discard(control.upper())
        return self

    def press(self, control, seconds=0.09):
        self.down(control)
        time.sleep(seconds)
        self.up(control)
        return self

    def hold(self, control, seconds):
        return self.press(control, seconds)

    def axis(self, name, value):
        self._abs(getattr(e, name.upper()), int(value))
        return self

    def stick(self, x, y=0, seconds=None):
        """Left stick. x/y are -1.0..1.0; evdev Y is inverted (up is negative)."""
        self.ui.write(e.EV_ABS, e.ABS_X, int(max(-1.0, min(1.0, x)) * STICK_MAX))
        self.ui.write(e.EV_ABS, e.ABS_Y, int(max(-1.0, min(1.0, -y)) * STICK_MAX))
        self.ui.syn()
        if seconds:
            time.sleep(seconds)
            self.neutral()
        return self

    def neutral(self):
        for code in {getattr(e, c) for c in BUTTONS.values()}:
            self.ui.write(e.EV_KEY, code, 0)
        for a in AXES + ("ABS_HAT0X", "ABS_HAT0Y"):
            self.ui.write(e.EV_ABS, getattr(e, a), 0)
        self.ui.syn()
        self._down.clear()
        return self

    @property
    def devnode(self):
        return self.ui.device.path if self.ui.device else None

    def close(self):
        try:
            self.neutral()
            self.ui.close()
        except Exception:
            pass


class PadFarm:
    """N pads, addressed by index, torn down together."""

    def __init__(self, count=0, prefix="PowOS E2E Pad"):
        self.prefix = prefix
        self.pads = []
        for i in range(count):
            self.add()

    def add(self):
        # Distinct names matter: the mod under test picks a device by identity,
        # and a scenario asserting "player 2 is on pad 2" needs them told apart
        # in logs and in the game's own device list.
        pad = Pad(f"{self.prefix} {len(self.pads) + 1}", index=len(self.pads))
        self.pads.append(pad)
        return pad

    def __getitem__(self, i):
        return self.pads[i]

    def __len__(self):
        return len(self.pads)

    def __iter__(self):
        return iter(self.pads)

    def neutral(self):
        for p in self.pads:
            p.neutral()

    def close(self):
        for p in self.pads:
            p.close()
        self.pads = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


# ── daemon mode (for shell callers) ───────────────────────────────────────────
def serve(count, prefix, fifo_dir):
    """Create `count` pads and take commands on <fifo_dir>/pad<N>.

    Line protocol, one command per line — same verbs as the Python API:
        press|hold|down|up <CONTROL> [seconds]
        axis <ABS_NAME> <value>
        stick <x> <y> [seconds]
        neutral
        quit
    """
    os.makedirs(fifo_dir, exist_ok=True)
    farm = PadFarm(count, prefix)
    fifos = []
    for i in range(count):
        path = os.path.join(fifo_dir, f"pad{i + 1}")
        if os.path.exists(path):
            os.unlink(path)
        os.mkfifo(path)
        fifos.append(path)
        print(f"pad {i + 1}: {farm[i].name} -> {farm[i].devnode}  fifo {path}",
              flush=True)
    print("ready", flush=True)

    import select
    handles = [os.open(f, os.O_RDONLY | os.O_NONBLOCK) for f in fifos]
    buffers = ["" for _ in fifos]
    try:
        while True:
            ready, _, _ = select.select(handles, [], [], 0.25)
            for h in ready:
                idx = handles.index(h)
                chunk = os.read(h, 4096).decode("utf-8", "replace")
                if not chunk:
                    continue
                buffers[idx] += chunk
                while "\n" in buffers[idx]:
                    line, buffers[idx] = buffers[idx].split("\n", 1)
                    if not dispatch(farm[idx], line):
                        return
    finally:
        farm.close()
        for f in fifos:
            try:
                os.unlink(f)
            except OSError:
                pass


def dispatch(pad, line):
    """Run one text command against a pad. False means 'stop serving'."""
    parts = line.strip().split()
    if not parts:
        return True
    verb = parts[0].lower()
    try:
        if verb == "quit":
            return False
        if verb == "neutral":
            pad.neutral()
        elif verb in ("press", "hold") and len(parts) >= 2:
            pad.press(parts[1], float(parts[2]) if len(parts) > 2 else 0.09)
        elif verb == "down" and len(parts) >= 2:
            pad.down(parts[1])
        elif verb == "up" and len(parts) >= 2:
            pad.up(parts[1])
        elif verb == "axis" and len(parts) >= 3:
            pad.axis(parts[1], int(parts[2]))
        elif verb == "stick" and len(parts) >= 3:
            pad.stick(float(parts[1]), float(parts[2]),
                      float(parts[3]) if len(parts) > 3 else None)
        else:
            print(f"?? {line.strip()}", flush=True)
    except Exception as ex:
        print(f"!! {line.strip()}: {ex}", flush=True)
    return True


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Virtual gamepads for e2e testing")
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--prefix", default="PowOS E2E Pad")
    ap.add_argument("--fifo-dir", default=os.path.join(
        os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "powos-e2e-pads"))
    ap.add_argument("--probe", action="store_true",
                    help="report whether virtual pads can be created, and exit")
    a = ap.parse_args()
    if a.probe:
        ok, why = probe()
        print(("OK: " if ok else "UNAVAILABLE: ") + why)
        raise SystemExit(0 if ok else 1)
    serve(a.count, a.prefix, a.fifo_dir)
