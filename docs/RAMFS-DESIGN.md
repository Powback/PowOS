# PowOS RAM Overlay Design

## Goal

Unplug USB SSD → System keeps running → Replug → Sync changes back

## The Problem with HomeFS v1

HomeFS only covered `/home`. But:
- Base OS files (`/usr/bin`, `/lib`, etc.) still read from USB
- If USB unplugged and something tries to read an uncached binary → crash

## Solution: Full Overlay Architecture

### How Live USBs Actually Work

Standard live USB (Ubuntu, Fedora):
```
1. Boot loads compressed OS (squashfs) to RAM
2. Entire OS runs from RAM
3. USB partition = "persistence" for saved files
4. USB can be removed after boot (OS doesn't need it)
```

This is what we need, but with a 4TB SSD for data.

### PowOS Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    USB SSD (4TB)                                 │
├─────────────────────────────────────────────────────────────────┤
│  Partition 1: EFI (512MB)                                        │
│  Partition 2: System SquashFS (10GB) - compressed OS image       │
│  Partition 3: Persistence (100GB) - /var, system state          │
│  Partition 4: Home (remainder) - /home/powos                     │
└─────────────────────────────────────────────────────────────────┘

Boot Process:
┌──────────┐    ┌──────────────┐    ┌──────────────┐
│  UEFI    │ -> │  initramfs   │ -> │  RAM overlay │
│  loader  │    │  loads sqfs  │    │  + desktop   │
└──────────┘    │  to RAM      │    └──────────────┘
                └──────────────┘

Runtime:
┌─────────────────────────────────────────────────────────────────┐
│                         RAM                                      │
├─────────────────────────────────────────────────────────────────┤
│  /usr, /lib, /etc (from squashfs, decompressed)                  │
│  overlayfs upper (writes)                                        │
│  tmpfs (/tmp, /run)                                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (sync when connected)
┌─────────────────────────────────────────────────────────────────┐
│                      USB SSD                                     │
├─────────────────────────────────────────────────────────────────┤
│  Partition 3: Persistence (overlay changes synced here)          │
│  Partition 4: Home (/home/powos - direct or cached)              │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: Overlay /home and /var (Simple, works now)

What we can do without custom initramfs:

```bash
# At boot, after USB detected:
USB_HOME=/dev/disk/by-label/POWOS-HOME
USB_VAR=/dev/disk/by-label/POWOS-VAR

# Mount USB partitions read-only
mount -o ro $USB_HOME /mnt/usb-home
mount -o ro $USB_VAR /mnt/usb-var

# Create RAM upper layers
mkdir -p /run/overlay/{home-upper,home-work,var-upper,var-work}
mount -t tmpfs -o size=4G tmpfs /run/overlay

# Create overlays
mount -t overlay overlay \
  -o lowerdir=/mnt/usb-home,upperdir=/run/overlay/home-upper,workdir=/run/overlay/home-work \
  /home

mount -t overlay overlay \
  -o lowerdir=/mnt/usb-var,upperdir=/run/overlay/var-upper,workdir=/run/overlay/var-work \
  /var
```

**Result:**
- Writes to /home and /var go to RAM
- USB can be unplugged for these dirs
- Base OS still needs USB (reads from /usr etc)

### Phase 2: Full RAM Boot (Requires ISO rebuild)

Modify the ISO build to:

1. Create squashfs of the root filesystem
2. Custom initramfs that:
   - Loads squashfs to tmpfs
   - Mounts overlay with RAM upper
   - Detects USB for persistence
3. Dracut module for the overlay setup

```bash
# In initramfs:

# Create RAM filesystem
mount -t tmpfs -o size=16G tmpfs /run/rootfs

# Load compressed OS
mount /dev/disk/by-label/POWOS-SYSTEM /mnt/usb-system
unsquashfs -d /run/rootfs/lower /mnt/usb-system/system.squashfs

# Create overlay
mkdir -p /run/rootfs/{upper,work}
mount -t overlay overlay \
  -o lowerdir=/run/rootfs/lower,upperdir=/run/rootfs/upper,workdir=/run/rootfs/work \
  /sysroot

# Now USB can be unmounted - OS runs from RAM
umount /mnt/usb-system  # Optional - can keep for persistence
```

**Result:**
- Entire OS in RAM
- USB completely optional after boot
- Full unplug resilience

## Sync Daemon

Regardless of phase, we need a sync daemon:

```python
#!/usr/bin/env python3
"""
powos-sync - Sync RAM overlay changes to USB
"""

import os
import time
import subprocess
from pathlib import Path

USB_MOUNT = "/mnt/usb-persist"
OVERLAY_UPPER = "/run/overlay/upper"
SYNC_INTERVAL = 30  # seconds

def is_usb_connected():
    return Path(USB_MOUNT).is_mount()

def sync_to_usb():
    """Rsync overlay upper to USB persistence partition"""
    if not is_usb_connected():
        return False

    subprocess.run([
        "rsync", "-av", "--delete",
        f"{OVERLAY_UPPER}/",
        f"{USB_MOUNT}/overlay/"
    ], check=True)
    return True

def main():
    while True:
        if is_usb_connected():
            try:
                sync_to_usb()
                notify("Synced to USB")
            except Exception as e:
                notify(f"Sync failed: {e}")
        time.sleep(SYNC_INTERVAL)

if __name__ == "__main__":
    main()
```

## USB Hotplug

udev rule to detect USB events:

```udev
# /etc/udev/rules.d/99-powos-usb.rules

# USB connected
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="POWOS-*", \
  RUN+="/usr/bin/powos-usb-event connect %E{ID_FS_LABEL}"

# USB disconnected
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="POWOS-*", \
  RUN+="/usr/bin/powos-usb-event disconnect %E{ID_FS_LABEL}"
```

## CLI Interface

```bash
# Status
$ powos overlay status
Overlay: ACTIVE
  Base: /mnt/usb-root (USB SSD)
  Upper: /run/overlay/upper (RAM, 1.2GB used)
  USB: CONNECTED
  Last sync: 30 seconds ago
  Pending changes: 47 files

# Manual sync
$ powos overlay sync
Syncing to USB... done (47 files, 156MB)

# Safe to unplug check
$ powos overlay safe
✓ Safe to unplug (no pending writes)

# Force offline mode
$ powos overlay offline
Switching to offline mode...
USB will not be accessed until 'powos overlay online'
```

## RAM Requirements

| Mode | RAM Needed | What's in RAM |
|------|-----------|---------------|
| Phase 1 (overlay /home) | 4-8 GB | /home writes, caches |
| Phase 2 (full RAM boot) | 16-32 GB | Entire OS + writes |

Phase 2 requires beefy RAM but gives true unplug resilience.

## Implementation Plan

1. **Now**: Implement Phase 1 overlay for /home and /var
2. **Later**: Build custom ISO with squashfs + initramfs for Phase 2
3. **Config**: Let user choose mode based on RAM available

## Docker Testing

In Docker, we simulate USB with a volume:

```yaml
volumes:
  - powos-fake-usb:/mnt/usb  # Simulates USB SSD
```

Then test overlay behavior:
```bash
# Inside container
mount -t overlay overlay -o lowerdir=/mnt/usb,upperdir=/run/upper,workdir=/run/work /test
# Write to /test, verify it goes to /run/upper
# "Disconnect" USB by unmounting /mnt/usb
# Verify /test still works from RAM cache
```
