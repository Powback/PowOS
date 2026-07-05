# PowOS Desktop Dual-Boot — Install Spec & Build Plan

> **Purpose:** durable capture of the desktop dual-boot design + build plan agreed
> in the 2026-07 planning sessions, so any future session (or a fresh context) can
> pick up exactly where we are. This is the source of truth for the installer /
> Windows-on-USB / disk-layout work. Update it as decisions change.

**Status:** planning done, implementation starting. Desktop-boot-fixed `powos.raw`
rebuilding (see §11). Nothing installed on the user's desktop yet.

---

## 1. The actual goal (distilled from the user)

The user cut through the accumulated ambition to a small, concrete target:

1. **Install PowOS on the desktop (installed, NOT live-USB)** — easy updates,
   config-as-code, so a future reinstall is "everything already set up for me,
   never configure this shit again."
2. **Dual-boot Windows on the same machine** for anti-cheat games (Arc Raiders /
   EAC / BattlEye) that don't work on Linux. Linux is primary (Docker/AI training
   + Proton games); Windows is the reboot-into-it escape hatch for anti-cheat.
3. **Push app/config changes to GitHub** when he modifies things → reinstall pulls
   them back. This is the "never rebuild" core.

**Explicitly deprioritized (shelved, not deleted):** the live-USB "run my home PC
anywhere (laptop/Steam Deck)" idea. It was the ORIGINAL vision but is not the
current focus. The installed desktop must be boringly reliable first.

**Shelved machinery** (source of past pain, keep OUT of the installed boot path):
layered RAM boot, layer-sync daemon, CacheFS, mobile mode, Windows-in-a-VHDX,
reciprocal VMs, GPU-to-VM hotswap. The 2026-07-04 boot-loop that bricked the
desktop was live-USB ramboot machinery leaking into the installed composefs path.

---

## 2. Hardware (the desktop)

- **2× 4TB NVMe SSD**, currently in **RAID0 set in BIOS = Intel VMD/RST firmware
  RAID** ("fake RAID").
- Currently holds only the **borked PowOS install** (no Windows present).
- User is open to (but not committed to) buying a **250GB SSD** for Windows.
- The machine I (the agent) run on is a *separate* Windows box; I cannot touch the
  desktop's disks. All hardware steps are the user's to run, from a runbook.

---

## 3. Decisions (with rationale)

### 3.1 DROP the RAID0 → two independent disks
Confirmed by real-world research (see §Sources):
- **Gaming benefit ≈ zero** — games are random-I/O + CPU/GPU bound; NVMe RAID0 only
  helps raw sequential throughput, which games don't use. A single modern NVMe is
  already past the point striping helps play.
- **Firmware RAID0 + Linux/Windows dual-boot is a documented nightmare** — Intel
  VMD hides the NVMe behind the controller; Windows Setup needs an F6 RST/VMD
  driver; Linux needs IMSM handling; and flipping RST↔AHCI later **bricks whichever
  OS is already installed**. Universal fix in the threads: disable VMD/RST → AHCI.
- **RAID0 sabotages "never rebuild"** — zero redundancy; either stick dies = total
  loss (OS + configs + games + AI data).
- **Timing:** the desktop only has a borked install to lose, so **now** is the one
  safe moment to kill the array (flip it after an OS is installed and you brick it).
- If sequential throughput is ever wanted for AI datasets: do a **Linux-side btrfs
  stripe on a data directory only**, never touching boot/dual-boot.

### 3.2 Windows = a normal partition (NOT the VHDX file)
- The `windows.vhdx` native-boot design's whole reason to exist is "Windows owns
  zero real partitions." That's moot once Windows lives on its own disk / a plain
  slot. A normal partition is simpler, reliable, supports hibernation + in-place
  feature updates, and is 100% anti-cheat-clean (real bare metal).
- The VHDX path is EXPERIMENTAL / never hardware-validated and always cold-boots
  (winresume can't read a hiberfil inside a VHD). Keep it available as the "I refuse
  to let Windows own any partition" option, but it is NOT the default.

### 3.3 Shared games = an NTFS partition (the one FS both OSes read natively)
- Windows has NO native btrfs support. The third-party **WinBtrfs** driver exists
  but is rejected: risking the OS-bearing btrfs to a third-party Windows FS driver,
  with unknown perf + anti-cheat behavior, is a bad trade.
- **NTFS is the lingua franca:** Linux reads it natively (`ntfs3`), Windows natively.
  So the shared games library is an **NTFS** partition; which disk it sits on is
  then free. One installed copy of each game serves both OSes.
- **Proton caveat (already handled by `powos games steam-setup`):** Proton prefixes
  (`compatdata`/`shadercache`) use filenames illegal on NTFS → keep them on btrfs
  via symlink; only the game *files* live on the NTFS share.
- **Games + Windows stay SEPARATE partitions** so you can wipe/reinstall Windows
  without losing the games library, AND so Linux mounts the clean games partition
  rather than Windows' live C: (Fast-Startup/hibernation makes mounting C: from
  Linux corruption-risky).

