#!/usr/bin/env bash
# build/boot-gate.sh [raw] — boot the raw in a VM and refuse to pass unless it
# reaches a desktop.
#
# Vendored from /var/tmp/boot-gate.sh, unchanged in what it asserts. Everything
# else in the pipeline verifies METADATA — that the initramfs got smaller, that
# the commit matches, that boot entries and variants exist. None of that asks
# whether the image can BOOT. An initramfs regenerated without ostree support
# boots nothing while looking like a perfect trim, and that is exactly what
# shipped on a stick.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
S() {
    # Prime the credential cache with its own stdin, then run with -n so the
    # caller's stdin reaches the command. See build/cycle-lib.sh for the bug
    # the obvious `echo pass | sudo -S "$@"` form causes.
    sudo -n true 2>/dev/null || echo "${POWOS_SUDO_PASS:-powos}" | sudo -S -v 2>/dev/null
    sudo -n "$@" 2>/dev/null
}
RAW="${1:-$REPO/build/output/powos.raw}"
[[ -f "$RAW" ]] || { echo "@@ GATE: no raw at $RAW"; exit 1; }

echo "@@ GATE: does this raw actually boot?"
S bash -c 'for c in $(podman ps -q); do podman kill "$c" >/dev/null 2>&1; done; pkill -9 -f "[q]emu-system-x86_64"'
S bash -c 'for l in $(losetup -j /var/tmp/gate.raw -O NAME -n 2>/dev/null); do losetup -d "$l"; done; rm -rf /var/tmp/shots-gate'
sleep 3
rm -f /var/tmp/gate.raw
cp --sparse=always "$RAW" /var/tmp/gate.raw || exit 1
S bash -c 'L=$(losetup -Pf --show /var/tmp/gate.raw); sleep 2
  B=$(lsblk -nro NAME,LABEL "$L" | awk "\$2==\"boot\"{print \"/dev/\"\$1;exit}")
  M=$(mktemp -d); mount "$B" "$M"
  sed -i "s|^options .*|& plymouth.enable=0 console=tty0 console=ttyS0,115200|" $M/loader/entries/*.conf
  sync; umount "$M"; rmdir "$M"; losetup -d "$L"'
S podman run --rm --privileged --device /dev/kvm -v /dev:/dev \
  -v "$PWD:/powos:z" -v /var/tmp:/out:z -w /powos quay.io/fedora/fedora:41 bash -c '
    dnf -y -q install qemu-system-x86-core qemu-img edk2-ovmf socat ImageMagick >/dev/null 2>&1
    bash test/qemu/boot-verify.sh --raw /out/gate.raw \
      --expect "Started sddm|Reached target graphical" \
      --timeout 300 --shots /out/shots-gate --serial /out/vm-gate.log' 2>&1 | tail -3
# STRIP ANSI BEFORE MATCHING. systemd colourises unit names on the console:
#     Starting ^[[0;1;39msddm.service^[[0m - Simple Desktop Display Manager...
# so "Started sddm" is never a contiguous string in the raw log. Grepping the
# raw bytes returns 0 matches and calls a perfectly good boot a failure — which
# it did, twice, on an image that boots fine.
# Capture, then match. NOT `cat | sed | grep -q`: this file runs under
# `set -o pipefail`, grep -q exits the instant it matches, cat and sed are killed
# mid-write, and the pipeline returns 141 — so a SUCCESSFUL match reported
# "did not reach a desktop". The earlier the match appeared, the more reliably
# the gate rejected a good image. It refused two builds of a raw whose log
# contains "Started sddm.service".
_gate_log=$(S cat /var/tmp/vm-gate.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
if grep -aqE 'Started sddm|Reached target graphical' <<< "$_gate_log"; then
    echo "@@ gate passed: this image boots to a desktop"
    exit 0
fi
echo "@@ FAIL gate: did not reach a desktop"
S sed 's/\x1b\[[0-9;]*m//g' /var/tmp/vm-gate.log | grep -aiE 'switch-root|Failed|error' | tail -8
exit 1
