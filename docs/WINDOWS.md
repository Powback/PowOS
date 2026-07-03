# Bare-Metal Windows on the PowOS USB — Design Spec

**Status: CLI implemented (`lib/games.sh`, `lib/windows.sh`), not yet
hardware-validated.** Every hardware-facing path is marked `TODO(hw)` in the
code. The switch depends on PowOS-side hibernation (`docs/HIBERNATION.md`)
shipping; until then `powos windows --reboot` is the fallback. Companion to
`docs/HIBERNATION.md` (the PowOS-side session-resume half), `docs/PROBLEM.md`
(why this design and not the alternatives), and `docs/DUAL-BOOT-VM.md` (the VM
half).

## Goal

One 4TB PowOS USB carries a full Windows that:

1. **Bare-metal boots** for kernel anti-cheat titles (EAC/BattlEye — VMs are
   detected and blocked; this is the only workload that needs metal).
2. **Also boots as a KVM guest** from PowOS for non-anti-cheat Windows work —
   the *same image*, no second install.
3. **Never touches internal disks, and never gets a partition of its own.**
   No internal partitioning, no second SSD, no carve step even on the USB.
   Windows is a single file; the worst it can ever do is damage that file (and
   the POWOS-GAMES volume that holds it, which is Windows-visible by design).
4. Is **snapshottable and rollback-able** from PowOS, like every other PowOS
   layer.

**Session resume across the switch is asymmetric — read this carefully:**
- **PowOS's own session always survives** the switch, via PowOS-side **S4
  hibernation** (Linux writes its whole RAM overlay to USB swap and resumes on
  return — `docs/HIBERNATION.md`).
- **Bare-metal Windows does NOT resume its session — it always cold-boots.**
  `winresume` cannot read a `hiberfil.sys` that lives *inside* a VHD, so a
  native-VHD metal boot can only cold-start. This is accepted: you quit the
  anti-cheat game to switch, so there is nothing live worth resuming.
- **Windows session resume exists only in VM mode** (`powos windows vm`), where
  the guest hibernates/resumes on identical virtual hardware.

Target switch workflow: *click Windows in PowOS → PowOS flushes + hibernates
(S4, full Linux session preserved incl. the RAM overlay) → firmware BootNext →
Windows **cold-boots** from the image file → play → "Return to PowOS" shortcut →
firmware boots PowOS → Linux resumes exactly where it was.* Realistic downtime
**30–60s each direction** (PowOS S4 image write + POST + resume read, plus a
Windows cold boot). 5s is not physically possible — a firmware reboot sits
between any two kernels; there is no kexec-into-Windows.

## Non-goals

- **Shipping any Microsoft bits.** The user supplies their own ISO + license;
  PowOS only provides tooling that applies user media. (Hard constraint.)
- Hiding the hypervisor from anti-cheat in VM mode (ban risk; bare metal is
  the supported path for AC titles).
- Bare-metal Windows *session* resume (see the asymmetry above — physically
  blocked by `winresume`; not a PowOS choice).
- Windows Home support (native-VHD-boot niceties and policy knobs assume Pro).

## The core decision: a FILE that PowOS manages like a virtual disk

Windows lives in **one file** on the POWOS-GAMES NTFS partition:

```
<POWOS-GAMES>/PowOS-Windows/windows.vhdx     (dynamic/thin — the canonical image)
```

and bare-metal boots via Windows **native VHD boot**: `bootmgr` on the *shared*
PowOS ESP mounts the file and boots the OS inside it. No partition table
changes, no carve step, one blast radius: the file.

Three container options were evaluated (full reasoning in `docs/PROBLEM.md`):

| | **VHDX file (chosen)** | Dedicated partition | Internal disk |
|---|---|---|---|
| Repartitioning needed | **none — it's a file** | on the USB (carve WIN-ESP + a Windows NTFS partition) | internal disk (rejected by requirement 3) |
| Snapshots / rollback | ✅ whole-file zstd copy (differencing-VHDX = future work) | ✅ via `ntfsclone` | ✅ same |
| One blast radius / delete = `rm` | ✅ delete the file | ✗ two GPT entries to remove | ✗ |
| Same image also runs as a VM | ✅ attach the file to QEMU directly | needs a synthetic-disk mapping | needs passthrough |
| Windows *bare-metal* hibernation | ❌ `winresume` can't read `hiberfil.sys` inside a VHD → **metal always cold-boots** | ✅ | ✅ |
| Windows knows it's virtualized | **yes — VHD APIs are visible on metal** (accepted) | no (plain disk) | no |
| Dynamic-VHD size on first metal boot | ⚠️ **expands toward full max size** (MS recommends *fixed* VHDs for native boot) | n/a | n/a |
| In-place feature updates (24H2-style) | ❌ **blocked on native-VHD-boot installs** | ✅ | ✅ |

