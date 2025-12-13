# PowOS Boot Architecture

## Overview

PowOS uses a two-base image strategy with GPU detection at boot time.

```
USB Drive Layout
├── EFI/
│   └── BOOT/
│       ├── BOOTX64.EFI          ← systemd-boot or GRUB
│       └── powos-detect.efi     ← GPU detection stub (optional)
│
├── loader/
│   ├── loader.conf
│   └── entries/
│       ├── powos-mesa.conf      ← AMD/Intel boot entry
│       └── powos-nvidia.conf    ← NVIDIA boot entry
│
├── powos/
│   ├── mesa/
│   │   ├── rootfs.img           ← AMD/Intel system image
│   │   └── vmlinuz + initramfs
│   │
│   ├── nvidia/
│   │   ├── rootfs.img           ← NVIDIA system image
│   │   └── vmlinuz + initramfs
│   │
│   ├── overlays/                ← Shared overlays
│   │   ├── steamdeck-hw.raw
│   │   ├── rog-ally.raw
│   │   ├── gaming-mode.raw
│   │   └── ...
│   │
│   └── home/                    ← Shared home (lazy-loaded)
│
└── state/                       ← Git-tracked state
```

## Boot Flow

### Option 1: Initramfs Detection (Preferred)

1. **GRUB/systemd-boot** loads a universal initramfs
2. **Initramfs** runs GPU detection script
3. **Script** determines GPU vendor and switches root to correct image
4. **System boots** with appropriate drivers

```
UEFI → Bootloader → Universal Initramfs → Detect GPU → Mount correct rootfs → Boot
```

**Pros:** Single boot entry, automatic selection
**Cons:** More complex initramfs

### Option 2: Bootloader Menu with Auto-select

1. **Bootloader** has both entries
2. **Default entry** runs detection script
3. **Script** chainloads correct entry
4. **Or:** User manually selects

```
UEFI → Bootloader → [Auto-detect entry] → Chainload mesa/nvidia → Boot
```

**Pros:** Simpler, can still manually override
**Cons:** Slight delay for detection

### Option 3: EFI Stub Detection

1. **Custom EFI application** detects GPU
2. **Sets EFI variable** or **chainloads** correct bootloader entry
3. **Bootloader** reads variable or is already correct

```
UEFI → powos-detect.efi → Set boot target → Bootloader → Boot
```

**Pros:** Very early detection
**Cons:** Requires custom EFI code

---

## GPU Detection Logic

### Detection Script: `/usr/lib/powos/detect-gpu.sh`

```bash
#!/bin/bash
# Detect primary GPU vendor

detect_gpu() {
    # Method 1: Check PCI devices
    if lspci 2>/dev/null | grep -qi "VGA.*NVIDIA"; then
        echo "nvidia"
        return 0
    fi

    # Method 2: Check /sys/class/drm
    for card in /sys/class/drm/card*/device/vendor; do
        if [[ -f "$card" ]]; then
            vendor=$(cat "$card")
            case "$vendor" in
                0x10de) echo "nvidia"; return 0 ;;  # NVIDIA
                0x1002) echo "amd"; return 0 ;;     # AMD
                0x8086) echo "intel"; return 0 ;;   # Intel
            esac
        fi
    done

    # Method 3: Check for nvidia kernel module
    if lsmod 2>/dev/null | grep -q "^nvidia"; then
        echo "nvidia"
        return 0
    fi

    # Default to mesa (covers AMD + Intel)
    echo "mesa"
}

GPU=$(detect_gpu)
echo "Detected GPU: $GPU"
```

### Vendor IDs

| Vendor | PCI ID | Common Names |
|--------|--------|--------------|
| NVIDIA | 0x10de | GeForce, Quadro, Tesla |
| AMD | 0x1002 | Radeon, FirePro |
| Intel | 0x8086 | UHD, Iris, Arc |

---

## Initramfs Implementation (Dracut)

### Custom Dracut Module: `95powos-gpu`

```
/usr/lib/dracut/modules.d/95powos-gpu/
├── module-setup.sh
├── powos-gpu-detect.sh
└── powos-switch-root.sh
```

