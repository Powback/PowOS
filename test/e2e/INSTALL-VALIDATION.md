# Installer Validation Checklist (hardware / VM)

Tier-1 unit tests (`test/tier1/test-install-system.sh`) cover the installer's
*logic* — arg parsing, dry-run gating, confirmation, disk exclusion, free-space
parsing. They **cannot** validate real partitioning or the boot menu. Everything
below must be checked on a VM (QEMU/virt-manager) or a spare disk before the
`TODO(hw)` markers in `lib/install-system.sh` come off.

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

## Known gaps to close before calling this stable

- Exact `bootc install to-filesystem` flags vs. the shipped bootc version.
- Shared partition is now created inline (root reserves the tail, then
  `isv_create_shared_partition` runs mkpart + mkfs.ntfs) — but the parted
  negative-offset placement and `mkfs.ntfs` have only been unit-tested at the
  parsing level, never run against a real disk. Verify the layout end-to-end.
- Partition identification uses GPT PARTLABEL (`isv_part_by_partlabel`) — confirm
  labels survive on the real image's partitioning.
- `grub2-editenv menu_auto_hide=0` path on the real image (menu visibility).
