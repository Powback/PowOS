# Installer Validation Checklist (hardware / VM)

Tier-1 unit tests (`test/tier1/test-install-system.sh`) cover the installer's
*logic* — arg parsing, dry-run gating, confirmation, disk exclusion, free-space
parsing. They **cannot** validate real partitioning or the boot menu. Everything
below must be checked on a VM (QEMU/virt-manager) or a spare disk before the
`TODO(hw)` markers in `lib/install-system.sh` come off.

## One command first

On a Linux box (PC, Steam Deck, or WSL2 w/ nested KVM), run the staged validator
before the manual steps below — it runs unit tests → real deploy/disk → build →
QEMU boot, skipping stages whose prerequisites are missing:

```bash
./build/validate.sh          # fast: unit + (as root) deploy/disk tests
sudo ./build/validate.sh     # include update-self + loop-device disk ops
sudo ./build/validate.sh --all   # + build image + QEMU boot smoke test
```

It ends by listing the manual checks (boot menu, installer, dual-boot, vm, base)
that can't be automated — those are detailed below.

**Now automated in the QEMU tier** (`test/e2e/test-qemu-boot.sh`) — no longer
manual-only:

- **Two-boot persistence** (TEST Q7): the runner creates a btrfs `POWOS-DATA`
  data disk (needs `btrfs-progs`; skips cleanly without it), writes a marker in
  the guest, flushes RAM upper → custom layer (`layer-sync.py --sync-now`),
  reboots the guest, and asserts the marker survived and the custom layer is in
  the active stack.
- **Rollback across a reboot** (TEST Q6): `powos rollback custom`, real guest
  reboot, then `rd.powos.skip.custom=1` asserted in `/proc/cmdline`. Skips (not
  fails) when grubby can't update the boot entry on the live image — that case
  still needs BLS/grubby validation on hardware.

## Setup

1. Build: `./build/build-iso.sh live-usb` (Linux/WSL + podman).
2. Write to a **virtual disk** or throwaway USB: `sudo ./build/install-to-usb.sh /dev/sdX`.
3. Create a VM with:
   - UEFI firmware (OVMF), Secure Boot **off**.
   - The PowOS USB/virtual disk as one drive.
   - A **second** blank virtual disk (the "internal" install target).
   - For dual-boot tests: install Windows to the second disk first.

## Boot menu (BLS entry)

- [ ] Boot the USB → GRUB shows **two** entries: `PowOS Live` and `Install PowOS to disk`.
- [ ] `PowOS Live` (default) boots to RAM as before; internal disks untouched.
- [ ] `Install PowOS to disk` boots and auto-launches the installer on tty1
      (i.e. `powos.install=1` reached the kernel and `powos-installer.service` fired).
- [ ] Confirm the entry exists on disk: `loader/entries/powos-install.conf`
      contains `powos.install=1` in its `options` line.

## Interactive installer — safety

- [ ] `sudo powos install-system --dry-run` against a disk prints a plan and
      changes **nothing** (verify with `lsblk` before/after — identical).
- [ ] Disk list **excludes** the live USB you booted from.
- [ ] Windows is flagged `YES` on a disk that has it; `no` otherwise.
- [ ] Whole-disk mode refuses to proceed unless the exact disk **model** is typed.
- [ ] Aborting at any confirmation leaves all disks untouched.

## Whole-disk install (`bootc install to-disk`)

- [ ] Installs to the blank second disk; system boots from it with USB removed.
- [ ] `powos status` shows the layered stack after first boot.

## Dual-boot / alongside (EXPERIMENTAL — the risky path)

- [ ] With Windows on the target disk, `--alongside` finds the free block and
      the existing ESP (does **not** reformat the ESP or Windows partitions).
- [ ] `bootc install to-filesystem` completes; reboot offers both OSes via the
      **UEFI boot menu** (F-key). GRUB may not auto-list Windows — that's expected.
- [ ] Windows still boots and its C:/data partitions are intact.
- [ ] Post-install: RTC is local time (`timedatectl` — Windows clock matches).
- [ ] Shared NTFS partition (`--shared-gb N`) is created, mountable by both OSes.

## Games partition + Steam (`powos games`)

- [ ] `powos games status` on a fresh install reports the POWOS-GAMES partition
      (created by the installer's auto reservation, or by `powos games create`).
- [ ] `powos games create --size N --dry-run` prints a plan bounded inside a real
      free block and changes nothing; without `--dry-run` it creates + formats
      NTFS (label POWOS-GAMES, GPT type 0700) and refuses if the label exists.
- [ ] `powos games mount` mounts it at `/var/mnt/games` via ntfs3 (uid/gid,
      windows_names).
- [ ] `powos games steam-setup` adds the library to Steam and keeps Proton
      `compatdata`/`shadercache` on native btrfs (symlinks), Steam closed.
- [ ] Windows sees POWOS-GAMES as a lettered drive and NO "format this disk?"
      prompt for any PowOS/Linux partition (GPT type-GUID exposure contract).

## Bare-metal Windows on the USB (`powos windows`) — EXPERIMENTAL

- [ ] `powos windows fetch-iso --slim` downloads the OFFICIAL MS ISO, SHA-256
      verifies it (aborts on mismatch), and produces a slimmed ISO via wimlib.
- [ ] `powos windows create --size N --dry-run` plans a thin `windows.vhdx` on
      POWOS-GAMES with no partitioning.
- [ ] `powos windows install --iso <slim.iso>` (or `--fetch --slim`) runs
      zero-touch: the ESP is backed up first (abort if backup fails) and
      host-unmounted; Windows Setup completes unattended into the VHDX.
- [ ] `powos windows finalize` creates the host-side firmware entry; `powos boot
      windows` resolves it.
- [ ] Reboot → **native VHD boot reaches the Windows desktop** (cold boot by
      design — no bare-metal resume with the `vhd` backend).
- [ ] **ANTI-CHEAT (the load-bearing test): launch an EAC/BattlEye title on the
      slimmed install — it MUST load.** If it fails, the slim removed something it
      needs; the whole bare-metal path is pointless without this. See docs/PROBLEM.md.
- [ ] Steam is preinstalled and its library points at `<letter>:\SteamLibrary`
      (the same folder `powos games steam-setup` uses) — a game installed on one
      OS appears on the other.
- [ ] `WINDOWS_BACKEND=partition` (config/windows.conf): the alternate backend
      installs into a dedicated WIN-ESP + POWOS-WIN carved from the burn-time
      `--windows-gb` tail and gives Windows real hibernation. Validate separately.
- [ ] ESP restore path works: after a Windows update that touches the shared ESP,
      the printed restore one-liner recovers PowOS's boot files.

## Known gaps to close before calling this stable

- Exact `bootc install to-filesystem` flags vs. the shipped bootc version.
- Shared partition is now created inline (root reserves the tail, then
  `isv_create_shared_partition` runs mkpart + mkfs.ntfs) — but the parted
  negative-offset placement and `mkfs.ntfs` have only been unit-tested at the
  parsing level, never run against a real disk. Verify the layout end-to-end.
- Partition identification uses GPT PARTLABEL (`isv_part_by_partlabel`) — confirm
  labels survive on the real image's partitioning.
- `grub2-editenv menu_auto_hide=0` path on the real image (menu visibility).
