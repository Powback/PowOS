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

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
