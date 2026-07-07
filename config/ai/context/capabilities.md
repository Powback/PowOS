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

## Games partition & bare-metal Windows (NEW)
- `powos games {status|create|mount|steam-setup|resize}` — first-class shared NTFS
  partition, label POWOS-GAMES, deliberately visible to Windows (all other PowOS
  partitions hidden via Linux GPT type GUIDs — no drive letter, no format prompts).
  Created at USB flash (`install-to-usb.sh --games-gb N`), by the installer
  (`--shared-gb`, now labeled POWOS-GAMES), or later via
  `powos games create --size N [--disk D] [--dry-run] [--yes]`. `steam-setup`
  mounts at /var/mnt/games (ntfs3, uid/gid, windows_names), creates
  SteamLibrary/steamapps, keeps Proton compatdata/shadercache on native btrfs via
  symlinks (prefixes break on NTFS), registers in libraryfolders.vdf (Steam must
  be closed), drops GAMES-README.txt for the Windows side. One installed game
  serves both OSes. `resize` is a stub. ⚠️ implemented CLI, hardware validation
  pending.
- `powos windows {status|create [--size N] [--fixed-vhd]|fetch-iso [--slim] [--hash]|
  slim <iso>|install [--iso PATH] [--fetch] [--slim]|finalize|snapshot|snapshots|
  rollback|vm}`, plus `--backend vhd|partition` (default vhd). DEFAULT BACKEND:
  Windows lives in ONE FILE (`<POWOS-GAMES>/PowOS-Windows/windows.vhdx`,
  thin/dynamic), no partition of its own. ALT BACKEND (`WINDOWS_BACKEND=partition`
  in /etc/powos/windows.conf, or `--backend partition`): a dedicated WIN-ESP +
  POWOS-WIN carved from the burn-time `--windows-gb` unallocated tail, giving
  Windows plain metal + REAL hibernation (both backends keep every Linux partition
  invisible to Windows via GPT type GUIDs). `fetch-iso` downloads the OFFICIAL MS
  ISO (verified, never a prebuilt third-party image) and `--slim` debloats it
  natively (wimlib, tiny11-style) — install `--fetch` chains this. Install is
  zero-touch (autounattend: keyless edition-select, TPM/SB bypass, OOBE skipped)
  and preloads Steam pointed at the shared POWOS-GAMES library. User supplies ISO
  + license; PowOS ships no MS bits. Bare-metal boots via native VHD
  boot (bootmgr on the SHARED PowOS ESP, backed up before install); the same file
  also boots as a KVM guest (`vm`, implemented — VM-hibernation is the supported
  resume path). Bare `powos windows` = the guarded switch: flush + stop layer-sync
  → guards → unmount POWOS-GAMES → BootNext → hibernate PowOS (`--reboot` fallback
  until hibernation ships). **Metal Windows always COLD-BOOTS** (winresume can't
  read a hiberfil inside a VHD — no bare-metal session resume; PowOS's own session
  survives via S4). Snapshots = whole-file zstd copy on POWOS-DATA (NOT ntfsclone).
  Native-VHD costs: dynamic image expands toward full --size on first metal boot,
  and in-place feature updates are blocked. 🚧 implemented CLI, hardware validation
  pending — do NOT present the switch or install as proven; see docs/WINDOWS.md.
- Machine-local model: the USB is also an installer and gets unplugged after
  installing to a desktop/laptop/Steam Deck SSD — so the POWOS-GAMES partition (and
  the windows.vhdx file on it) is per-machine, created on that machine's own
  PowOS-owned disk. Installed systems receive these commands via normal bootc
  updates and run create once (no reflash).
- Safety: nothing touches a disk except a user-run command against a device the
  user names, behind plan display + confirmations + `--dry-run`.

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
- Dev / modding — TWO paths, pick by whether you want it committed:
  - **Runtime, per-machine** (`powos dev`): `new`/`fork`/`build`/`enable`/`disable`/
    `update`, `--ai` gen, plus native app override — `override <app>` seeds a
    COMPLETE sysext shadow of a base app (edit → `enable` auto-builds → `disable`
    restores base), `overrides` lists them, `override --diff <n>` shows what changed.
    Projects live in /var/lib/powos/projects — **NOT committable**. Override of a
    base app is ⚠️ untested overlay-on-overlay (TODO(hw)).
  - **Committable, baked into every build** (`sources/<name>/`): edit upstream
    source, save a `.patch` under `sources/<name>/patches/<app>/` — upstream is
    gitignored, patches are committed (Fedora-style); the image build applies them.
    `powos dev patch <name> [desc]` generates the patch from a fork straight into
    `sources/…` (KDE → `sources/kde/patches/<app>/`). **Use THIS, not `dev`, for
    permanent/version-controlled mods** (e.g. patch Dolphin).
  - KDE start menu (Kickoff) is Plasma, not a standalone app → config/widget, not override.