### 3.4 Sizing — no resize needed by design
- **Windows partition ~150GB** (OS + updates + page file only; games live
  elsewhere so it never grows). 128–200GB all fine; it's a rounding error on 4TB.
- **Games partition = "the rest"** of its disk (already huge).
- **Resize is deliberately hard/refused** (`powos games resize` errors out; in-place
  NTFS resize between occupied partitions is the riskiest disk op). The design
  avoids ever needing it: Windows is fixed-small, games is disk-sized. Size once.

---

## 4. Disk layouts (installer must support BOTH, user picks)

```
Layout A — with a 250GB SSD for Windows (cleanest isolation):
  250GB SSD    → Windows (whole disk, own ESP; wipe/reinstall freely)
  4TB NVMe #1  → PowOS (btrfs: OS, Docker/AI, Proton prefixes)
  4TB NVMe #2  → Games (NTFS, whole disk — one copy, both OSes)

Layout B — just the two 4TB (nothing to buy):
  4TB NVMe #1  → PowOS (btrfs, whole disk)
  4TB NVMe #2  → Windows (~150GB) + Games (NTFS, the rest)
```

Both give "reinstall Windows without losing games." Every disk has ONE job → no
sizing regret. Linux partitions carry Linux GPT type GUIDs → invisible to Windows
(no drive letter, no "format this disk?" prompt). Windows only ever sees its own
volumes + the NTFS games share.

---

## 5. The all-in-one USB — 3-entry boot menu

**Live PowOS / Install PowOS / Install Windows.** (Live Windows REJECTED — see below.)

- **Live PowOS / Install PowOS** — exist today (BLS entries via `install-to-usb.sh`).
- **Install Windows** — NEW work: a boot entry that chainloads Windows Setup off a
  USB partition holding the slimmed official ISO + injected `autounattend.xml`.
  Bounded, known-solved (Rufus/Ventoy prove it); mark EXPERIMENTAL until validated.

**Live Windows — REJECTED.** = Windows To Go, which Microsoft deprecated/removed.
It's slow off USB, licensing-gray, and **kernel anti-cheat hates it** — the exact
opposite of what the user needs Windows for. Delivers nothing; adds the flakiest
entry. Off unless the user explicitly insists.

---

## 6. The "stripped Windows ISO" — the correct, honest model

