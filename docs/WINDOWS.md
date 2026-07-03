# Bare-Metal Windows on the PowOS USB — Design Spec

**Status: SPEC / not implemented.** Companion to `docs/HIBERNATION.md` (the
PowOS-side session-resume half) and `docs/DUAL-BOOT-VM.md` (the VM half).

## Goal

One 4TB PowOS USB carries a full Windows that:

1. **Bare-metal boots** for kernel anti-cheat titles (EAC/BattlEye — VMs are
   detected and blocked; this is the only workload that needs metal).
2. **Hibernates and resumes** its own session across OS switches.
3. **Also boots as a KVM guest** from PowOS for non-anti-cheat Windows work —
   the same instance, no second install.
4. **Never touches internal disks.** No internal partitioning, no second SSD.
   The worst Windows can ever do is damage its own region of the USB.
5. Is **snapshottable and rollback-able** from PowOS, like every other PowOS
   layer.

Target switch workflow: *click Windows in PowOS → PowOS hibernates (S4, full
session preserved incl. the RAM overlay) → firmware BootNext → Windows resumes
from its own hibernation → play → "Return to PowOS" → PowOS resumes exactly
where it was.* Realistic downtime **30–60s each direction** (S4 image write +
POST + resume read). 5s is not physically possible — a firmware reboot sits
between any two kernels; there is no kexec-into-Windows.

## Non-goals

- **Shipping any Microsoft bits.** The user supplies their own ISO + license;
  PowOS only provides tooling that applies user media. (Hard constraint.)
- Hiding the hypervisor from anti-cheat in VM mode (ban risk; bare metal is
  the supported path for AC titles).
- Windows Home support (native boot niceties and policy knobs assume Pro).

## The core decision: a PARTITION that PowOS manages like a virtual disk

Three container options were evaluated:

| | VHDX native boot | **Partition (chosen)** | Internal disk |
|---|---|---|---|
| Windows hibernation | ❌ `winresume` cannot read hiberfil.sys inside a VHD — hard limitation, no workaround | ✅ | ✅ |
| Windows knows it's virtualized | yes (VHD APIs visible) | **no — it's a plain disk** | no |
| Snapshots / rollback | ✅ native diff disks | ✅ via `ntfsclone` (used-blocks, zstd) | ✅ same |
| Repartitioning needed | none | on the USB only | internal disk (rejected by requirement 4) |
| Feature-update friction | yes (blocked on VHD boot) | none | none |

The insight: at bare metal, the only "virtual disk" firmware can boot that
Windows cannot distinguish from real hardware **is** a partition. So the
design keeps the *management model* of a virtual disk (snapshot, rollback,
attach-to-VM, one blast radius) but implements it as a raw block range.
Windows never knows; PowOS manages it like a file.

## Disk layout

```
USB (4TB), burned with:  install-to-usb.sh --games-gb 512 --windows-gb 256
├── p1  EFI (PowOS)          512MB     Windows: ESP type → hidden, respected
├── p2  System (base image)  ~100GB    Windows: Linux type GUID → no letter, ignored
├── p3  POWOS-DATA (btrfs)   bulk      Windows: Linux type GUID → no letter, ignored
├── p4  POWOS-GAMES (NTFS)   e.g 512GB Windows: basic-data type → VISIBLE (by design)
├── (unallocated)            e.g 256GB reserved; `powos windows create` carves:
│    p5  WIN-ESP (FAT32)     512MB     Windows boot files, isolated from PowOS's ESP
│    p6  POWOS-WIN (NTFS)    rest      Windows itself (C:)
```

**The Windows-exposure contract, enforced at burn time:** Windows' scary
"you need to format this disk" prompt only fires for partitions that receive
a drive letter with an unreadable filesystem. Partitions carrying the *Linux
filesystem* GPT type GUID (sgdisk `8300`) get no letter and no prompt —
Windows silently ignores them. `install-to-usb.sh` sets `8300` on the btrfs
partitions and `0700` (Microsoft basic data) on POWOS-GAMES explicitly, so
the only things Windows ever sees are the games partition and (after
`windows create`) its own C: — exactly the exposure the design intends.

