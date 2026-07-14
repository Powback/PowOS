# PowOS Controller — Driver-Level Analog Stick-Drift Fixer

**Status:** Implemented. **Command:** `powos controller`
**Last updated:** 2026-07-14

---

## 1. Goal

Fix analog **stick drift** (and trigger drift) permanently, for **any**
joystick or gamepad — Xbox, PS4 / PS5 / DualSense, DJI, and generic HID pads —
without per-game tweaking and without extra software.

A worn or cheap stick reports a small non-zero value even at rest. Games read
that as constant input: the camera creeps, the character walks. The usual fixes
(Steam per-game deadzones, `xboxdrv`, vendor apps) are per-title, per-launcher,
or Windows-only. PowOS fixes it **once, below the game.**

## 2. Mechanism

Every Linux input device exposes a per-axis **"flat"** value — the region around
center the kernel treats as zero. PowOS sets that flat value at the evdev/driver
level with `evdev-joystick` (from **linuxconsoletools**, already in the base
image — verify with `command -v evdev-joystick`):

```
evdev-joystick --evdev /dev/input/eventN --axis <n> --deadzone <units>
```

Because the deadzone lives in the kernel input device, **everything above it**
— Steam, Proton, native games, emulators — sees a clean, centered stick with no
configuration.

### Percentage → axis units

Axes have different ranges (a 16-bit stick is −32768..32767; an 8-bit trigger is
0..255). To make one user-facing percentage mean the same thing on every axis,
PowOS converts using each axis's own min/max:

```
flat_units = round( pct × (max − min) / 200 )
```

This mirrors how `evdev-joystick` reports a deadzone (`flat × 200 / (max − min)`,
i.e. flat as a fraction of the half-range from center). Hat/D-pad axes (range ≤2)
are skipped.

## 3. Usage

```
powos controller list                     # detected pads: node, VID:PID, deadzone, idle drift
powos controller deadzone <dev> <pct>     # set + persist a deadzone, apply now
powos controller deadzone <dev> auto      # sample idle drift ~2s, set just above it
powos controller clear <dev>              # remove stored deadzone, reset flat to kernel default
powos controller status                   # stored config + hotplug reapply state
```

`<dev>` accepts a **VID:PID** (`2ca3:1020`), a **name substring** (`dji`,
`dualsense`), or a **js/event node** (`js0`, `event2`).

```
powos controller deadzone 045e:028e 8       # Xbox pad → 8% deadzone
powos controller deadzone "dualsense" auto  # measure + fix a drifting PS5 pad
powos controller clear js0
```

## 4. Persistence & hotplug — why it's "permanent"

The kernel **forgets** the flat value when a controller is unplugged. Two pieces
make the fix stick:

- **Store:** `/etc/powos/controllers.conf` — one documented `key=value` entry set
  per controller, keyed by USB VID:PID:

  ```
  deadzone.045e:028e = 8
  name.045e:028e     = Microsoft X-Box 360 pad
  default.045e:028e  = 0:128,1:128,2:0,3:128,4:128,5:0   # pre-PowOS flats, for `clear`
  ```

- **Hotplug reapply:** the udev rule `60-powos-controller.rules` fires on every
  joystick `add` and starts the oneshot template unit
  `powos-controller@<node>.service`, which runs `controller-apply.sh` to restore
  the stored deadzone. This runs on every plug-in **and** every boot.

`powos controller` installs the udev rule and unit into `/etc` on the first
`deadzone` save, so the feature is live immediately (both paths persist across
`bootc` upgrades). The canonical rule/unit also live in the source tree
(`config/udev/60-powos-controller.rules`, `systemd/powos-controller@.service`)
for image shipping; an image-installed copy under `/usr/lib/...` takes
precedence over the runtime one.

## 5. Files

| Path | Role |
|------|------|
| `lib/controller.sh` | Subsystem: enumeration, per-axis apply, CLI, persistence, hotplug install |
| `lib/controller-apply.sh` | Hotplug applier invoked by the systemd oneshot |
| `systemd/powos-controller@.service` | Oneshot template unit (udev-triggered) |
| `config/udev/60-powos-controller.rules` | udev rule that starts the unit on joystick `add` |
| `/etc/powos/controllers.conf` | Per-VID:PID deadzone store (runtime) |

## 6. Notes

- Setting a deadzone needs write access to `/dev/input/eventN`. The logged-in
  desktop user has it via logind's `uaccess` ACL; otherwise the command escalates
  with `sudo`. The hotplug unit runs as root, so reapply always works.
- `clear` restores the exact pre-PowOS flats captured on the first set, not a
  guessed zero — so a device's own factory deadzone comes back.