- **Fetch the OFFICIAL Microsoft ISO** (`win_fetch_official_iso()` → `mido`, an
  auditable Fido reimplementation hitting Microsoft's official download API).
  **Never a third-party `tiny11` mirror** (supply-chain risk — you'd install an OS
  from an unverified stranger).
- **Slim it locally** with our own transparent debloat pass (`powos windows slim`,
  to be finished) — rip appx bloat/telemetry → your own auditable tiny11-equivalent.
- **Inject `autounattend.xml`** (`win_build_autounattend()`) for zero-touch Setup:
  skip product key, skip OOBE, create the user. Windows-side Steam + shared-library
  wiring via FirstLogonCommands / a post-install script.
- **HARD CONSTRAINTS:**
  - The published PowOS image (ghcr) **must NEVER contain Windows** — that's
    redistributing MS's OS (illegal) and would bloat the image.
  - The ISO is **fetched onto the USB at setup time** as a user-initiated step.

---

## 7. What already exists in the code (scaffolding inventory)

- **`lib/install-wizard.sh`** — step flow `iwz_step_disk → mode → sizes → gpu →
  identity → ssh → ramboot`; vars `IWZ_DISK`, `IWZ_GAMES_GB`, `IWZ_WINDOWS_GB`;
  `iwz_build_installer_args()` (PURE, unit-tested) maps `IWZ_DISK→--disk`,
  `IWZ_GAMES_GB→--shared-gb`, `IWZ_WINDOWS_GB→--windows-gb`. **Single-disk today.**
- **`lib/install-system.sh`** — `ISV_TARGET`, `ISV_MODE` (alongside|whole-disk),
  `ISV_SHARED_GB`, `ISV_WINDOWS_GB`, `isv_auto_reserve_gb`, `isv_detect_windows`;
  layout is `[ PowOS root | POWOS-GAMES | unallocated Windows tail ]` **all on the
  one target disk**. Whole-disk uses `bootc install to-disk`; `--alongside` is
  EXPERIMENTAL (TODO(hw)).
- **`lib/games.sh`** — `gms_create --disk D --size N` (POWOS-GAMES on ANY disk —
  reuse this for the cross-disk case), `steam-setup` (compatdata→btrfs symlinks),
  `gms_resize` refuses by design.
- **`lib/windows.sh`** — `win_fetch_official_iso` (mido, official only),
  `win_build_autounattend` (zero-touch), Steam fetch (Valve CDN), partition backend
  (`win_part_*`) + vhd backend (`win_*`), fetch-iso/slim knobs. **All hardware-
  facing paths EXPERIMENTAL / TODO(hw).**
- **`build/install-to-usb.sh`** — reserves POWOS-GAMES + Windows tail on the USB;
  `write_bls_entries` (Install/Recovery); `--self-complete`; sourceable. **No
  "Install Windows" boot entry yet.**
- **`Containerfile`** — display manager wired (`plasmalogin` enabled + add-wants
  graphical.target + set-default graphical, commit e833830); unit files forced 0644
  (b8a105b); base = `bazzite-nvidia-open:stable`.

---

## 8. Build plan (priority order + acceptance criteria)

1. **[in progress] Deliver the desktop-boot-fixed `powos.raw`.**
   Rebuild with e833830 (plasmalogin wiring) + hydrate HOME + b8a105b (unit modes).
   *Accept:* QEMU (virtio-gpu, OVMF CODE+VARS) boot reaches `graphical.target` /
   plasmalogin paints a login. Delivered to `C:\Users\Pow\PowOS-USB\powos.raw`.

2. **Multi-disk installer flow.**
   Wizard: pick PowOS disk, pick games/Windows disk (default = same as PowOS disk),
   sizes (Windows ~150GB default, games = rest). New `IWZ_GAMES_DISK` → new
   `install-system --games-disk`. When games disk ≠ target, create POWOS-GAMES +
   Windows slot on that disk (reuse `games.sh` create logic) instead of tail-carving
   the PowOS disk. Single-disk behavior unchanged when games disk == target.
   *Accept:* unit tests for `iwz_build_installer_args` (multi-disk) + layout
   planning pass in Docker/tier-1; `--dry-run` prints correct plan for Layouts A & B.

3. **"Install Windows" USB entry.**
   `powos windows fetch-iso --slim --to-usb` places slimmed official ISO +
   autounattend on a USB partition; `install-to-usb.sh` adds a chainload boot entry
   (GRUB→bootmgfw.efi). Handle install.wim >4GB (split or UEFI:NTFS shim).
   *Accept:* boot entry written + unit-tested; documented as EXPERIMENTAL.

4. **`powos windows slim`.** Debloat the official ISO (remove appx/telemetry),
   re-pack, keep it bootable. *Accept:* pure parts unit-tested; produces a smaller
   bootable ISO from an official one.

5. **Steam Windows-side wiring.** Post-install script/README: install Steam + add
   `<letter>:\SteamLibrary` so the shared games light up on Windows too.

6. **[deeper goal] Harden the backup → hydrate → restore loop.** The actual "never
   rebuild" core, and the least-proven code in the repo (hydrate failed every boot
   until the HOME fix). *Accept:* reinstall + `backup pull` gets fully home < 1hr.

---

## 9. Runbook (what the USER does, on the metal)

1. **BIOS:** disable VMD/RST (delete the RAID0 volume) → AHCI. Confirm BOTH NVMe
   appear as separate plain disks. (⚠️ this wipes the striped borked install — if
   anything on it isn't already in git, pull it first via the live USB +
   `mdadm --assemble` before flipping.)
2. *(Optional)* install the 250GB SSD if going Layout A.
3. **Flash** `powos.raw` to a USB (Rufus / Balena Etcher / `dd`). Verify it's the
   right device.
4. Boot USB → **Install PowOS** → multi-disk wizard: PowOS → NVMe #1; games (+
   Windows slot ~150GB) → NVMe #2 (or the 250GB SSD for Windows in Layout A).