#### module-setup.sh
```bash
#!/bin/bash

check() {
    return 0  # Always include
}

depends() {
    echo "base"
}

install() {
    inst_hook pre-mount 10 "$moddir/powos-gpu-detect.sh"
    inst_script "$moddir/powos-switch-root.sh" /usr/bin/powos-switch-root
    inst_multiple lspci
}
```

#### powos-gpu-detect.sh
```bash
#!/bin/bash
# Runs in initramfs before mounting root

source /usr/bin/powos-switch-root

GPU=$(detect_gpu)

case "$GPU" in
    nvidia)
        ROOT_IMAGE="/powos/nvidia/rootfs.img"
        ;;
    *)
        ROOT_IMAGE="/powos/mesa/rootfs.img"
        ;;
esac

# Set root for later mount
echo "ROOT=$ROOT_IMAGE" >> /etc/cmdline.d/powos.conf
```

---

## Systemd-boot Configuration

### loader/loader.conf
```
default powos-auto.conf
timeout 3
console-mode max
editor no
```

### loader/entries/powos-auto.conf (Auto-detection)
```
title   PowOS (Auto-detect GPU)
linux   /powos/mesa/vmlinuz
initrd  /powos/mesa/initramfs.img
options root=LABEL=POWOS rootflags=subvol=mesa rw powos.autodetect=1
```

### loader/entries/powos-mesa.conf (Manual AMD/Intel)
```
title   PowOS (AMD/Intel)
linux   /powos/mesa/vmlinuz
initrd  /powos/mesa/initramfs.img
options root=LABEL=POWOS rootflags=subvol=mesa rw
```

### loader/entries/powos-nvidia.conf (Manual NVIDIA)
```
title   PowOS (NVIDIA)
linux   /powos/nvidia/vmlinuz
initrd  /powos/nvidia/initramfs.img
options root=LABEL=POWOS rootflags=subvol=nvidia rw
```

---

## Hybrid GPU Handling (Laptops)

Many laptops have both integrated (Intel/AMD) and discrete (NVIDIA) GPUs.

### Detection Priority
1. If NVIDIA discrete GPU present → use nvidia image
2. If only AMD/Intel → use mesa image

### Runtime Switching
- **supergfxctl** (in nvidia image) handles hybrid switching
- User can switch between integrated/discrete at runtime
- No reboot needed for GPU switching (just session restart)

### Optimus/Prime Support
The nvidia image includes:
- `nvidia-prime` for render offload
- `supergfxctl` for full switching
- `envycontrol` alternative

---

## Overlay Loading (Post-Boot)

After the correct base image boots:

1. **powos-hardware-detect.service** runs
2. Detects device (Steam Deck, ROG Ally, etc.)
3. Detects form factor (laptop, desktop, handheld)
4. Symlinks appropriate overlays to `/var/lib/extensions/`
5. Runs `systemd-sysext refresh`
6. Enables device-specific services

This is INDEPENDENT of GPU detection - overlays work the same on both bases.

---

## USB Drive Preparation

### Partition Layout
```
/dev/sdX
├── sdX1: EFI System Partition (FAT32, 512MB)
│   └── EFI/, loader/, powos kernels
│
└── sdX2: PowOS Data (BTRFS, rest of disk)
    ├── @mesa/        ← Mesa rootfs subvolume
    ├── @nvidia/      ← NVIDIA rootfs subvolume
    ├── @overlays/    ← Shared overlays
    ├── @home/        ← Shared home
    └── @state/       ← Git state
```

### BTRFS Subvolumes
Using BTRFS allows:
- Efficient storage (dedup between images)
- Snapshots for rollback
- Shared data between images
- Compression

---

## First Boot Experience

1. User boots USB on new machine
2. PowOS detects GPU automatically
3. Correct image boots
4. Hardware detection finds device type
5. Overlays loaded for device
6. Desktop appears, fully configured

**No user intervention required** for basic setup.

---

## Future: Single Unified Image?

If systemd-sysext improves to allow file replacement, we could:
- Ship ONE base image (mesa)
- NVIDIA as a replacing overlay
- Simpler maintenance

But for now, two bases is the practical solution.