- Overlays (systemd-sysext) via `powos dev` / `overlay-manager.sh`; extension-release
  uses `ID=_any` so it merges on any host (Bazzite included). ✅
- Hibernation / session-resume (hop to Windows for anti-cheat games, resume the
  Linux session on return) — ❌ SPEC ONLY, not built, blocked on persistence
  validation. See docs/HIBERNATION.md. `powos boot windows` (UEFI BootNext,
  one-shot reboot to Windows) IS built. ✅

## Game modding (`powos mods`)
- Install mod managers on-demand: `powos mods install nexus-mods-app`
  (AppImage, native Linux, Nexus's own — replaces old Vortex which was
  Windows-only). Also `install vortex` (documents the Proton wrapper path,
  doesn't auto-install). `mods installed` lists installed managers.
- One-shot game modding prep: `powos mods setup <game>` — installs
  protontricks, runs winetricks packages (`vcrun2022`, `d3dcompiler_47`)
  into the game's Proton prefix, sets `WINEDLLOVERRIDES="winmm=n,b;version=n,b" %command%`
  in Steam's per-user launch options. Requires Steam CLOSED for the config
  edit. Short names: cyberpunk, skyrimse, skyrim-ae, fallout4, starfield,
  witcher3, bg3 — plus any numeric appid. ✅
- **Nexus Mods App CLI** (undocumented but exists): `powos mods` wraps
  the AppImage's own `as-main` subcommands. Auth persists in the app's
  data model — a GUI login is visible to all subsequent CLI calls, no
  re-auth needed.
  - `powos mods auth [api-key]`: key = save API key; no arg = OAuth login.
  - `powos mods logout` / `games` / `tools <game>` / `run-tool <game> <tool>`.
  - `powos mods install-collection <slug>`: installs a whole Nexus
    collection headlessly. Slug is from the URL
    `nexusmods.com/<game>/collections/<slug>`. **NMA GUI must be closed.**
  - `powos mods install-mod <game> <mod-id> [file-id]`: constructs a
    `nxm://` URL and uses `protocol-invoke` — works whether the GUI is
    running or not (running instance receives it). Game accepts either a
    short name (cyberpunk, skyrimse, bg3, …) or a Nexus URL slug.
  - `powos mods raw <args>`: forward to `NexusModsApp as-main` for
    subcommands PowOS hasn't wrapped (heartbeat, extract-archive,
    datamodel, etc.).
- Workflow for AI-driven collection install:
  1. Ensure NMA installed: `powos mods install nexus-mods-app`.
  2. Ensure game modding-prep done: `powos mods setup <game>` (once per
     game). Requires Steam closed. On success, WINEDLLOVERRIDES is set.
  3. Ensure NMA GUI is closed for `as-main` commands.
  4. `powos mods install-collection <slug>` — hands-off collection install.
  5. Relaunch Steam and the game; mods are deployed by NMA.
- Cyberpunk specifics: mod framework stack is CET + RED4ext + REDscript.
  The `setup` command installs the winetricks packages CET needs;
  RED4ext/REDscript are managed by NMA once auth is in place.
- Steam Workshop is deliberately separate — it's built into Steam
  itself, no PowOS wrapper needed. `powos mods` covers off-Workshop
  modding (Nexus + REDmod tooling).

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
- GPU hotswap (`powos gpu status|to-vm|to-host`): dynamically bind the dGPU
  between the host (nvidia → CUDA/native games) and vfio-pci (VM passthrough),
  so it's NOT permanently dedicated to vfio and CUDA keeps working. `vm windows
  --gpu` auto-does to-vm → launch → to-host. ⚠️ Hard prereqs: IOMMU on; the
  DESKTOP must run on the OTHER GPU (iGPU) or releasing the dGPU freezes the
  session (to-vm refuses while in use). Pure logic unit-tested; real bind/unbind
  needs hardware. Whole IOMMU-group slot (GPU + HDMI-audio) moves together.
- Anti-cheat reality (IMPORTANT, don't over-promise): kernel anti-cheats
  (EAC/BattlEye/Vanguard — e.g. Arc Raiders) BLOCK VMs and may flag them, so
  anti-cheat games CANNOT run in `vm windows` — they need BARE-METAL Windows
  (`powos boot windows`, a reboot). Non-anti-cheat games should run NATIVE on
  Linux (Steam/Proton) — no VM. The Windows VM is for productivity + non-AC
  Windows-only titles. "Both OSes native at once, no VM" is physically impossible.
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
