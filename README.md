# PowOS

A [Bazzite](https://bazzite.gg/)/[bootc](https://bootc-dev.github.io/bootc/)-based
Linux with **layered persistence and independent rollback**. It runs either as a
portable OS off a USB SSD (the whole system in RAM, take it to any machine) or as
an installed daily-driver desktop that dual-boots alongside Windows. You can
install packages and change configs like a normal system — everything persists —
but each layer (base OS, updates, your customizations) rolls back on its own, so a
bad update or a broken package never means a reinstall.

> **Honesty first.** PowOS is in active development. Some of what's described here
> is solid, some is work-in-progress, some is experimental and not yet
> hardware-validated. Every section flags its status, and the
> [Feature Status](#feature-status) table is the at-a-glance truth. When in doubt,
> trust the status markers over the prose. For the deepest, most current technical
> reference see [`CLAUDE.md`](CLAUDE.md).

## Contents

- [Two ways to run PowOS](#two-ways-to-run-powos)
- [Core concepts](#core-concepts)
- [Quick start](#quick-start)
- [Dual-boot, games and Windows](#dual-boot-games-and-windows)
- [The developer / customization workflow](#the-developer--customization-workflow)
- [AI integration](#ai-integration)
- [Discoverability](#discoverability)
- [Command reference](#command-reference)
- [Feature status](#feature-status)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)
- [Credentials](#credentials)
- [License](#license)

---

## Two ways to run PowOS

PowOS's **primary story is install-to-disk**: a daily-driver desktop that
dual-boots Windows. The live-USB "run from RAM anywhere" mode is the original
vision, kept as an explicit opt-in. The same source, same CLI, same customization
model backs both.

> **RAM boot is OFF by default.** The `rd.powos.ramboot=1` karg used to be baked
> into the image, but the ramboot dracut step hangs the boot on real hardware, so
> it is no longer a default. Whether you flash the image to a USB or install it to
> disk, it **boots a normal disk root**. RAM boot is an opt-in you enable
> deliberately (`powos ramboot enable`). See [Feature Status](#feature-status).

### 1. Installed — a primary/daily-driver OS (the main path)

Install PowOS to an internal disk and run it like any bootc desktop:

- **Normal disk boot.** Boots straight to the desktop; nothing runs from RAM
  unless you opt in with `powos ramboot enable` (a composefs-safe copy-to-tmpfs
  behind `rd.powos.ramboot.installed=1` — deliberately *not* the live auto-karg,
  because overlaying a composefs root on itself once caused a boot loop). That opt-in
  is EXPERIMENTAL.
- **Updates are a pull.** `bootc upgrade` / `powos upgrade` / `powos update os`
  fetch a new base image; `powos update packages` handles layered packages.
- **Config-as-code.** Your setup lives in the repo + your cloud backup, so a
  reinstall restores your environment instead of a day of reconfiguring (the
  "never configure this again" goal — restore loop is [partially implemented](#feature-status)).
- **Dual-boots Windows** for the games Linux can't run (see below).

Build the Anaconda installer ISO, flash it, boot it, and the graphical installer
installs PowOS to disk (see [Build the image](#build-the-image)). The installed
dual-boot design, disk layouts, and rationale live in
[`docs/DUALBOOT-DESKTOP-SPEC.md`](docs/DUALBOOT-DESKTOP-SPEC.md).

### 2. Live USB — the OS runs from RAM (opt-in)

Flash the image to a USB SSD and boot it on any machine. This mode is opt-in:
enable RAM boot (`powos ramboot enable`) and the dracut module copies the layered
OS into a RAM overlay, so the whole system runs from memory — **pull the USB and
your session keeps running**. Changes land in RAM and sync to the USB's persistent
layers every 60s, so they survive reboots — and you can roll back individual layers.

- Take one drive between machines; hardware auto-detection reconfigures on each boot.
- Your customizations persist to the USB; roll back per layer if something breaks.
- `/home` is a direct USB bind-mount by default (see [CacheFS](#user-data) for the
  opt-in, currently-disabled lazy-load path).

> **Status:** layered RAM boot and layer-sync are **implemented but pending
> hardware validation** — both were previously broken on real hardware and the
> fixes have not yet been re-validated on metal. RAM boot is no longer baked on by
> default. See [Feature Status](#feature-status).

---

## Core concepts

### The layer stack

PowOS is **not** a locked-down immutable system. It's layered persistence: writes
go to a RAM upper layer instantly, then sync down into persistent layers you can
roll back independently.

```
┌─────────────────┐
│   RAM (upper)   │  All writes land here first (instant)
└────────┬────────┘
         │ layer-sync every 60s
         ▼
┌─────────────────┐
│  Custom Layer   │  Your packages & configs   → powos rollback custom
└────────┬────────┘
┌─────────────────┐
│  Updates Layer  │  OS updates                → powos rollback updates
└────────┬────────┘
┌─────────────────┐
│   Base Layer    │  Original Bazzite image
└─────────────────┘
```

Install anything → it hits RAM → syncs to the custom layer → persists. If an
update breaks something, `powos rollback updates`; if a package you added breaks
something, `powos rollback custom`; if everything's broken, `powos rollback all`
boots base-only. Rollback sets kernel args via `grubby` and reports failures
loudly — verify with `grep powos /proc/cmdline` after reboot.

### Independent rollback

| Command | What happens | Use when |
|---|---|---|
| `powos rollback custom` | Skip your customizations next boot | A package you installed broke something |
| `powos rollback updates` | Skip OS updates next boot | An OS update broke something |
| `powos rollback all` | Boot base only | Everything is broken |
| `powos rollback reset` | Use all layers again | Ready to try again |

### Chameleon Boot (hardware auto-detection)

On boot PowOS detects GPU, power source and form factor and applies a matching
hardware profile (17 profiles: desktop-nvidia-performance, laptop-intel-battery,
virtual, etc.). One drive works across different machines with zero config.

> The GPU **driver stack** is fixed by the base image you build (see
> [Quick start](#quick-start)) — profiles tune settings but can't swap
> nvidia↔amd at boot. The default base is `bazzite-nvidia-open`.

### systemd-sysext overlays

Custom binaries are merged into `/usr` as systemd system extensions — this is how
`powos dev` installs the apps you build or fork (see
[dev workflow](#the-developer--customization-workflow)).

### User data

By default `/home` is a **direct USB bind-mount** (simple, reliable, needs the USB
connected). **CacheFS** — a FUSE filesystem that lazy-loads home data and keeps
metadata in RAM for unplug resilience — exists but is **incomplete and must stay
disabled**: write-back to USB is not implemented, so written data is lost on
unmount. Do not set `POWOS_CACHEFS_ENABLED=true` until write-back lands.

---

## Quick start

### Test in Docker (no hardware, no risk)

```bash
docker compose up          # builds + starts PowOS with a KDE desktop
# open http://localhost:6091/vnc.html   (password: powos)
docker exec powos powos status
```

In Docker you'll see "Standard" boot mode — correct, since there's no real
initramfs. On real hardware the full RAM boot with layers engages automatically.

### Build the image

The canonical installer is an **Anaconda GUI ISO** (hardware-validated):

```bash
podman build -t localhost/powos .   # build the PowOS image
./build/build-iso.sh                 # → build/output/bootiso/install.iso (Anaconda GUI installer)
# flash install.iso → boot → Anaconda GUI installs PowOS to disk → reboot
powos backup pull                    # restore your config

# or via just:
just installer            # same as above: PowOS image → Anaconda installer ISO
just build-image          # build the OS container image only (faster, for testing)
```

`build/build-iso.sh` with no args builds the container image, then runs
`bootc-image-builder --type anaconda-iso` to produce a proper Anaconda graphical
installer. It lands at **`build/output/bootiso/install.iso`** (also copied to
`build/output/powos-installer.iso`). Anaconda handles disk selection + GPU and
confirms before writing — nothing is touched until you drive the installer.

> **Legacy / experimental (not the supported install path):** the raw-efi
> live/RAM-boot image (`just build-live-usb` → `powos.raw`) and the lean
> custom-wizard installer (`just build-installer` → `powos-installer.raw`) still
> build but are superseded by the Anaconda ISO. The custom wizard has a blind TUI
> and stalls on the GPU; use the Anaconda ISO instead.

The base image is a build ARG (default `ghcr.io/ublue-os/bazzite-nvidia-open:stable`
for RTX / GTX-16+ open modules). Override for other GPUs:

```bash
podman build --build-arg BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable ...   # AMD / Intel
podman build --build-arg BASE_IMAGE=ghcr.io/ublue-os/bazzite-nvidia:stable ...  # older/closed NVIDIA
```

### Flash the ISO and install

Flash **`build/output/bootiso/install.iso`** to a USB with any tool, boot it, and
the Anaconda GUI installer walks you through the install:

```bash
sudo dd if=build/output/bootiso/install.iso of=/dev/sdX bs=4M status=progress conv=fsync
# or: Balena Etcher / Rufus (DD mode)
```

Boot the USB → Anaconda starts → pick your target disk → confirm → install →
reboot. Anaconda handles disk selection, partitioning and GPU itself, with its
own confirmations, so nothing is touched until you drive the graphical installer.
After the first reboot into the installed system:

```bash
powos backup pull                     # restore your config-as-code
```

Future updates are just `bootc switch ghcr.io/powback/powos:nvidia-open` +
`powos upgrade`.

> **Legacy / experimental install paths (superseded by the Anaconda ISO):** the
> in-system `powos install` guided wizard and `powos install-system` raw
> installer still exist, and the raw-efi live image (`powos.raw`) still supports
> a live-USB first-boot self-completion via `install-to-usb.sh --self-complete`.
> These are the old custom paths (blind TUI, GPU stalls, slow boot) and are **not
> the supported way to install** — use the Anaconda ISO above.

---

## Dual-boot, games and Windows

Full design and rationale: [`docs/DUALBOOT-DESKTOP-SPEC.md`](docs/DUALBOOT-DESKTOP-SPEC.md),
[`docs/WINDOWS.md`](docs/WINDOWS.md), [`docs/DUAL-BOOT-VM.md`](docs/DUAL-BOOT-VM.md).

**The reality of anti-cheat:** kernel anti-cheats (EAC/BattlEye/Vanguard — e.g.
Arc Raiders) **block VMs**, so those games need **bare-metal Windows**. Non-anti-cheat
games run **native on Linux via Proton**. PowOS is the primary OS (Docker/AI +
Proton games); Windows is the reboot-into-it escape hatch for anti-cheat.

### Recommended disk layout

Every disk gets one job so you never have to resize:

```
PowOS   → its own disk/partition (btrfs: OS, Docker/AI, Proton prefixes)
Games   → NTFS partition, labeled POWOS-GAMES, shared with Windows
Windows → its own disk/partition (bare metal, anti-cheat-clean)
```

**Why NTFS for shared games:** it's the only filesystem both OSes read natively
(Linux via `ntfs3`, Windows native). Windows has no native btrfs. One installed
copy of each game serves both OSes. **Proton caveat:** Proton prefixes
(`compatdata`/`shadercache`) use filenames illegal on NTFS, so
`powos games steam-setup` keeps them on native btrfs via symlinks — only the game
*files* live on the NTFS share. Every *other* PowOS partition is hidden from
Windows via Linux GPT type GUIDs (no drive letter, no "format this disk?" prompt).

### Commands

```bash
powos games status                 # partition, mount, Steam wiring state
powos games create --size N        # create POWOS-GAMES (named device, plan, confirm, --dry-run)
powos games steam-setup            # Steam library on the shared partition
powos boot windows                 # one-shot reboot into bare-metal Windows, back after
powos vm windows                   # run installed Windows as a KVM guest (no reboot, non-AC only)
powos gpu status | to-vm | to-host # hotswap the dGPU between Linux (CUDA) and a VM
```

> **Status:**
> - `powos games` — implemented, **not yet hardware-validated** (nothing touches a
>   disk except a command you run against a device you name, behind a plan +
>   confirmation + `--dry-run`).
> - `powos boot windows` / `powos vm windows` / `powos gpu` — **hardware-only**,
>   cannot be exercised in CI/Docker (no GPU/IOMMU/vfio/Windows image).
> - **Bare-metal Windows on USB** (`powos windows` — Windows in a single VHDX,
>   native-VHD boot, auto-install from a fetched official ISO) is **experimental /
>   not hardware-validated** and, per the desktop spec, deprioritized in favor of
>   Windows on a normal partition. See [`docs/WINDOWS.md`](docs/WINDOWS.md) and
>   [`docs/PROBLEM.md`](docs/PROBLEM.md) for the hard limits (hibernation through a
>   VHD is impossible).

---

## The developer / customization workflow

PowOS is built to be edited. Two loops: customize **PowOS itself**, and build/fork
**apps**.

### Edit PowOS → test → push (`powos self`)

The complete source is baked into every image at `/var/lib/powos/src`, with the
exact commit it was built from recorded in `/usr/lib/powos/.powos-src-commit`.

```bash
powos self status    # baked commit, git attach state, local edits, ahead/behind
powos self test      # apply your /var/lib/powos/src edits to THIS running system,
                     # transiently (auto-reverts on reboot on installed composefs)
powos self pull      # SAFE update from upstream — never discards local edits
powos self push      # git add -A + commit + push  (-m "message")
```

`powos reload` applies your local changes live without a reboot; `powos reload
--build` does a full local image build + switch for base/package changes. The
durable path for installed systems is **edit → `self push` → rebuild →
`bootc upgrade`**.

### Build or fork apps (`powos dev`)

Build new apps or fork existing ones (e.g. KDE apps) into systemd-sysext overlays:

```bash
powos dev new myapp                 # new project from scratch
powos dev new --ai "CLI that converts JSON to YAML" jsonyaml   # AI project generator
powos dev fork kde:dolphin          # fork an upstream app
powos dev build myapp               # build to an overlay
powos dev enable myapp              # merge into /usr (overrides system version)
powos dev update dolphin            # pull upstream changes (forks)
```

`src/` is your editable copy; `upstream/` is read-only reference (forks). Same
workflow for new apps and forks.

### Config-as-code + cloud backup

The "reinstall and I'm home" loop: your projects, overlay sources, container
definitions and PowOS config back up to a git repo; a fresh install pulls them
back.

```bash
powos backup setup <url>            # configure the cloud repo
powos backup push                   # push USB/system state to cloud
powos backup pull                   # restore on a fresh install
powos backup ignore "pattern"       # tune .syncignore (node_modules, secrets, etc. excluded by default)
```

> **Status:** cloud backup is **git-based and partially implemented / not fully
> validated** — and it's the least-proven, highest-value code in the repo (the
> restore loop is the actual "never rebuild" core). Treat restore as
> work-in-progress until you've tested it end-to-end.

---

## AI integration

PowOS ships a configurable AI agent system (`powos ai`) with multiple agents,
clients, flavors and sessions. It's **implemented**; what it can actually do
depends on which AI client you have installed (`claude`, `gemini`, or a local
`ollama`).

```bash
powos ai "help me set up this project"
powos ai --agent coder "review this function"
powos ai --agent health "is my system healthy?"
powos ai --agent containerizer:python "containerize this flask app"
powos ai --client ollama "local inference"     # or --client claude|gemini
powos ai -i                                     # interactive chat
powos ai -s myproject "continue..."             # named sessions with context
powos ai agents                                 # list agents + flavors
```

| Agent | Purpose | Flavors |
|---|---|---|
| `assistant` | General purpose (default) | — |
| `coder` | Coding help | `:review` |
| `devops` | System admin, containers | — |
| `health` | PowOS diagnostics | `:sync`, `:layers` |
| `creator` | Project generator | — |
| `containerizer` | Container config generator | `:python`, `:node` |

Aliases: `docker`, `pod`, `container` → `containerizer`.

The health and boot-debug flows are AI-native:

```bash
powos health --ai        # diagnose system health with the health agent
powos doctor --ai        # collect a boot diagnostic bundle + have the agent diagnose it
```

> **Status:** the agent framework, dispatch, flavors and sessions are implemented.
> A working AI client (Claude/Gemini/Ollama) must be present and configured;
> without one, `powos health` shows "No AI clients found". Local Ollama needs
> manual setup.

---

## Discoverability

```bash
powos menu        # guided, categorized interactive menu that dispatches real commands
powos help        # full usage text
powos overview    # one-glance panel: model, image, GPU/CUDA, deploys, disk
```

---

## Command reference

`powos <command>`. This is a selection — run `powos help` or `powos menu` for the
complete, current surface.

**Status & health:** `status`, `overview`, `services`, `health [--ai]`, `safe`,
`hardware`, `profile`, `layers`, `version`

**Sync & backup:** `sync [status|resolve|diff|--keep-ram|--keep-usb]`, `flush`,
`backup [status|push|pull|setup <url>|ignore]`

**Updates & self:** `update [os|packages|apply|self]`, `upgrade [--check]`,
`reload [--pull|--build]`, `self [status|test|pull|push]`

**Layers & rollback:** `layers [status|sync|clear custom|clear updates]`,
`rollback [custom|updates|all|reset]`

**Install & boot:** `install`, `install-system [--alongside|--whole-disk|--dry-run]`,
`ramboot [status|enable|disable|reset]`, `base [list|switch|add|remove]`,
`boot [list|windows|next]`, `driver [status|stable|testing]`

**Games, Windows, GPU:** `games [status|create|mount|steam-setup]`,
`windows [status|create|install|finalize|snapshot|vm]`, `vm [status|windows]`,
`gpu [status|to-vm|to-host]`, `cuda [enable|enter|run|status|disable]`

**Packages & containers:** `install PKG` (routes flatpak → sandbox → asks before
touching the OS), `install -c NAME [-e] PKG`, `containers [list|create|enter|assemble|prune]`,
`build [path|iso|test|image]`, `registry [login|status]`

**Dev & AI:** `dev [new|fork|build|enable|disable|update]`,
`ai "prompt" [--agent|--client|-i|-s]`

**Recovery:** `doctor [--ai|--offline|--target auto]`, `menu`

---

## Feature status

Adapted from [`CLAUDE.md`](CLAUDE.md) — the authoritative status source.

| Feature | Status | Notes |
|---|---|---|
| Layered RAM boot (live USB) | 🧪 Opt-in, HW validation pending | OS in RAM, layers from USB; **no longer baked on by default** (`powos ramboot enable`); previously broken on real hardware, fix awaiting validation |
| Hardware detection (17 profiles) | ✅ Implemented | Auto-selects on boot |
| Layer sync (RAM→USB, 60s) | ✅ Implemented, HW validation pending | Whiteout translation, USB disconnect guard, failure notifications |
| systemd-sysext overlays | ✅ Implemented | Custom binaries merged into /usr |
| `powos dev` (build/fork apps) | ✅ Implemented | New projects + forks as overlays |
| `powos self` (edit PowOS loop) | ✅ Implemented | Baked source + safe pull; transient on installed composefs |
| Container dev (Distrobox) | ✅ Implemented | Mutable dev containers |
| Rollback (custom/updates) | ✅ Implemented | grubby can fail — verify via `grep powos /proc/cmdline` |
| AI agent system (`powos ai`) | ✅ Implemented | Needs a configured client (Claude/Gemini/Ollama); Ollama is manual |
| Install to disk (whole-disk) | 🚧 New, needs HW validation | `bootc install to-disk`; guided wizard |
| Dual-boot install (`--alongside`) | 🚧 Experimental | Partition free space + reuse Windows ESP; `TODO(hw)` |
| Shared games partition (`powos games`) | ⚠️ Implemented, not HW-validated | NTFS POWOS-GAMES shared with Windows; Steam wiring |
| Windows dual-boot / VM / GPU hotswap | 🚧 Hardware-only | Can't be tested in CI/Docker; keep a TTY/SSH the first time |
| Bare-metal Windows on USB (`powos windows`) | 🚧 Experimental | VHDX native-boot; deprioritized vs. a normal Windows partition |
| Installed OS-in-RAM (`powos ramboot`) | 🧪 Experimental (opt-in) | Composefs-safe copy-to-tmpfs; separate karg to avoid the boot-loop incident |
| Cloud backup / restore loop | ⚠️ Partial | git-based; least-proven, highest-value; not fully validated |
| Sync conflict detection | ⚠️ Partial | Detection works; `--merge` is basic, may need manual help |
| Mobile mode (USB-free) | 🚧 WIP | Copies OS to RAM but live remount not implemented — reboot required |
| CacheFS (lazy-load home) | 🚫 Incomplete — keep disabled | Write-back to USB not implemented; written data is lost |
| Tier-2 VM testing | ❌ Missing | Only Docker/tier-1 tests exist |

---

## Troubleshooting

```bash
powos status                 # layers, RAM, USB, protection
powos health                 # health check with issues/warnings
powos health --ai            # AI-assisted diagnosis
powos doctor                 # boot diagnostic bundle → /var/log/powos/
grep powos /proc/cmdline     # verify RAM boot / rollback kargs took effect
cat /run/powos/layer-sync-status.json    # layer sync state
```

Recovery is designed to be survivable: an always-visible 5-second boot menu lets
you pick the previous bootc deployment, RAM boot self-heals after 3 failed
attempts, and Safe mode + AI Debug recovery entries exist. Details in
[`docs/BOOT-ARCHITECTURE.md`](docs/BOOT-ARCHITECTURE.md).

### Testing

```bash
docker compose up --build -d
docker exec powos bash   /var/lib/powos/src/test/tier1/test-hardware-detect.sh
docker exec powos bash   /var/lib/powos/src/test/tier1/test-overlay.sh
docker exec powos python3 /var/lib/powos/src/test/tier1/test-layer-sync.py
```

Docker/tier-1 covers logic (hardware detection, overlays, package install, layer
sync units, CacheFS units). Real overlayfs RAM boot, USB sync, FUSE mounts,
rollback across reboots and profile application need real hardware or a VM.
**Tier-2 VM testing infrastructure does not exist yet** — there is no automated
test suite for real-hardware behavior.

---

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — the fullest, most current technical reference (start here)
- [`docs/DUALBOOT-DESKTOP-SPEC.md`](docs/DUALBOOT-DESKTOP-SPEC.md) — installed dual-boot design, disk layouts, runbook
- [`docs/BOOT-ARCHITECTURE.md`](docs/BOOT-ARCHITECTURE.md) — boot chain, ramboot, self-heal, recovery
- [`docs/WINDOWS.md`](docs/WINDOWS.md) — Windows-on-USB VHDX design + exposure contract
- [`docs/DUAL-BOOT-VM.md`](docs/DUAL-BOOT-VM.md) — reciprocal VM, GPU passthrough, anti-cheat reality
- [`docs/PROBLEM.md`](docs/PROBLEM.md) — why seamless bare-metal Windows has a hard limit
- Deeper design notes: [`docs/RAMFS-DESIGN.md`](docs/RAMFS-DESIGN.md), [`docs/SYNC-ARCHITECTURE.md`](docs/SYNC-ARCHITECTURE.md), [`docs/HOMEFS-DESIGN.md`](docs/HOMEFS-DESIGN.md), [`docs/OVERLAY-ARCHITECTURE.md`](docs/OVERLAY-ARCHITECTURE.md), [`docs/MULTI-VARIANT-USB.md`](docs/MULTI-VARIANT-USB.md)

## Credentials

```
VNC password: powos
User login:   powos / powos
```

## License

MIT
