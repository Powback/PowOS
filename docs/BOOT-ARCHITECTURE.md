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

## OS in RAM: `powos ramboot` (USB auto vs. installed opt-in)

"Run the whole OS from RAM" means two different things depending on how PowOS
booted, and conflating them once caused a boot loop:

| World | Karg | How it engages | `powos ramboot` role |
|-------|------|----------------|----------------------|
| **USB live** | `rd.powos.ramboot=1` | Auto — the dracut module finds `POWOS-DATA`, stacks `custom:updates:base` into an overlay, pivots. USB is unpluggable. | Nothing to enable — `status` reports it; `enable` refuses ("already runs from RAM"). |
| **Installed** (bootc/composefs on a disk) | `rd.powos.ramboot.installed=1` | Opt-in — a **copy-to-tmpfs** path (composefs-safe), *never* overlay-on-self. | `enable` / `disable` / `reset`. |

### Why installed RAM boot is a separate, opt-in karg

An installed root is an ostree **composefs** mount. The USB path overlays the
root on top of itself and `pivot_root`s into the merge — doing that to a
composefs deployment corrupts it and loops the boot. This actually happened when
an installed desktop inherited `rd.powos.ramboot=1` from the image kargs. The
dracut side (`lib/dracut/90powos-ramboot/ramboot-setup.sh`) now **only**
auto-engages when a `POWOS-DATA` partition is present; installed OS-in-RAM is a
deliberate opt-in behind `rd.powos.ramboot.installed=1`, and the CLI never sets
the USB auto karg on an installed system.

### Command surface

```bash
powos ramboot status                    # mode, RAM-vs-OS fit, self-heal counter
sudo powos ramboot enable               # installed only; auto-sizes the tmpfs
sudo powos ramboot enable --ram 20G     # explicit tmpfs size
sudo powos ramboot enable --dry-run     # show the plan, change nothing
sudo powos ramboot disable              # remove the installed opt-in kargs
sudo powos ramboot reset                # clear the self-heal counter after a fix
```

`enable` refuses unless the OS fits in RAM with a reserve: it needs
`MemTotal > OS_estimate + 4 GiB` (OS estimate = `du -sx /usr /etc`), and the
default `--ram` is `min(OS + 4 GiB headroom, MemTotal − 4 GiB)`. Kargs are set
through `rpm-ostree kargs` (preferred) or `bootc kargs` (fallback), whichever
the system has. Both `enable` and `disable` only toggle kernel arguments —
nothing on disk is destroyed — and a reboot is required to apply.

### Contract (kargs, counter, runtime state)

The CLI and the dracut/initramfs side must agree on these exact strings:

```
kargs:
  rd.powos.ramboot=1             USB auto model      (CLI NEVER sets this)
  rd.powos.ramboot.installed=1   installed opt-in    (enable sets / disable clears)
  rd.powos.ramsize=SIZE          tmpfs size, e.g. 20G

self-heal counter (on the ESP):
  <esp>/powos/ramboot-attempts   integer; after 3 failed boots ramboot
                                 auto-skips. `powos ramboot reset` deletes it.

runtime state (written by initramfs, read by the CLI):
  /run/powos/ramboot-state
    POWOS_RAMBOOT_MODE=off|usb|installed-copy
    POWOS_RAMBOOT_ATTEMPTS=<n>
```

If an installed RAM boot misbehaves it auto-reverts after 3 tries (the counter
above), and the 5-second boot menu still offers the previous entry.

> ⚠️ **Status:** the installed copy-to-tmpfs boot path is EXPERIMENTAL and must
> be validated in a VM before it is trusted on real hardware. The CLI is safe on
> a Windows workstation to reason about, but every mutating action is root-gated
> and `--dry-run`-able.

## Boot recovery: `powos doctor` (AI-native boot debugger)

When a boot goes wrong, `powos doctor` collects the evidence and — with `--ai` —
hands it to the health AI agent for a diagnosis. It runs in one of two roles.