**Dedicated WIN-ESP (p5), not the shared PowOS ESP.** Windows updates
occasionally rewrite boot files/entries on "their" ESP; giving Windows its own
keeps the PowOS loader untouchable. UEFI handles multiple ESPs fine; the
firmware entry for Windows points at p5's `EFI/Microsoft/Boot/bootmgfw.efi`.
`hiberfil.sys` lives on p6 as normal — full hibernation support.

### Free space: reserved at flash time (re-burn, don't shrink)

`install-to-usb.sh` historically gave POWOS-DATA `100%` of the remainder, so
older USBs have zero free space. The primary path is a **fresh burn**:
`--games-gb N` creates POWOS-GAMES, `--windows-gb N` leaves the tail
unallocated for `powos windows create` (both implemented). The current
physical USB carries an outdated PowOS with nothing worth keeping — it gets
re-burned with the new layout; state comes back via `powos backup pull`.
An online-shrink path for non-reburnable USBs is possible but deliberately
unscheduled — it's the scariest operation in the plan and re-burn beats it
in every case that matters.

## Install flow: ISO-in-VM onto a synthetic disk

`bcdboot`/BCD creation requires Windows — so we don't do it from Linux. We
let Windows Setup do everything, inside a VM whose disk IS the real
partitions:

1. Assemble a **synthetic whole disk** with device-mapper linear targets:
   `[generated GPT header][p5 WIN-ESP][p6 POWOS-WIN][backup GPT]` — the GPT
   fragments are small loop-backed files; the data ranges map straight onto
   the real partitions. QEMU gets this dm device as a **raw AHCI disk**
   (AHCI, not virtio: identical storage stack in VM and on metal, no driver
   surprises when switching).
2. Boot the user's ISO in QEMU (existing `vm.sh` machinery, OVMF) with that
   disk attached. User clicks through Setup onto the disk; Setup lays the
   ESP contents, BCD, and Windows itself onto the *real* partitions through
   the dm mapping.
3. Post-install (still in the VM, automated via an unattend/firstlogon
   script we inject or a documented one-liner): enable hibernation
   (`powercfg /h on`), **disable Fast Startup** (`powercfg /h /type full` +
   registry), set RTC-local-time expectations, drop the **"Return to
   PowOS"** shortcut (below), enable "restart apps after sign-in".
4. On the PowOS side: create the firmware boot entry
   (`efibootmgr -c` → p5 bootmgfw), verify `powos boot windows` resolves it,
   add the BLS menu entry.

The same synthetic-disk assembly is reused for **VM mode** later — Windows
sees the identical disk in both worlds. (This replaces `vm windows`'s
whole-disk passthrough for the on-USB case, which is impossible anyway: the
USB is the live root and can never be handed to a guest whole.)

## The switch (`powos windows`, both directions)

PowOS → Windows:
1. **Guards** (all enforced, none advisory):
   - layer-sync: flush + stop; USB filesystems synced.
   - No VM currently attached to p6 (dm device not open).
   - p6/POWOS-GAMES not mounted, or unmounted now.
   - Windows Fast Startup verified OFF (read the registry hive from Linux
     via `hivex`, or NTFS dirty-flag heuristic) — refuse with instructions
     if on.
2. `efibootmgr --bootnext <windows-entry>`.
3. PowOS S4 hibernate (per `docs/HIBERNATION.md`: swap sized ≥ RAM on the
   USB, `resume=` karg; S4 inherently preserves the RAM overlay — the
   session, tmpfs and all, is in the hibernation image).

Windows → PowOS: the **"Return to PowOS"** desktop shortcut runs (elevated)
`bcdedit /set {fwbootmgr} bootsequence <PowOS-GUID>` + hibernate — the exact
Windows mirror of `powos boot windows`. Fallback: `shutdown /r /fw`.
Generated at install time; this closes the loop so neither direction ever
needs a firmware menu.

### The one rule that keeps hibernation safe

**A hibernated OS's volumes are frozen — the other OS gets them read-only or
not at all.** Concretely:

- Windows hibernated → PowOS mounts POWOS-WIN and any shared NTFS
  **read-only** (detected via hiberfil + NTFS dirty flag; enforced in the
  mount path, not documented as advice).
- Windows hibernated → **VM mode refuses to start** (resuming a hibernation
  image on different "hardware" bluescreens or corrupts; the command offers
  "boot it bare-metal instead" and, with an explicit flag, hiberfile
  discard).
