# PowOS Tier-2: Boot-to-Desktop E2E Tests

VM-based tests that prove every change boots to a working KDE Plasma desktop.

## Why

A shipped change once broke boot-to-desktop. This test layer ensures it never
happens again: every PR must pass install -> boot -> SDDM -> sign-in -> desktop
before publish.

## Stages

| Stage | What it tests | Per-PR | Nightly |
|-------|---------------|--------|---------|
| **A** | Boot: graphical.target reached, SSH reachable | yes | yes |
| **B** | Greeter: SDDM active, not crash-looping, screenshot has content | yes | yes |
| **C** | Desktop: autologin -> plasmashell + kwin running, stable 5s | yes | yes |
| **D** | Install: Anaconda ISO unattended install, then A-C on result | no | yes |
| **R** | Ramboot: boot with `rd.powos.ramboot=1`, verify no hang | optional | yes |

## Named regression cases

- **Hang before graphical.target** -- Stage A timeout (BOOT_TIMEOUT exceeded)
- **SDDM crash-loop** -- Stage B: NRestarts > 2
- **Session dies after login** -- Stage C: plasmashell not found or dies within 5s
- **Historical ramboot hang** -- Stage R: VM doesn't come back after reboot with `rd.powos.ramboot=1`

## Quick start

### Local (needs KVM for reasonable speed)

```bash
# Option 1: pre-built disk image
just build-image
./test/tier2/run.sh --from-container localhost/powos:latest

# Option 2: existing qcow2/raw image
./test/tier2/run.sh --image build/output/qcow2/disk.qcow2

# With ramboot regression test
./test/tier2/run.sh --image disk.qcow2 --ramboot

# Stage D (Anaconda install path)
./test/tier2/run.sh --stage d --iso build/output/bootiso/install.iso --image disk.qcow2

# No KVM (TCG fallback -- ~5-10x slower)
./test/tier2/run.sh --image disk.qcow2 --no-kvm
```

### CI

Stages A-C run automatically on every PR/push after the container image build.
Stage D runs on the weekly schedule and manual dispatch.

## Requirements

| Tool | Required | Notes |
|------|----------|-------|
| `qemu-system-x86_64` | yes | VM runtime |
| OVMF | yes | UEFI firmware (package: `ovmf` or `edk2-ovmf`) |
| `sshpass` | yes | Automated SSH with password |
| `python3` | yes | QMP protocol client |
| `/dev/kvm` | recommended | Falls back to TCG with warning |
| `convert` (ImageMagick) | optional | PPM -> PNG screenshot conversion |

Ubuntu/Debian: `sudo apt install qemu-system-x86 qemu-utils ovmf sshpass`
Fedora: `sudo dnf install qemu-system-x86 edk2-ovmf sshpass`

## Artifacts

Each run produces artifacts in `$ARTIFACTS_DIR` (default `/tmp/powos-tier2`):

```
/tmp/powos-tier2/
  serial.log                 Full serial console output
  verdict-stage-a.json       Per-stage machine-readable verdict
  verdict-stage-b.json
  verdict-stage-c.json
  verdict-combined.json      Overall pass/fail + counts
  stage-a-boot.ppm           Named screenshots (PPM or PNG)
  stage-b-greeter.ppm
  stage-c-desktop.ppm
  periodic-0000.ppm          Background screendumps (every 30s)
  periodic-0001.ppm
  ...
```

Verdict JSON format:
```json
{
  "stage": "a",
  "name": "boot-to-graphical",
  "verdict": "pass",
  "duration_s": 45,
  "checks": [
    {"name": "ssh-reachable", "result": "pass"},
    {"name": "graphical-target", "result": "pass"}
  ],
  "timestamp": "2026-07-16T21:30:00+00:00"
}
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARTIFACTS_DIR` | `/tmp/powos-tier2` | Artifact output directory |
| `TIER2_MEM` | `4G` | VM memory |
| `TIER2_CPUS` | `4` | VM CPU count |
| `TIER2_SSH_PORT` | `2222` | Host SSH forward port |
| `TIER2_BOOT_TIMEOUT` | `300` | Seconds to wait for boot SSH |
| `TIER2_DESKTOP_TIMEOUT` | `120` | Seconds to wait for desktop after autologin |
| `TIER2_INSTALL_TIMEOUT` | `1200` | Seconds for Anaconda install (Stage D) |

## How it works

1. **Image preparation**: Takes a qcow2/raw disk image (from bib or pre-built)
   and creates a COW overlay so the source stays pristine.

2. **QEMU launch**: Boots with UEFI (OVMF), VGA framebuffer, QMP control socket,
   serial console logging, and SSH port forwarding. KVM if available, TCG fallback.

3. **Stage A**: Waits for SSH, then asserts `graphical.target` is active.

4. **Stage B**: Checks `sddm.service` is active with 0 restarts. Takes a
   screendump and verifies it's non-blank (heuristic: pixel byte diversity).

5. **Stage C**: Injects an autologin config via SSH (`/etc/sddm.conf.d/`),
   restarts SDDM, and polls for `plasmashell` + `kwin_wayland`/`kwin_x11`.
   Checks stability (process survives 5s). Cleans up the autologin config.

6. **Stage R** (optional): Injects `rd.powos.ramboot=1` via rpm-ostree/bootc
   kargs, reboots, and verifies the VM comes back and reaches graphical.target.

7. **Stage D** (nightly): Boots the Anaconda ISO with a kickstart for unattended
   install, waits for install + reboot, then runs Stages A-C against the result.

## CI failure UX

When A-C fail in CI, the workflow summary shows:
- The tail of the serial console log
- Links to artifact screenshots
- Per-stage verdict JSONs

Download the `tier2-boot-test` artifact for full serial logs and all screenshots.

## Design constraints

- **No image modification**: The shipped image is never changed. Test-only
  injection (autologin config, kargs) happens at runtime via SSH or is applied
  to a COW overlay that is discarded after the test.
- **No heavyweight frameworks**: Pure bash + QEMU + a small Python QMP client.
- **Hard timeouts everywhere**: Every wait has a wall-clock limit. No infinite loops.
- **Artifacts on failure**: Screenshots and serial logs are always available for
  post-mortem debugging, even (especially) when stages fail.
