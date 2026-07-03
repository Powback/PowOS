# PowOS Capabilities (AI context — single source of truth)

This file is injected into PowOS AI agents at call time (via AGENT_CONTEXT_CMD)
alongside live `powos help`. **Edit this one file to keep every agent current** —
do not duplicate this into individual agent prompts. Keep entries short and mark
status honestly so agents don't over-promise.

Status legend: ✅ stable · ⚠️ experimental/partial · 🚧 WIP · ❌ not implemented

## Core model
- Runs live from USB into a RAM overlay; OS in RAM, USB optional at runtime.
- Layered persistence: RAM upper → custom → updates → base (Bazzite). ✅
- Independent rollback per layer: `powos rollback {custom|updates|all|reset}`. ✅
  (grubby can silently fail — verify via `/run/powos/rollback-kargs`.)
- Layer sync RAM→USB every 60s (`powos sync`, `powos flush`). ✅

## Install to disk & dual-boot (NEW)
- The USB boots a menu: **"PowOS Live"** (default, RAM) and **"Install PowOS to disk"**. ✅ menu wiring / ⚠️ install paths need hardware validation
- `powos install-system` — interactive installer. Picks target disk (never wipes
  blindly), detects Windows, defaults to **dual-boot into free space**. ⚠️
  - `--dry-run` shows the plan, changes nothing. `--alongside` / `--whole-disk`
    (whole-disk requires typing the disk model). `--shared-gb N` = shared NTFS.
  - Whole-disk uses `bootc install to-disk` ✅-ish; **alongside is experimental** ⚠️.
- Dual-boot guidance the installer automates / should advise:
  - Disable Windows Fast Startup + hibernation (`powercfg.exe /hibernate off`).
  - Set RTC to local time to match Windows. Suspend BitLocker before repartitioning.
  - Use the UEFI boot menu (F-key) to pick OS — atomic Bazzite's GRUB won't auto-list Windows.
  - Share only large Steam *assets* on NTFS; keep Proton compatdata/prefixes on native FS.
- Reciprocal VMs (`powos vm`): boot the *other* installed OS as a VM off the same
  physical partition, no reboot. `powos vm status`, `sudo powos vm windows`
  (KVM/OVMF, AHCI passthrough), `--dry-run/--ram/--cpus/--gpu`. ⚠️ launch config
  generated + safety-gated (refuses mounted disks); real boot/GPU passthrough
  needs hardware validation. Reverse direction (Windows→PowOS guest) = manual,
  see docs/DUAL-BOOT-VM.md. Gaming in a guest needs GPU passthrough (2 GPUs + IOMMU).
- PowOS cannot build/bundle Windows or a live Windows; Windows comes from normal MS install.

## Runtime updates (edit source → update running system)
- Source is bundled at `/var/lib/powos/src` (no `.git` — excluded from image).
- `powos update self` — deploy bin/lib/config/systemd from source into the live
  system; persists via layer sync. ✅
- `powos update self --from /path` — deploy from a mounted checkout. ✅
- `powos update self --pull` — clones POWOS_UPSTREAM fresh (bundled src has no
  `.git`); private repo needs git creds on the machine. ✅ (creds-dependent)
- `powos update {os|packages|overlays|apply}` — base OS / packages / overlays.

## Other subsystems
- Mobile mode `powos mobile` — copy OS to RAM so USB can unplug. 🚧 live remount not done; reboot needed.
- Cloud backup `powos backup {status|push|pull|setup}` — git-based USB state backup. ✅ CLI exists.
- Sync conflicts `powos sync {status|resolve|--keep-ram|--keep-usb|--merge}` — detection ✅, `--merge` basic ⚠️.
- CacheFS (lazy user-data FUSE) — ❌ opt-in/experimental, off by default (`POWOS_CACHEFS_ENABLED`).
- Containers `powos containers …` (Podman/Distrobox), install/export GUI apps. ✅
- Dev `powos dev {new|fork|build|enable}` incl. `--ai` project generation. ✅
- Overlays (systemd-sysext) via `powos dev` / `overlay-manager.sh`. ✅

## GPU / base image
- One x86-64 USB, GPU variant auto-select at boot: `lib/boot/variant-select.sh`
  picks base-nvidia vs base-main from the detected GPU, override via
  `rd.powos.variant=nvidia|main|auto`. ⚠️ selection ENGINE done + unit-tested;
  the multi-base USB layout + dracut wiring + build-both-variants are NOT wired
  yet (see docs/MULTI-VARIANT-USB.md). x86-64 only — Mac/Android out of scope.
- Base is ONE image, default `bazzite-nvidia:stable` (NVIDIA proprietary driver + KDE).
  Overridable via `POWOS_BASE_IMAGE` / `--build-arg BASE_IMAGE` → `bazzite` (AMD/Intel)
  or `bazzite-nvidia-open` (RTX 20-series+). Driver stack is fixed by the image;
  hardware profiles tune settings but can't swap nvidia↔amd at boot.
- CUDA: base has the NVIDIA driver (CUDA *runtime* works). Full toolkit (nvcc/cuDNN)
  is NOT in the base — use the `powos-cuda` distrobox (nvidia/cuda devel image) for
  compiling CUDA. `powos-python` has GPU passthrough but no toolkit.

## Key paths
- `/usr/lib/powos/` scripts · `/etc/powos/` config · `/run/powos/` runtime state
- `/var/lib/powos/{src,projects,sources,extensions}` · USB label `POWOS-DATA`
