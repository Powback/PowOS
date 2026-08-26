#!/usr/bin/env bash
# build/raw-stamp.sh <disk-image-or-device>
#
# Print the PowOS source commit baked into the ostree deployment INSIDE the
# artifact, plus two other facts that are only knowable by looking inside it.
#
# Vendored unchanged in behaviour from /var/tmp/raw-stamp.sh so the pipeline
# lives in the repo. Its reason for existing is not negotiable and is repeated
# here because every speed optimisation is a temptation to drop it:
#
#   Comparing a "prepared at <commit>" note against HEAD says NOTHING about what
#   the raw actually contains. A prepare that rebuilt the image but not the raw
#   still wrote the note, and the stick came out one build behind with every
#   check reporting success. Notes are hints. This is evidence.
#
# Output (eval-able):
#   commit=<sha|none|unknown>
#   live_marker=yes|no
#   containers_fstab=yes|no
set -uo pipefail
S() { if sudo -n true 2>/dev/null; then sudo "$@" 2>/dev/null
      else echo "${POWOS_SUDO_PASS:-powos}" | sudo -S "$@" 2>/dev/null; fi }
src="${1:?usage: raw-stamp.sh <image|device>}"; loop=""; part=""
if [[ -b "$src" ]]; then
    part=$(S lsblk -nro NAME,LABEL "$src" | awk '$2=="root"{print "/dev/"$1; exit}')
else
    loop=$(S losetup -Pf --show "$src") || { echo "stamp: cannot attach $src" >&2; exit 1; }
    sleep 1
    part=$(S lsblk -nro NAME,LABEL "$loop" | awk '$2=="root"{print "/dev/"$1; exit}')
fi
[[ -n "$part" ]] || { echo "stamp: no root partition in $src" >&2; [[ -n "$loop" ]] && S losetup -d "$loop"; exit 1; }
m=$(mktemp -d)
S mount -o ro "$part" "$m" || { echo "stamp: cannot mount $part" >&2; [[ -n "$loop" ]] && S losetup -d "$loop"; exit 1; }
d=$(S bash -c "ls -d $m/root/ostree/deploy/*/deploy/*.[0-9] $m/ostree/deploy/*/deploy/*.[0-9] 2>/dev/null | head -1")
if [[ -n "$d" ]]; then
    echo "commit=$(S cat "$d/usr/lib/powos/.powos-src-commit" 2>/dev/null || echo unknown)"
    S test -f "$d/etc/powos/.live-medium" && echo "live_marker=yes" || echo "live_marker=no"
    S grep -q '/var/lib/containers' "$d/etc/fstab" 2>/dev/null && echo "containers_fstab=yes" || echo "containers_fstab=no"
else
    echo "commit=none"
fi
S umount "$m"; rmdir "$m" 2>/dev/null
[[ -n "$loop" ]] && S losetup -d "$loop"
exit 0