- PowOS hibernated → Windows physically can't hurt it: btrfs is unreadable
  to Windows, and the standing rule (never initialize disks in Disk
  Management) is stated in the install-time README on the shared partition.
- Snapshots refuse to run against a hibernated/dirty p6.

## Snapshots / rollback

- `powos windows snapshot [name]` — `ntfsclone --save-image` (used blocks
  only) | zstd → `POWOS-DATA/windows/snapshots/`. Refuses on dirty/hibernated.
- `powos windows rollback <name>` — restore, typed confirmation.
- `powos windows snapshots` — list with sizes/dates.
- Minutes, not instant (it's a block clone, the price of "Windows never
  knows") — but a 256GB partition with ~80GB used ≈ 80GB read/write ≈ a few
  minutes on this SSD, and post-zstd snapshots are ~40-60GB each.

## Command surface

```
powos windows create [--size 256G] [--from-iso PATH]   # carve + VM install + boot entries
powos windows            # the switch: guards → flush → BootNext → S4
powos windows vm         # same instance as KVM guest (synthetic disk; refuses if hibernated)
powos windows snapshot|rollback|snapshots
powos windows status     # partition, hibernation state, boot entries, guards
```

`powos boot windows` (existing) remains the low-level one-shot reboot;
`powos windows` is the full guarded switch. `powos gpu to-vm` composes with
`powos windows vm` as today.

## Failure modes considered

| Failure | Outcome |
|---|---|
| Power loss during PowOS S4 write | Normal cold boot; layer-sync already flushed → persisted state intact, only the live session lost |
| Windows offered to format an unreadable partition | Can't happen for lettered-less Linux-GUID partitions (exposure contract); POWOS-GAMES/C: are real NTFS |
| Windows Update rewrites boot entries | Only p5/NVRAM affected; `powos windows status` detects, `powos boot` repairs BootOrder; PowOS ESP untouched (dedicated-ESP payoff) |
| USB unplugged while Windows runs | Same as any Windows losing its disk — but internal disks were never involved; snapshot restores |
| Hibernated-Windows + VM start attempt | Refused by guard |
| Activation flapping (VM↔metal hardware profiles) | Known behavior; digital license re-activates; documented |

## Phases & validation

1. **Phase 0 (gate):** persistence chain + hibernation validated on real
   hardware (`sudo build/validate.sh --all`, then HIBERNATION.md Phase 1).
   Nothing here ships before that — hibernating an unvalidated RAM-overlay
   OS compounds any persistence bug.
2. **Phase 1:** `install-to-usb --windows-gb` reservation + partition-path
   `windows create` on fresh USBs. Pure-function tier-1 tests for partition
   math (reuse the installer's mocked-tool style), dm-assembly command
   generation, guard logic (fake hiberfile/dirty flags), BCD-entry
   detection. E2E: the QEMU tier can exercise create → dm-assembly → VM
   boot of the Setup ISO *up to* the Setup screen with a stub ISO; actual
   Windows install/licensing is manual-checklist (INSTALL-VALIDATION.md).
3. **Phase 2:** the guarded switch + Return-to-PowOS + hibernation
   round-trip (hardware-only validation).
4. **Phase 3:** snapshots/rollback; `powos windows vm` replacing raw
   passthrough for the on-USB case.
   (Online shrink for non-reburnable USBs: unscheduled — see above.)

## Decisions & open questions

Decided:
- **Games partition: YES** — `--games-gb` POWOS-GAMES NTFS, burned at USB
  creation, deliberately visible to Windows. Everything else hidden via GPT
  type GUIDs (exposure contract above).
- **Existing USB: re-burn**, not shrink. Nothing on it worth keeping.
- Burn-time reservation flags implemented in `install-to-usb.sh`
  (`--games-gb`, `--windows-gb`).

Still open:
1. **Sizes** — suggestion for the 4TB stick: `--games-gb 512 --windows-gb
   256` (Windows C: mostly holds the OS + AC titles; big assets live on
   POWOS-GAMES which both OSes read).
2. Unattend automation depth for the ISO-in-VM install (full unattend.xml vs
   a documented post-install one-liner) — unattend is nicer, more to
   maintain.
3. Does Secure Boot need to stay off? (Bazzite unsigned kmods generally mean
   SB off; EAC/BattlEye don't require SB; Vanguard does — accept "no
   Vanguard" or document per-title.)