The chosen column honestly gives up three things — bare-metal hibernation,
thin-provisioning at metal boot, and in-place feature updates (see "Two honest
cost notes" below) — in exchange for **never partitioning anything for
Windows, ever**, and a management model that is literally `rm`, `cp`, `zstd`,
and "attach the file to QEMU". `docs/PROBLEM.md` argues why that trade is
correct: the sole thing given up that matters — bare-metal session resume —
protects exactly the sessions (anti-cheat games) that have nothing live to
resume, while PowOS's own session survives via its own S4 hibernation.

## Image format lifecycle (three masters to satisfy)

- **(a) `bootmgr` native boot** needs a VHD or VHDX (fixed or dynamic).
- **(b) safe QEMU read-write** — raw is bulletproof; QEMU's `vhdx` driver works
  but is the least battle-tested of the three.
- **(c) thin on NTFS** — sparse raw / dynamic VHDX.

So: **install** onto a raw sparse temp image (`windows.raw` — QEMU raw is the
most reliable format for Setup's heavy I/O), then `finalize` converts with
`qemu-img convert -O vhdx -o subformat=dynamic` (thin **and** native-bootable)
and deletes the raw. Steady-state VM sessions attach the VHDX read-write through
QEMU's `vhdx` driver. If that driver misbehaves, the **`--fixed-vhd` escape
hatch** converts to a fixed-subformat VHD (`vpc`) instead — `bootmgr`'s oldest,
safest native-boot format, written sparse so NTFS still stores only used blocks,
and read/written very reliably by QEMU. `discard=unmap` + `detect-zeroes=unmap`
on the QEMU drive keep the file thin (guest TRIM and zero-writes punch holes).

## Disk layout

Windows adds **no partitions**. The USB carries only its existing ones; the
Windows image is a file on POWOS-GAMES:

```
USB (4TB), burned with:  install-to-usb.sh --games-gb 512
├── p1  EFI (PowOS, SHARED)  512MB     Windows native-boot files (bootmgr+BCD) also land here
├── p2  System (base image)  ~100GB    Windows: Linux type GUID → no letter, ignored
├── p3  POWOS-DATA (btrfs)   bulk       Windows: Linux type GUID → no letter, ignored
│                                       └── windows/snapshots/  +  windows/esp-backup-*.tar.zst
└── p4  POWOS-GAMES (NTFS)   e.g 512GB  Windows: basic-data type → VISIBLE (by design)
                                        └── PowOS-Windows/windows.vhdx   ← Windows lives HERE
```

POWOS-GAMES must be sized to hold the image (default `--size 256`, thin) **plus**
shared game assets. There is no reserved/unallocated tail and no `powos windows
create` carve step — creation just makes a sparse file on POWOS-GAMES.

**The Windows-exposure contract, enforced at burn time:** Windows' scary "you
need to format this disk" prompt only fires for partitions that receive a drive
letter with an unreadable filesystem. Partitions carrying the *Linux
filesystem* GPT type GUID (sgdisk `8300`) get no letter and no prompt — Windows
silently ignores them. `install-to-usb.sh` sets `8300` on the btrfs partitions
and `0700` (Microsoft basic data) on POWOS-GAMES explicitly, so the only things
a metal Windows session ever sees are:

1. its own **file-internal** volumes (ESP/MSR/C: created *inside* `windows.vhdx`),
2. the **POWOS-GAMES** host volume (by design — it carries the image and shared
   game assets),
3. the **shared PowOS ESP's** boot files.

Everything else (System, POWOS-DATA) is letterless and invisible.

**The shared PowOS ESP — the only real block device Windows ever touches.**
Windows native VHD boot needs `bootmgr` + a BCD on a real ESP; PowOS has exactly
one, so Windows shares it. Because that is the PowOS loader's ESP too,
`powos windows install` takes a **mandatory backup** of it (`tar | zstd` →
`POWOS-DATA/windows/esp-backup-*.tar.zst`) *before* Windows touches it, unmounts
it on the host for the install VM, and `finalize` prints the one-line restore.
`hiberfil.sys` lives inside the VHDX and is unreadable at metal boot — hence the
cold-boot property, not a bug.

## Games storage (`powos games`)

POWOS-GAMES is a **first-class concept**, not a side effect of the Windows
work: an NTFS partition, labeled `POWOS-GAMES`, *deliberately* visible to
Windows — and now also the host volume for `windows.vhdx`. Every other PowOS
partition is hidden from Windows via GPT type GUIDs (Linux-filesystem type = no
drive letter = no "format this disk?" prompt); the games partition is the one
intentional exception.

**Three creation paths** (all producing the same partition):

1. **At USB flash time** — `install-to-usb.sh --games-gb N` (implemented).
2. **By the disk installer** — `powos install-system --shared-gb N` labels the
   shared NTFS partition `POWOS-GAMES`.
3. **Later, on any existing system** — `powos games create --size N [--disk D]`,
   against a PowOS-owned disk the user names.

**Machine-local model:** POWOS-GAMES (and the `windows.vhdx` file on it) belong
to a machine, not to the USB — see "Installed systems" below. Each machine
creates its own on its own PowOS-owned disk.

### Steam wiring (`powos games steam-setup`)

The point of the partition is *one installed game serving both OSes*. The
`steam-setup` command wires the PowOS side:

- Mounts POWOS-GAMES at `/var/mnt/games` via the kernel **ntfs3** driver
  (`uid`/`gid` mapping, `windows_names` to keep filenames Windows-legal).
- Creates `SteamLibrary/steamapps` on the partition.
- **The critical part:** keeps `compatdata` and `shadercache` on native btrfs
  via symlinks — Proton prefixes break on NTFS (symlinks, case handling,
  xattrs), so only the game *assets* live on the shared partition.
- Adds the library to Steam's `libraryfolders.vdf` — only while Steam is closed
  (Steam rewrites the file on exit and would clobber the edit).
- Drops `GAMES-README.txt` at the partition root telling the Windows side to add
  `<letter>:\SteamLibrary` as a Windows Steam library.

Result: install a game once from either OS; both Steams see it.

### Safety posture

Nothing in `powos games` (or `powos windows`) touches a disk except when the
user runs a command against a device they explicitly name — behind a printed
plan, confirmations, and `--dry-run`. Development machines are never touched
implicitly. Status: implemented, not yet hardware-validated.

## Installed systems (USB unplugged after install)

The USB is also an installer. After `powos install-system` puts PowOS on a
desktop/laptop/Steam Deck SSD, the USB is unplugged — so POWOS-GAMES and the
`windows.vhdx` on it are **machine-local**: each machine creates its own on its
own PowOS-owned disk, using the same commands (`powos games create`,
`powos windows create`) targeting that machine's disk instead of the USB.

Existing installs (e.g. a desktop that auto-updates via bootc/GHCR) receive the
new command families through **normal OS updates** and then run them once — no
reflash needed.

## Getting a Windows ISO (`powos windows fetch-iso [--slim]`)

PowOS ships no Microsoft bits, but it can *fetch* the media for you — under one
non-negotiable trust rule.

**Trust model (encoded in `lib/windows.sh`):** we **never download a prebuilt
or third-party Windows image** (unverifiable, and a redistribution problem). We
download the **official Microsoft ISO and verify it**, then *optionally* slim it
with an in-repo, auditable recipe. No foreign executable code is ever
fetched-and-run; at most we fetch **data** (and, for Steam, the official Valve
bootstrapper — same rule).

```
powos windows fetch-iso [--dest PATH] [--slim] [--hash SHA256] [--dry-run]
```

- **Download** the official Windows 11 ISO. The fetch is a mockable seam
  (`win_fetch_official_iso`) built on the **mido** approach — mido
  (<https://github.com/ElliotKillick/Mido>) is an auditable POSIX-sh
  reimplementation of *Fido* that drives Microsoft's **own** public download API
  (the same one `microsoft.com/software-download` uses). PowOS calls it if
  present; it is **not vendored**. Absent mido, PowOS refuses to improvise a
  downloader and prints the official manual route instead.
- **Verify integrity.** With `--hash`, PowOS asserts the SHA-256 matches and
  **aborts on mismatch** (and does *not* proceed to slim/install). Without
  `--hash`, it prints the computed SHA-256 with a prominent note to **verify it
  against Microsoft's published hash** yourself.
- **Sanity checks:** the file exists, is non-trivially sized (>3 GB), and has an
  ISO filesystem signature (`iso9660`/`udf`).
- **Default destination:** `<POWOS-DATA>/windows/iso/` (persistent, and
  letterless/invisible to Windows). `--dest` overrides.
- `install --fetch [--slim]` runs this first, then installs the result.

### Slimming: `powos windows slim <src.iso>` (EXPERIMENTAL)

A tiny11-**style** debloat done **natively on Linux with wimlib** — **no
Windows, no DISM, no running `tiny11builder`**. It extracts the ISO (xorriso),
mounts `sources/install.wim` (wimlib), removes a **curated** provisioned-appx
list plus the Edge/OneDrive setup, injects the TPM/SecureBoot/RAM **LabConfig
bypass** into the offline registry (the same intent as the autounattend's
LabConfig block — for a bare-metal Setup run from the slimmed media), rebuilds
the wim, and repacks a bootable UEFI ISO (xorriso). The removal list lives
in-repo as a pure function (`win_slim_package_list`) that **mirrors
[ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder)'s
curation** — reviewed and pinned by us, **never downloaded-and-executed**.

> ⚠️ **ANTI-CHEAT WARNING (do not ignore).** Bare-metal Windows exists **only**
> to run kernel anti-cheat titles (EAC/BattlEye — see `docs/PROBLEM.md`). The
> slim pass therefore **keeps** Windows Update / the servicing stack, .NET, the
> VC runtime, and the security stack; a strip that breaks EAC/BattlEye defeats
> the entire purpose. The removal list is guard-tested to contain none of those.
> The whole slim path is **EXPERIMENTAL / TODO(hw): it must be validated by
> actually installing and running an anti-cheat title before it is trusted.**

### Fixed-VHD synergy

A slimmed (tiny11-sized) install is small — which makes `--fixed-vhd` practical
up front. Native VHD boot **prefers a fixed VHD** (a *dynamic* VHDX balloons
toward its full `--size` on the first bare-metal boot — see cost note 1 below),
so `fetch-iso --slim` and `install --slim` suggest `--fixed-vhd` in their output.

## Steam & the shared library, preinstalled (`--no-games` to skip)

By default `powos windows install` makes the installed Windows arrive
**game-ready**, mirroring `powos games steam-setup` on the Windows side:

- **POWOS-GAMES gets a stable drive letter** (default `G:`, `--games-letter`),
  matched by **NTFS label** — never by letter, since letters are unpredictable
  before boot (the historical blocker).
- **Steam is preinstalled from an offline bootstrapper.** During `install`,
  PowOS drops the **official** `SteamSetup.exe` (fetched from Valve's CDN — same
  trust rule, sanity-checked by shape) onto the unattend FAT volume; a generated
  `powos-first-logon.ps1` runs it silently (`/S`) at first logon, with a CDN
  fallback if the offline copy is absent.
- **The shared library is seeded** into Steam's `libraryfolders.vdf` pointing at
  `G:\SteamLibrary` — the *exact* folder `gms_steam_layout` creates on the Linux
  side (`<POWOS-GAMES>/SteamLibrary`), so **one installed game serves both
  OSes**. The Windows side registers **only** the library folder; the Linux-only
  Proton state (`compatdata`/`shadercache`, symlinked onto btrfs there because it
  corrupts on NTFS) is never created or referenced from Windows — a deliberate,
  guard-tested asymmetry. `--steam-autostart` optionally adds Steam to the Run
  key. `--no-games` skips the whole first-logon payload.

## Install flow: ISO-in-VM into the file

`bcdboot`/BCD creation requires Windows — so we don't do it from Linux. We let
Windows Setup do everything, inside a VM whose **disk 0 is the image file**:

1. `powos windows create [--size N]` — `truncate` a sparse `windows.raw` on
   POWOS-GAMES. No partitioning. (`--fixed-vhd` picks the VHD lifecycle instead
   of VHDX.)
2. `powos windows install --iso PATH` boots the user's ISO in QEMU (OVMF, **AHCI
   — not virtio**, so the storage stack is identical in VM and on metal) with:
   - **disk 0** = `windows.raw` (Setup wipes disk 0 *only* — it is the file —
     and creates the internal ESP + MSR + C: inside it),
   - **disk 1** = the **real, backed-up, host-unmounted PowOS ESP** (Setup's
     first-logon `bcdboot` lays the native-boot files onto it),
   - **disk 2** = a 64MiB FAT volume carrying `autounattend.xml` for a
     zero-touch install (`--interactive` omits it and you click Setup yourself).
   The unattend file bypasses the TPM/Secure-Boot/RAM/CPU checks *for the VM
   only* (LabConfig registry switches — bare-metal boots are unaffected),
   installs the chosen edition keyless-by-default, then self-registers native
   boot: `mountvol S: /S`; `bcdboot C:\Windows /s S: /f UEFI`;
   `bcdedit … device/osdevice vhd=[locate]\PowOS-Windows\windows.vhdx`
   (`vhd=[locate]` makes `bootmgr` *search* every volume for the path — no
   drive-letter assumption survives into a metal boot).
3. First-logon commands also set: `powercfg /h on` (matters for VM-mode
   hibernation; harmless on metal), Fast Startup **off** (keeps the internal
   NTFS and POWOS-GAMES clean), `RealTimeIsUniversal` (RTC as UTC, agrees with
   PowOS), a **"Return to PowOS"** desktop shortcut, and "restart apps after
   sign-in".
4. `powos windows finalize` — converts `windows.raw` → `windows.vhdx`
   (`qemu-img convert`, thin + native-bootable), deletes the raw, verifies the
   ESP gained `EFI/Microsoft/Boot/{BCD,bootmgfw.efi}`, and creates the **host**
   firmware entry (`efibootmgr -c` → `\EFI\Microsoft\Boot\bootmgfw.efi`; the VM
   couldn't, it has its own NVRAM). Prints the ESP-restore one-liner.

The **same image file** is reused for **VM mode** later — Windows sees the same
disk in both worlds (AHCI both times).

## The switch (`powos windows`, both directions)

PowOS → Windows (`win_switch`):

1. **Guards** (all enforced):
   - image exists and is **finalized** (a raw image can't native-boot).
   - image **not open** by any process (a running VM = refuse; two writers
     corrupt it).
   - hibernation-inside-the-image probe → **warn only**: if a VM session left a
     `hiberfil.sys` in the file, a metal boot will prompt Windows to **discard**
     it (session lost, no corruption; resume it with `powos windows vm` instead).
   - a Windows **firmware entry exists** (else run `finalize`).
2. **Flush + stop layer-sync** — a failed flush is a **hard abort** (unsynced
   RAM changes would be lost across the switch).
3. **Unmount POWOS-GAMES** — PowOS hibernates with its mounts frozen, and the
   metal Windows session writes this NTFS volume (it hosts the image); a frozen
   rw-mount under another OS's writes = corruption. Refuse if busy.
4. `efibootmgr --bootnext <windows-entry>`, `sync`.
5. `systemctl hibernate` — PowOS S4; the RAM overlay (the whole session, tmpfs
   and all) is in the hibernation image (`docs/HIBERNATION.md`). Windows then
   **cold-boots** from the file. If hibernate fails, the fallback is a plain
   reboot (`--reboot`, or an interactive prompt) — BootNext is already set, so
   the next boot still lands in Windows; only the live PowOS session is lost
   (layer-sync already flushed all files).

Windows → PowOS: the **"Return to PowOS"** desktop shortcut (`shutdown /r /fw
/t 0`, generated at install time) reboots to the firmware boot menu; because
PowOS is the default entry it comes back up and resumes. (A cleaner one-shot,
`bcdedit /set {fwbootmgr} bootsequence {PowOS-GUID}`, is addable once the PowOS
entry GUID is known.)

### The one rule that keeps hibernation safe

**A hibernated OS's volumes are frozen — the other OS gets them read-only or not
at all.** In this file design that means:

- Before the switch, **POWOS-GAMES is unmounted** (it hosts the image Windows is
  about to write); PowOS then hibernates with nothing mounted on it.
- **VM mode is NOT refused on a hiberfile** — resuming a *VM*-hibernated image in
  the *VM* is the correct, supported path (identical virtual hardware). It is
  only a *metal* boot of a hibernated image that must discard the session, and
  the switch **warns** about that before its confirmation gate.
- PowOS hibernated → Windows physically can't hurt it: btrfs is unreadable to
  Windows, and the standing rule (never initialize disks in Disk Management) is
  stated in the post-install script and the POWOS-GAMES README.
- Snapshots refuse to run against an image that is open.

## Snapshots / rollback

Snapshots are **whole-file zstd copies of the VHDX**, stored on POWOS-DATA
(btrfs, letterless/invisible to Windows — a rogue metal session can't reach its
own restore points):

- `powos windows snapshot [name]` → `zstd` copy →
  `POWOS-DATA/windows/snapshots/<name>.vhdx.zst`. Refuses if the image is open.
- `powos windows rollback <name>` → `zstd -d` decompress-replace, **typed**
  confirmation (it overwrites the live image; everything newer is lost).
- `powos windows snapshots` — list with sizes/dates.
- Minutes, not instant — it's a whole-file compress/decompress (a 256GB dynamic
  image with ~80GB used ≈ tens of GB read/write). **Differencing-VHDX snapshots
  (instant, rollback = drop-the-child) are future work.**

## VM mode (`powos windows vm`)

Attaches the **same `windows.vhdx`** directly to QEMU (`vhdx` driver, or `vpc`
for a `--fixed-vhd` image) — OVMF, AHCI, per-VM writable NVRAM, no reboot. The
real ESP is **not** attached (only install needs it). VM-hibernation is the
**supported resume path** and is never refused: a VM-hibernated image resumes on
identical virtual hardware, so it's correct. This is the mode for productivity
and non-anti-cheat Windows-only titles; anti-cheat titles still need the metal
switch.

## Two honest cost notes (the price of "Windows in a file")

Native VHD boot carries two penalties the partition/internal-disk options don't:

1. **Thin provisioning is optimistic at metal boot.** Windows *expands a dynamic
   VHD toward its full maximum size* the first time it **bare-metal** boots
   (Microsoft recommends *fixed* VHDs for native boot for exactly this reason).
   The file stays thin under `powos windows vm`, but the "grows on demand"
   advantage largely evaporates in the one mode this design exists for — size
   POWOS-GAMES for close to the full `--size`, and consider `--fixed-vhd` if you
   want the on-disk size to be predictable up front.
2. **In-place feature updates are unsupported** on native-boot VHDs (24H2-style
   in-place upgrades are blocked) — a standing maintenance tax. Cumulative
   updates are fine; a feature-version jump means a reinstall into a fresh image
   (snapshot first).

Both are accepted in `docs/PROBLEM.md`: they are the cost of never partitioning
anything for Windows.

## Command surface

```
powos games status                       # partition, mount, Steam wiring state
powos games create --size N [--disk D] [--dry-run] [--yes]   # create POWOS-GAMES
powos games mount                        # mount at /var/mnt/games (ntfs3)
powos games steam-setup                  # library + compatdata symlinks + vdf + README
powos games resize                       # stub — not implemented

powos windows status                     # image, hibernation state, boot entry, snapshots
powos windows fetch-iso [--dest P] [--hash H] [--slim]   # download + verify the OFFICIAL MS ISO
powos windows slim <src.iso> [--out P]   # tiny11-style wimlib debloat (EXPERIMENTAL)
powos windows create [--size N] [--fixed-vhd]   # create the thin image file (NO partitioning)
powos windows install --iso PATH         # Windows Setup in QEMU into the file (ESP rides along)
                                         #   (--fetch [--slim]: acquire the ISO first)
powos windows finalize                   # raw→VHDX convert, verify ESP boot files, host firmware entry
powos windows                            # THE SWITCH: flush+stop layer-sync → guards → unmount
                                         #   POWOS-GAMES → BootNext → hibernate PowOS (Windows cold-boots)
                                         #   (--reboot: plain reboot if hibernate fails)
powos windows snapshot|snapshots|rollback   # whole-file zstd copy on POWOS-DATA
powos windows vm                         # boot the SAME image as a KVM guest (VM-hibernation OK)
```

Install options: `--interactive`, `--username`, `--password`, `--locale`,
`--keyboard`, `--edition`, `--product-key`, `--with-steam`, `--fetch`, `--slim`,
`--games-letter L`, `--steam-autostart`, `--no-games`. fetch-iso/slim options:
`--dest`, `--hash`, `--out`. Global: `--dry-run`, `--yes`, `--ram`, `--cpus`.
`powos boot windows` (existing) remains the low-level one-shot reboot;
`powos windows` is the full guarded switch.

## Failure modes considered

| Failure | Outcome |
|---|---|
| Power loss during PowOS S4 write | Normal cold boot; layer-sync already flushed → persisted state intact, only the live session lost |
| Windows offered to format an unreadable partition | Can't happen for letterless Linux-GUID partitions (exposure contract); POWOS-GAMES/C: are real NTFS |
| Windows Update rewrites boot files on the shared ESP | `powos windows status` detects; the mandatory ESP backup restores in one line (`finalize` prints it) |
| Two writers on the image (metal + VM, or two VMs) | `win_guard_image_free` refuses — the image is `fuser`-checked before every metal/VM/snapshot op |
| VM left a hiberfile, then a metal boot | Switch warns; Windows prompts to discard the VM session (no corruption). Resume it with `powos windows vm` |
| Dynamic VHDX ballooning to full size on first metal boot | Expected (cost note 1); use `--fixed-vhd` or size POWOS-GAMES accordingly |
| Feature-update attempt on the native-boot image | Blocked by Windows (cost note 2); reinstall into a fresh image, snapshot first |
| USB unplugged while Windows runs | Same as any Windows losing its disk — but internal disks were never involved; snapshot restores |
| Activation flapping (VM↔metal hardware profiles) | Known behavior; digital license re-activates; documented |

## Phases & validation

1. **Phase 0 (gate):** persistence chain + hibernation validated on real
   hardware (`sudo build/validate.sh --all`, then HIBERNATION.md Phase 1).
   Nothing here ships before that — hibernating an unvalidated RAM-overlay OS
   compounds any persistence bug.
2. **Phase 1:** `create` / `install` / `finalize` on a fresh USB. Pure-function
   tier-1 tests already cover the QEMU command builder, the autounattend
   generator, guard logic, ESP-backup/restore command shapes, and boot-entry
   parsing (`test/tier1/test-windows.sh`). E2E: the QEMU tier can exercise
   create → install-VM launch up to the Setup screen with a stub ISO; actual
   Windows install/licensing is a manual checklist.
3. **Phase 2:** the guarded switch + Return-to-PowOS + PowOS S4 round-trip
   (hardware-only validation).
4. **Phase 3:** differencing-VHDX snapshots (instant, drop-the-child rollback)
   replacing today's whole-file zstd copy.

## Decisions & open questions

Decided:
- **Windows is a FILE, not a partition** — `windows.vhdx` on POWOS-GAMES, native
  VHD boot off the shared ESP. No WIN-ESP, no dedicated Windows partition, no
  carve step. (The earlier partition-as-virtual-disk spec is superseded — see
  `docs/PROBLEM.md` for the full comparison.)
- **Games partition: YES** — `--games-gb` POWOS-GAMES NTFS, deliberately visible
  to Windows; it also hosts the image. Everything else hidden via GPT type GUIDs.
- **Snapshots: whole-file zstd** now; differencing-VHDX later.

Still open:
1. **Sizes** — for a 4TB stick, `--games-gb 512` with a `--size 256` image is a
   reasonable start (Windows C: mostly holds the OS + AC titles; big assets live
   on POWOS-GAMES which both OSes read). Note cost note 1: a *dynamic* image can
   balloon toward 256G on first metal boot.
2. Unattend automation depth (the current `autounattend.xml` vs. a lighter
   documented post-install one-liner — the `--interactive` fallback).
3. Does Secure Boot need to stay off? (Bazzite unsigned kmods generally mean SB
   off; EAC/BattlEye don't require SB; Vanguard does — accept "no Vanguard" or
   document per-title.)
4. `qemu-img`'s `vhdx` driver maturity for steady-state rw VM sessions — the
   `--fixed-vhd` (`vpc`) escape hatch exists if it misbehaves.
