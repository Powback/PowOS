#!/bin/bash
# test/qemu/boot-verify.sh — Tier-2 VM boot test.
#
# Boot a PowOS raw disk image under QEMU + UEFI (OVMF) and assert it reaches an
# expected state without hitting forbidden failures — capturing the serial log
# and periodic framebuffer screenshots for evidence. This is the automated
# real-boot check the repo previously lacked (see the "Tier-2 VM testing"
# ❌ row in CLAUDE.md's Feature Status).
#
# It cannot run on GitHub's runners (no KVM); run it on a KVM-capable Linux host
# or a privileged container with /dev/kvm. Falls back to TCG (slow) without KVM.
#
# Requires: qemu-system-x86_64, qemu-img, edk2-ovmf (OVMF_CODE.fd + OVMF_VARS.fd),
#           socat, ImageMagick (`convert`, for screenshots).
#
# Usage:
#   test/qemu/boot-verify.sh --raw IMG \
#       [--expect REGEX] [--forbid REGEX] [--timeout SEC] \
#       [--vga std|virtio] [--shots DIR] [--serial FILE] [--mem 4G]
#
# Exit 0 = an --expect marker appeared and no --forbid marker did.
# Exit 1 = a --forbid marker appeared, or the timeout elapsed with no --expect.
#
# Notes:
#   - OVMF needs BOTH a CODE pflash AND a WRITABLE VARS pflash, or the firmware
#     halts before GRUB ("Guest has not initialized the display").
#   - PowOS images bake console=ttyS0, so the kernel/systemd log reaches --serial;
#     graphical output does not (it hands off to the display). Screenshots catch
#     the framebuffer (GRUB, text consoles, the installer wizard, a login).
set -uo pipefail

RAW="" ; EXPECT="" ; FORBID="" ; TIMEOUT=360 ; VGA="std"
SHOTS="${TMPDIR:-/tmp}/powos-boot-shots" ; SERIAL="${TMPDIR:-/tmp}/powos-boot-serial.log" ; MEM="4G"
while [ $# -gt 0 ]; do
    case "$1" in
        --raw)     RAW="$2"; shift 2 ;;
        --expect)  EXPECT="$2"; shift 2 ;;
        --forbid)  FORBID="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --vga)     VGA="$2"; shift 2 ;;
        --shots)   SHOTS="$2"; shift 2 ;;
        --serial)  SERIAL="$2"; shift 2 ;;
        --mem)     MEM="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | cut -c3-; exit 0 ;;
        *) echo "boot-verify: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -f "$RAW" ] || { echo "boot-verify: --raw IMG required and must exist" >&2; exit 2; }
for t in qemu-system-x86_64 qemu-img socat convert; do
    command -v "$t" >/dev/null 2>&1 || { echo "boot-verify: missing tool: $t" >&2; exit 2; }
done

CODE="" VARS_TMPL=""
for c in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && CODE="$c" && break; done
for v in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$v" ] && VARS_TMPL="$v" && break; done
[ -n "$CODE" ] && [ -n "$VARS_TMPL" ] || { echo "boot-verify: OVMF CODE/VARS not found (install edk2-ovmf)" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$VARS_TMPL" "$WORK/vars.fd"
qemu-img create -f qcow2 -b "$RAW" -F raw "$WORK/ov.qcow2" >/dev/null   # COW: never mutate the raw
mkdir -p "$SHOTS"; : > "$SERIAL"
ACCEL="-enable-kvm"; [ -e /dev/kvm ] || { ACCEL="-accel tcg"; echo "boot-verify: no /dev/kvm — TCG (slow)"; }

echo "boot-verify: booting $RAW (vga=$VGA, timeout=${TIMEOUT}s)"
qemu-system-x86_64 $ACCEL -m "$MEM" -smp 4 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
    -drive file="$WORK/ov.qcow2",format=qcow2,if=virtio \
    -vga "$VGA" -display none \
    -monitor unix:"$WORK/qmon",server,nowait \
    -serial file:"$SERIAL" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 &
QPID=$!

snap() {
    printf 'screendump %s\n' "$WORK/s.ppm" | socat - unix-connect:"$WORK/qmon" >/dev/null 2>&1
    sleep 1
    [ -f "$WORK/s.ppm" ] && { convert "$WORK/s.ppm" "$SHOTS/$1.png" 2>/dev/null && echo "  snap $1.png"; rm -f "$WORK/s.ppm"; }
}
strip() { sed 's/\x1b\[[0-9;]*m//g' "$SERIAL"; }

result="timeout" ; elapsed=0 ; next_snap=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    sleep 5; elapsed=$((elapsed+5))
    kill -0 "$QPID" 2>/dev/null || { result="qemu-exited"; break; }
    if [ "$elapsed" -ge "$next_snap" ]; then snap "t${elapsed}s"; next_snap=$((next_snap+30)); fi
    if [ -n "$FORBID" ] && strip | grep -qiE "$FORBID"; then result="FORBIDDEN (~${elapsed}s)"; break; fi
    if [ -n "$EXPECT" ] && strip | grep -qiE "$EXPECT"; then result="EXPECTED (~${elapsed}s)"; break; fi
done
snap "final"
kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true

echo "boot-verify: result=$result"
echo "--- kernel cmdline ---"; strip | grep -iE "Command line:" | head -1
echo "--- last 15 serial lines ---"; strip | tail -15
echo "--- screenshots in $SHOTS ---"; ls "$SHOTS" 2>/dev/null | tail -12

case "$result" in
    EXPECTED*) echo "boot-verify: PASS"; exit 0 ;;
    *)         echo "boot-verify: FAIL ($result)"; exit 1 ;;
esac