5. **Install Windows** — RECOMMENDED FIRST TIME: burn a normal Windows USB and
   install into the Windows partition/SSD (boring, 100% reliable, anti-cheat-clean).
   The USB "Install Windows" entry is the automated alternative once validated.
   Tip: installing Windows FIRST on the SSD (NVMes blank) keeps the only ESP on the
   Windows disk → clean separation; then install PowOS.
6. `bootc switch ghcr.io/powback/powos:nvidia-open` → future updates are a pull.
7. `powos games steam-setup`; on Windows add `<letter>:\SteamLibrary`.
8. `powos backup setup <repo>` → push state.
9. **Acceptance test:** deliberately reinstall PowOS + `backup pull`. Home in < 1hr
   = the "never again" goal is proven.

---

## 10. Decisions / open items

- **RESOLVED — Layout: A, via a transplanted Windows disk.** The user will move a
  **PCIe/NVMe SSD that already has Windows installed** from his old PC into the
  desktop. So Windows needs NO fresh install:
  ```
  Transplanted PCIe SSD → Windows (already installed, its own ESP)
  4TB NVMe #1           → PowOS (btrfs)
  4TB NVMe #2           → Games (NTFS, whole disk)
  ```
  **Pre-move checks (do BEFORE pulling the drive):**
  1. **BitLocker/device encryption** — if on (common on Win11 24H2), a hardware move
     demands the 48-digit recovery key or you're locked out. Grab the key
     (account.microsoft.com/devices/recoverykey) or decrypt first. Check via
     `manage-bde -status` / Settings→Device encryption.
  2. **Storage mode** — if the drive ran under Intel RST/VMD in the old PC it will
     `INACCESSIBLE_BOOT_DEVICE` on the AHCI desktop; only move it from a plain
     AHCI/NVMe setup (or prep the AHCI driver first).
  3. Minor: activation may re-prompt (unactivated is fine for gaming); carries old
     driver cruft (works; clean-install later if wanted).
  Needs a **free M.2 slot** (or PCIe→M.2 adapter) — this is a 3rd NVMe.
- **CONSEQUENCE — "Install Windows from USB" + stripped-ISO work is now
  FUTURE/OPTIONAL**, not needed to get running (Windows arrives pre-installed on the
  transplanted disk). Keep in the plan (§8.3–8.4) but deprioritize; focus the build
  on the multi-disk PowOS installer (§8.2) + games wiring (§8.5).
- **Live Windows:** rejected; reopen only if the user insists.
- **Fallback if the transplant fails the pre-checks:** buy a cheap 250GB SATA SSD
  (Layout A) and fresh-install Windows, or Layout B (Windows partition on the games
  disk). Installer supports all three.

---

## 11. Current build / repo state (update as it moves)

- Branch `master`; relevant fixes landed: e833830 (plasmalogin/display-manager
  wiring — desktop actually reaches KDE now), hydrate `${HOME:-/root}`, b8a105b
  (unit files 0644), base → `bazzite-nvidia-open`.
- **A stale `powos.raw` was delivered earlier that boots only to a TEXT console**
  (built before e833830 — display manager wasn't wired). It is being replaced by a
  rebuild that includes the fix. Do not trust any raw built before e833830.
- QEMU boot-test harness that works: OVMF **CODE + writable VARS** pflash (both
  units, non-secboot), `-vga virtio` (Plasma 6 needs DRM to paint), screendump via
  QMP `-monitor unix` socket + `socat` + PPM→PNG. Serial (`console=ttyS0`, already
  in kargs) stops at the graphical handoff. First-boot self-completion + no boot
  loop + self-heal counter CONFIRMED working in QEMU.

---

## 12. Hard constraints (do not violate)

- **Never use `sed`** (user's standing rule).
- **Never touch the user's real host disks** (C/D/E/F, block devices) without
  explicit per-action confirmation. Containers/VMs OK. Ask before privileged /
  block-device runs.
- **No Windows OS baked into the published PowOS image** (redistribution) — always
  fetch official at setup time.
- Boot-path / initramfs / kargs changes get a QEMU boot test before they can be
  trusted on hardware (the boot-loop lesson). CI can't (no KVM on GH runners).

---

## Sources (research backing §3.1 / §3.3)

- Intel VMD/RST NVMe dual-boot problems: Tom's Hardware, Manjaro forum threads.
- NVMe RAID0 gaming ≈ zero benefit: DiskInternals, Evetech "NVMe RAID0 worth it 2025".
- Shared Steam library on NTFS + compatdata symlink: ValveSoftware/Proton wiki + issue #7669.
- Windows native-boot VHDX alongside Linux: Microsoft Learn "boot to VHD".
