#!/usr/bin/env bash
# The boot menu default must name an entry that EXISTS.
#
# `set default="ostree-1"` was written into grub.cfg for every medium ever
# burned. grub's blscfg ids each entry by its FILENAME INCLUDING ".conf", so it
# matched nothing, GRUB fell back to entry 0, and BLS entries sort filename-
# DESCENDING — putting powos-safe.conf first. The menu therefore defaulted to
# "Recovery — Safe mode", which carries no powos.install: the installer service
# correctly does not run, a getty takes tty1, and the boot lands on a bare
# login prompt indistinguishable from a broken installer.
#
# Proven by booting the real medium under OVMF and reading the serial console:
#     set default="ostree-1"       -> *Recovery — Safe mode (RAM boot off)
#     set default="ostree-1.conf"  -> *Bazzite (ostree:0)
#
# The setting was present, well-formed and inert — which is why nothing caught
# it. These assertions are about the .conf suffix surviving, and about the code
# warning when the id names no file.
set -uo pipefail
PASS=0; FAIL=0
check(){ if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
         else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }
U="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/build/install-to-usb.sh"

echo "== boot menu default =="
check "the live-entry id is NOT stripped of .conf" \
      '! grep -q "live=\"\${live%\.conf}\"" "$U"'
check "the fix records why (blscfg ids include the extension)" \
      'grep -q "blscfg ids each entry by its FILENAME INCLUDING" "$U"'
check "a default naming no entry file is reported, not shipped silently" \
      'grep -q "does not name an entry file" "$U"'
check "the stale 'safe, just unhelpful' claim is gone" \
      '! grep -q "safe, just unhelpful" "$U"'

# The mechanism, exercised rather than described: build a fake entries dir the
# way the medium has one, and confirm the selected id names a real file.
check "the newest ostree entry is chosen, with its extension" \
      'd=$(mktemp -d); mkdir -p "$d/loader/entries"
       : > "$d/loader/entries/ostree-1.conf"; : > "$d/loader/entries/ostree-2.conf"
       : > "$d/loader/entries/powos-safe.conf"; : > "$d/loader/entries/powos-install.conf"
       live=$(find "$d/loader/entries" -maxdepth 1 -name "*.conf" ! -name "powos-*" -printf "%f\n" | sort -V | tail -1)
       [ "$live" = "ostree-2.conf" ] && [ -f "$d/loader/entries/$live" ]; r=$?; rm -rf "$d"; exit $r'
check "and it is NEVER a recovery entry" \
      'd=$(mktemp -d); mkdir -p "$d/loader/entries"
       : > "$d/loader/entries/ostree-1.conf"; : > "$d/loader/entries/powos-safe.conf"
       live=$(find "$d/loader/entries" -maxdepth 1 -name "*.conf" ! -name "powos-*" -printf "%f\n" | sort -V | tail -1)
       case "$live" in powos-*) r=1 ;; *) r=0 ;; esac; rm -rf "$d"; exit $r'

# The install entry must MASK getty@tty1 on the kernel command line.
#
# powos-installer.service stops getty@tty1 in ExecStartPre, but the install
# entry boots systemd.unit=multi-user.target, and getty.target pulls the getty
# straight back up afterwards. Captured on a real OVMF boot:
#
#     [  OK  ] Started powos-installer.service - ... ("Install PowOS" entry).
#     [  OK  ] Started getty@tty1.service - Getty on tty1.
#     bazzite login:
#
# The installer WAS running — behind a getty that owned the console. The unit
# cannot use Conflicts= (that is what once deleted sddm from every boot), so the
# only place that cannot lose the race is the kernel command line: the mask is
# in effect before any unit starts.
#
# Re-booted with the mask: "Started getty@tty1" appears 0 times.
echo "== the install entry masks the getty that was stealing tty1 =="
check "the install entry masks getty@tty1" \
      'grep -q "systemd.mask=getty@tty1.service" "$U"'
check "the mask is on the INSTALL entry, beside powos.install=1" \
      'grep -q "powos.install=1.*systemd.mask=getty@tty1" "$U"'
check "it is NOT applied to the live or recovery entries" \
      '[ "$(grep -c "systemd.mask=getty@tty1" "$U")" -eq 1 ]'

# The default must be written as the entry's TITLE.
#
# Measured under OVMF on the real medium:
#     set default="powos-install.conf"      -> did NOT match; booted entry 0
#     set default="Install PowOS to disk"   -> booted that entry
# grub's blscfg id resolution is not dependable for these entries. Both forms
# look correct in grub.cfg, which is exactly why the broken one survived.
check "the default is resolved to the entry TITLE" \
      'grep -q "live_title=" "$U" && grep -q "s/\^title" "$U"'
check "a titleless entry warns instead of silently writing a bad id" \
      'grep -q "has no title line" "$U"'
check "title extraction works on a real BLS entry" \
      'd=$(mktemp -d); printf "title Bazzite (ostree:0)\nversion 1\n" > "$d/e.conf"
       t=$(sed -n "s/^title[[:space:]]\\+//p" "$d/e.conf" | head -1)
       [ "$t" = "Bazzite (ostree:0)" ]; r=$?; rm -rf "$d"; exit $r'

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