| Role | Where it runs | What it diagnoses |
|------|---------------|-------------------|
| **Safe mode** | On the installed/running system that booted degraded | THIS boot + the **previous failed boot** |
| **Live-USB rescue** | Booted from the Live USB | A **broken PowOS install on an internal disk**, mounted READ-ONLY |

### Command surface

```bash
powos doctor                       # collect a bundle for this boot
powos doctor --ai                  # collect + have the health agent diagnose it
powos doctor --target auto --ai    # find a broken install on an internal disk,
                                   #   mount it read-only, diagnose ITS logs
powos doctor --target /dev/sdX     # diagnose a specific device (read-only)
powos doctor --offline             # save the bundle + print how to re-run later;
                                   #   never touches the network/AI
powos doctor --dry-run             # plan only: zero mounts, zero AI calls
powos doctor --ts <stamp>          # override the bundle timestamp (stable names)
powos doctor status                # show boot role (karg) + where bundles land
powos doctor help                  # usage (exit 0)
```

### What it collects

Everything is assembled into a single bundle at
`/var/log/powos/doctor-<ts>.log`, one clearly-headed section each:

- `/proc/cmdline`
- current boot journal (`journalctl -b`)
- the **previous failed boot** (`journalctl -b -1`)
- failed units (`systemctl --failed`)
- kernel ring buffer errors (`dmesg`)
- PowOS runtime state (`/run/powos/*` — `ramboot-state`, `layer-sync-status.json`, …)
- the ESP self-heal counter (`<esp>/powos/ramboot-attempts`)
- (with `--target`) the broken install's persistent journal + `/etc/powos`

Each collector is an isolated, shadowable seam, so the whole thing is unit-tested
with mocked tools (`test/tier1/test-doctor.sh`) — no real disks or journald.

### Target a broken install — read-only, always unmounted

`--target auto` enumerates partitions (`lsblk`), skips the live device
(`findmnt -n -o SOURCE /`), and picks a partition whose label looks like a
PowOS/bootc/ostree root. It mounts that device **`-o ro`** into a temp dir,
reads its logs, and unmounts it — with an `EXIT`/`INT`/`TERM` trap as a
belt-and-suspenders so an interrupt can't leave it mounted. It **never writes**
to the target. Under `--dry-run` no mount happens at all.

### AI credential resolution (first hit wins, secret never printed)

`--ai` needs credentials for the health client. `doc_resolve_ai_creds` tries
four sources **in order** and stops at the first that yields a secret:

1. the **target install's** stored creds (`<target>/etc/powos/ai` + its users' `~/.config`)
2. the **running/Live system's** own creds (`/etc/powos/ai`, `~/.config`, `ANTHROPIC_API_KEY`)
3. **cloud backup** (creds cached in the state repo pulled from the backup remote)
4. **prompt** the operator (only on a real terminal — never hangs a service)

The resolver returns only the *source name*; the secret is handed to the client
via the **environment**, never on a command line (the run-step wrapper echoes
argv). If no creds resolve, or there is no network, or `--offline` is set, doctor
saves the bundle and prints exactly how to re-run once things are available — it
**never hangs on the network** (the reachability probe is a bounded `timeout`).

With `--ai`, if a prior doctor session exists it is continued (`--continue`);
otherwise a fresh `health` session (`--session powos-doctor`) is started.

### Contract (kargs the boot service reacts to)

The orchestrator builds a systemd service that invokes doctor; doctor only
provides the command. Two kargs signal the boot role:

```
powos.mode=safe      the boot menu / a service OFFERS  `powos doctor`
powos.mode=aidebug   a service AUTO-RUNS               `powos doctor --ai`
```

`powos doctor status` reads `/proc/cmdline` and reports which role is active.

> ⚠️ **Status:** the collection + AI path is unit-tested with mocked tools and is
> safe to reason about on a Windows workstation. The live-USB `--target` mount
> path touches real block devices and must be validated on a VM / spare disk
> before it is trusted — it is read-only by construction, but unproven on
> hardware.

## Future: Single Unified Image?

If systemd-sysext improves to allow file replacement, we could:
- Ship ONE base image (mesa)
- NVIDIA as a replacing overlay
- Simpler maintenance

But for now, two bases is the practical solution.
