# PowOS Hibernation & Session-Resume — Design Spec

**Status:** DRAFT — not implemented. **Blocked** on base RAM-boot/persistence
validation (see §9). This documents the design so it's ready to build once the
foundation is proven on real hardware. Nothing here should be built while the
persistence chain is unvalidated — hibernation *compounds* any persistence bug.

**Owner:** —  ·  **Last updated:** 2026-07-03

---

## 1. Goal

Let the user hop between PowOS and bare-metal Windows **without losing their
Linux session**. Instead of a cold reboot, PowOS *hibernates* (writes RAM to
disk, powers off). When they return from a Windows gaming session, PowOS resumes
with every window and program exactly where they left it.

Concretely, the target flow:

```
In PowOS  →  powos boot windows --hibernate
          →  Linux session saved, machine powers off, firmware boots Windows
          →  play anti-cheat games bare-metal (full GPU, no VM)
          →  shut down / restart Windows
          →  firmware boots PowOS  →  Linux RESUMES exactly where it was
```

## 2. Non-goals

- **Not** "see Linux in a window while gaming" — that needs a VM, which
  anti-cheat blocks. Hibernation is one-OS-at-a-time by nature; see
  [DUAL-BOOT-VM.md](DUAL-BOOT-VM.md).
- **Not** truly instant. Resuming a multi-GB RAM image from USB is seconds to
  tens of seconds; from internal NVMe it's fast but not zero.
- **Not** a replacement for layer-sync. Layer-sync persists *files*; hibernation
  persists *running process state*. They are complementary.

## 3. Background: why S4, and why PowOS makes it unusual

- **S3 (suspend-to-RAM)** keeps RAM powered — the machine isn't off, so you
  *cannot* boot Windows. Useless for OS switching.
- **S4 (hibernate)** writes RAM to a swap device and powers off fully → the
  firmware can boot another OS. This is the only sleep state compatible with
  dual-boot switching.

**PowOS wrinkle:** the entire OS runs from a **tmpfs RAM overlay**
(`rd.powos.ramboot`). A hibernation image is a dump of *all of RAM*, so PowOS's
image includes the OS itself, not just user apps. Implications:

- The swap/resume device must be **≥ peak used RAM** (OS overlay + apps + page
  cache), realistically sized to *total* installed RAM (could be 16–32 GB).
- Resuming restores the overlay mounts and kernel device state — this
  overlayfs-over-tmpfs + hibernation interaction is the **primary unknown** (§10).

## 4. Safety invariants (violating any of these risks data loss)

- **INV-1 — Shared partition is never hibernation-locked.** The shared games
  partition (`POWOS-SHARED`, NTFS) MUST be cleanly unmounted before either OS
  hibernates, and must not be part of any OS's Fast Startup / hibernate lock.
  Both OSes mount it fresh each session. A hibernated OS holding it open →
  the other OS mounting it → corruption.
- **INV-2 — Never resume onto changed hardware.** Record the USB `POWOS-DATA`
  UUID (and swap UUID) in the image metadata. On resume, if the expected devices
  aren't present/identical, **discard the image and cold-boot** rather than
  resume into an inconsistent state.
- **INV-3 — Quiesce layer-sync before imaging.** Stop `powos-layer-sync.service`
  and `sync` the USB before `systemctl hibernate`, so the image is consistent and
  the USB isn't mid-write. Restart it on resume.
- **INV-4 — Windows Fast Startup stays OFF.** Full "Hibernate" is allowed only if
  the shared partition is excluded (INV-1). Fast Startup (hybrid shutdown) must
  remain disabled — it silently locks NTFS. This is the same rule as the plain
  dual-boot setup, not a new one.

## 5. The round-trip mechanism (how BootNext + hibernate compose)

`powos boot windows --hibernate` sequence:

1. `efibootmgr --bootnext <windows>` — one-shot override so the *next* power-on
   boots Windows, not the Linux resume.
2. Quiesce layer-sync, unmount `POWOS-SHARED` (INV-1, INV-3).
3. `systemctl hibernate` — Linux image saved to swap; machine powers off.
4. Firmware honors BootNext → boots **Windows**. The Linux image sits untouched
   on swap.
