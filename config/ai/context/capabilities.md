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
  (grubby failures are reported loudly; `/run/powos/rollback-kargs` is
  informational only — verify after reboot via `grep powos /proc/cmdline`.)
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
- `powos update self --pull` — pulls if src has `.git`; otherwise attaches git
  to the bundled src in place (once), falling back to a one-shot clone when src
  isn't writable. Private repo needs git creds on the machine. ✅ (creds-dependent)
- `powos update {os|packages|overlays|apply}` — base OS / packages / overlays.
- `powos reload` — the easy button: auto-finds your source checkout (~/PowOS etc.),
  remembers it, and hot-applies live (no reboot). `--pull` (git pull first),
  `--build` (full local image build + switch), `--where`. Just `powos reload`.
- `powos upgrade` — smart base update: `bootc upgrade` then the LIGHTEST restart —
  soft-reboot if the staged kernel is unchanged (~seconds, warm), full reboot if it
  changed, nothing if already current. `--check|--now|--soft|--reboot`. Soft-reboot
  into a staged bootc deployment is ⚠️ frontier (opt-in).
- `powos build image [variant] [--switch|--push]` — build the OS image LOCALLY (no
  GitHub), optionally rebase this machine onto it. Self-hosted counterpart to CI. ✅

## Other subsystems
- Settings (`powos config [name] [value]` / `--json`): one front door for system
  toggles AND value settings — ssh, driver (stable/testing channel), auto-update
  (background staging via rpm-ostreed, never auto-reboots), ramsize (kernel arg,
  reboot), sync-interval (layer-sync daemon, applied live), nvidia-persistence,
  cachefs. Each shows WHEN it applies (now/reboot). Registry-based: adding a
  setting is one line + get/set(/validate) pair in lib/config.sh. Intended
  substrate for a future installer/GUI. ✅
- Uninstall (`powos remove [--dry] <thing...>`): mirror of the install router —
  probes flatpak / powos-sandbox (rpm+pip) / brew / host rpm-ostree layer and
  removes from every backend the thing is found in. Honest about host-layer
  config residue in /etc,/var. ✅
- Mobile mode `powos mobile` — copy OS to RAM so USB can unplug. 🚧 live remount not done; reboot needed.
- Cloud backup `powos backup {status|push|pull|setup}` — git-based USB state backup. ✅ CLI exists.
- Sync conflicts `powos sync {status|resolve|--keep-ram|--keep-usb|--merge}` — detection ✅, `--merge` basic ⚠️.
- CacheFS (lazy user-data FUSE) — ❌ incomplete: write-back to USB NOT implemented (written data is lost); must remain disabled (`POWOS_CACHEFS_ENABLED`).
- Containers `powos containers …` (Podman/Distrobox), install/export GUI apps. ✅
- Dev `powos dev {new|fork|build|enable}` incl. `--ai` project generation. ✅
- Overlays (systemd-sysext) via `powos dev` / `overlay-manager.sh`. ✅
- Hibernation / session-resume (hop to Windows for anti-cheat games, resume the
  Linux session on return) — ❌ SPEC ONLY, not built, blocked on persistence
  validation. See docs/HIBERNATION.md. `powos boot windows` (UEFI BootNext,
  one-shot reboot to Windows) IS built. ✅

## GPU / base image
- **Default base is now the OPEN NVIDIA driver** (`bazzite-nvidia-open:stable`).
  Closed proprietary (`bazzite-nvidia`) is selectable; AMD/Intel = `bazzite`.
  Override at build: `POWOS_BASE_IMAGE` / `--build-arg BASE_IMAGE`.
- One x86-64 USB, GPU variant auto-select at boot: `lib/boot/variant-select.sh`
  picks `nvidia-open` (default for NVIDIA) vs `nvidia` (closed) vs `main` (AMD/Intel),
  override via `rd.powos.variant=nvidia-open|nvidia|main|auto`. Install inherits the
  booted variant. ⚠️ selection engine done + unit-tested; multi-variant build,
  USB layout, dracut selection, and boot menu are wired (docs/MULTI-VARIANT-USB.md)
  — hardware validation pending.
  x86-64 only — Mac/Android out of scope. Open needs Turing/GTX-16+; older NVIDIA
  (Maxwell/Pascal) needs closed.
- Driver stack is fixed by the image; hardware profiles tune settings but can't
  swap nvidia↔amd at boot.
- **Runtime base swap** (`powos base`): `list`, `current`, `switch <name>` (persistent
  default, reboot to apply), `add <bootc-image> [name]` (builds through PowOS's
  Containerfile so the new base keeps the RAM-boot module, extracts to
  layers/base-<name>/), `remove`. Same-family swaps work (nvidia open/closed, amd,
  newer/older bazzite/ublue); non-bootc distro is NOT a drop-in. ⚠️ boot-critical,
  needs VM validation. Each base is several GB.
- CUDA (`powos cuda enable|enter|run|status|disable`): base has the NVIDIA driver
  (CUDA *runtime* works). Full toolkit (nvcc/cuDNN) is NOT baked in — it lives in
  the `powos-cuda` distrobox (GPU passed through, nvcc exported to host). Image is
  CUDA 12.8 cuDNN — **≥12.8 is REQUIRED to compile for RTX 50-series (sm_120)**;
  12.4 silently can't target Blackwell. `powos-python` has passthrough but no toolkit.
- Driver channel (`powos driver status|stable|testing`): rebases the installed
  system between published image tags (:nvidia-open ↔ :nvidia-open-testing) for
  tested vs newest drivers. Derives the repo from the booted image (fork-agnostic).
  Reboot to apply; old deployment = rollback. Counterpart to `powos base` (USB layers).
- Private image pulls (`powos registry login [host]`): writes /etc/ostree/auth.json
  so bootc can pull private bases; reuses your `gh` token for ghcr.io.
- Overview (`powos overview [--json]`): one-glance panel — layer model
  (bootc-deployment vs USB overlay-stack), base image + channel, GPU/CUDA,
  deployment/rollback count, active services, containers, disk, safety posture.
  Read-only + non-root, so desktop widgets can poll `--json`.
- Services (`powos services [--json]`): running podman/distrobox containers
  (image, status, ports, gpu-access, dev-vs-service), container-backed systemd
  units (flags stale/failed), and GPU users (vram/util + compute processes).
  The "what are my gsplat/TTS/STT/dev boxes doing + who's on the GPU" panel.
- Install router (`powos install <thing>`): ONE front door — probes flatpak/rpm/
  brew, reports "found in N sources", installs the MOST CONTAINED by default:
  flatpak (sandbox + portals prompt) → powos-sandbox container (own home, can't
  see real $HOME — supply-chain containment) → brew only by explicit opt-in
  (unsandboxed, warns) → host rpm-ostree layer last, always asks. `-m` forces a
  backend; `-m pip` installs inside the sandbox; `--dry` reports only;
  `sandbox-share <dir>` = explicit containment grant. Honesty: flatpak portals
  give real runtime prompts; containers give denial-by-default (no per-syscall
  prompts on Linux) — the sandbox simply cannot see your files.

## Key paths
- `/usr/lib/powos/` scripts · `/etc/powos/` config · `/run/powos/` runtime state
- `/var/lib/powos/{src,projects,sources,extensions}` · USB label `POWOS-DATA`