5. User games, then shuts down / restarts Windows.
6. Firmware boots the default entry = **PowOS**. The initramfs `resume` module
   sees a valid image on swap → **restores the Linux session**.

For this to be automatic, **PowOS must be the default UEFI boot entry** (BootNext
only handles the one-time Windows detour). `powos boot` should ensure this.

## 6. Requirements

| Requirement | Detail |
|---|---|
| Resume device (swap) | ≥ total RAM. Partition or swapfile. |
| Kernel args | `resume=UUID=<swap-uuid>` (+ `resume_offset=` for a swapfile). |
| Initramfs | `resume` dracut module present (before `90powos-ramboot`). |
| Firmware | UEFI; PowOS is the default boot entry; `efibootmgr` available. |
| USB present on resume | `POWOS-DATA` must be reconnected for layer-sync/home. |

**Swap location matters for speed & reliability:**
- **Installed-to-disk PowOS:** swap on internal NVMe — fast, standard, reliable.
  This is the recommended and first target.
- **USB live boot:** swap on `POWOS-DATA` — multi-GB read/write over USB, slow,
  and fragile (USB must be present & unchanged). Experimental, last target.

## 7. CLI surface

```
powos hibernate                 # quiesce + unmount shared + systemctl hibernate
powos hibernate status          # is hibernation configured? (swap, resume karg, size)
powos hibernate setup           # create/size swap, add resume= karg, enable resume module
powos boot windows --hibernate  # §5 round-trip: hibernate Linux, BootNext -> Windows
```

## 8. Implementation sketch

- `lib/hibernate.sh` — `cmd_hibernate` (status/setup/now) + the pre-hibernate
  quiesce hook (stop layer-sync, unmount `POWOS-SHARED`, `sync`).
- Extend `lib/boot-manager.sh` `bm_boot_to` with a `--hibernate` path that sets
  BootNext then invokes the hibernate hook.
- `systemd`: a `powos-hibernate-guard` unit (`ExecStop`/sleep hook under
  `/usr/lib/systemd/system-sleep/`) enforcing INV-1/INV-3 on every hibernate.
- Resume-side verification (INV-2): a small pre-resume check comparing recorded
  device UUIDs; abort→cold-boot on mismatch.
- `setup`: size the swap to `MemTotal`, `mkswap`, write `resume=` via
  `config/bootc/kargs.d/`, ensure the `resume` dracut module, rebuild initramfs.

## 9. Prerequisites — do NOT build before these hold

1. **Base RAM-boot + layer-sync + persistence chain validated on real hardware /
   a VM** (`build/validate.sh --all`, `test/e2e/INSTALL-VALIDATION.md`).
   Hibernating a RAM-overlay OS whose persistence is unproven multiplies risk.
2. Dual-boot alongside Windows validated (installer, shared partition).
3. `powos boot windows` (BootNext) validated on real UEFI.

## 10. Open questions / risks (the untested unknowns)

- **Does a tmpfs-RAM-overlay OS hibernate and resume cleanly?** The overlayfs +
  swsusp interaction is the central unknown. Needs a VM spike before committing.
- Peak hibernation image size with the OS in RAM — how big must swap really be?
- USB device-state consistency across the power cycle (esp. if swap is on USB).
- Resume speed from USB — is it fast enough to be worth it vs. a cold boot that
  already restores files via layer-sync?
- Corrupted/partial image handling — confirm the kernel cleanly rejects and
  cold-boots rather than half-resuming.

## 11. Phasing

- **Phase 0** — Prereqs (§9) green.
- **Phase 1** — Hibernation for **installed-to-disk** PowOS (swap on NVMe).
  Simplest, most reliable. `powos hibernate` + `status`/`setup`.
- **Phase 2** — The round-trip `powos boot windows --hibernate` + resume-side
  INV-2 verification.
- **Phase 3** — USB-live-boot hibernation (swap on `POWOS-DATA`). Experimental;
  may be declared not-worth-it after Phase 1 measurements.

---

*This is a design spec, not an implementation. Every disk/boot/sleep interaction
here is unvalidated and must be proven on real hardware or a VM before code lands.*
