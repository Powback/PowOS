#!/bin/bash
# test/qemu/install-e2e.sh — end-to-end installer test in a VM.
#
# Boots the REAL installer medium under QEMU+UEFI against a blank disk, drives
# the REAL guided wizard by sending Enter to the console, and then inspects the
# target image offline to prove the install landed AND that the first-boot
# config was placed on it.
#
# This exists because every failure on this path so far was invisible until
# hardware: the wizard writes to tty1 and not the journal, so a broken install
# looks identical to a working one from any log we can collect afterwards. The
# only honest test is to run it.
#
# Not run in CI: needs KVM and ~25 minutes. Run it before shipping a medium.
#
# Usage:
#   test/qemu/install-e2e.sh --medium medium.img --target target.img [--timeout 2400]
#
# Exit 0 = the target disk carries an ostree deployment AND /etc/powos/install.conf
set -uo pipefail

MEDIUM="" ; TARGET="" ; TIMEOUT=2400 ; SHOTS="${TMPDIR:-/tmp}/powos-e2e-shots"
SERIAL="${TMPDIR:-/tmp}/powos-e2e-serial.log" ; MEM="6G" ; KEYS=22 ; KEY_GAP=5
while [ $# -gt 0 ]; do
    case "$1" in
        --medium)  MEDIUM="$2"; shift 2 ;;
        --target)  TARGET="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --shots)   SHOTS="$2"; shift 2 ;;
        --serial)  SERIAL="$2"; shift 2 ;;
        --keys)    KEYS="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | cut -c3-; exit 0 ;;
        *) echo "install-e2e: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -f "$MEDIUM" ] || { echo "install-e2e: --medium must exist" >&2; exit 2; }
[ -f "$TARGET" ] || { echo "install-e2e: --target must exist (create a sparse file)" >&2; exit 2; }
MEDIUM="$(cd "$(dirname "$MEDIUM")" && pwd)/$(basename "$MEDIUM")"
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
for t in qemu-system-x86_64 socat convert; do
    command -v "$t" >/dev/null 2>&1 || { echo "install-e2e: missing tool: $t" >&2; exit 2; }
done
CODE="" VARS=""
for c in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && CODE="$c" && break; done
for v in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd;  do [ -f "$v" ] && VARS="$v" && break; done
[ -n "$CODE" ] && [ -n "$VARS" ] || { echo "install-e2e: OVMF not found" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$VARS" "$WORK/vars.fd"; mkdir -p "$SHOTS"; : > "$SERIAL"
ACCEL="-enable-kvm"; [ -e /dev/kvm ] || ACCEL="-accel tcg"

echo "install-e2e: medium=$MEDIUM target=$TARGET"
# The medium is written to: the installer imports the variant into its own
# container storage on POWOS-DATA. snapshot=off on both, deliberately.
qemu-system-x86_64 $ACCEL -m "$MEM" -smp 4 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
    -drive file="$MEDIUM",format=raw,if=virtio,cache=unsafe \
    -drive file="$TARGET",format=raw,if=virtio,cache=unsafe \
    -vga std -display none \
    -monitor unix:"$WORK/qmon",server,nowait \
    -serial file:"$SERIAL" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 &
QPID=$!
mon() { printf '%s\n' "$1" | socat - unix-connect:"$WORK/qmon" >/dev/null 2>&1; }
snap() { mon "screendump $WORK/s.ppm"; sleep 1
         [ -f "$WORK/s.ppm" ] && { convert "$WORK/s.ppm" "$SHOTS/$1.png" 2>/dev/null; rm -f "$WORK/s.ppm"; }; }

# Let firmware + GRUB + boot settle, then capture the menu as evidence.
sleep 12; snap "menu"
sleep 60; snap "booted"

# Drive the wizard. Every question is designed to be answerable with a bare
# Enter — that is the whole point of the keyboard-less design — so this is a
# faithful reproduction of what a user with only a d-pad can do.
echo "install-e2e: sending $KEYS Enters, ${KEY_GAP}s apart"
for i in $(seq 1 "$KEYS"); do
    mon "sendkey ret"
    sleep "$KEY_GAP"
    [ $((i % 4)) -eq 0 ] && snap "keys-$i"
done

echo "install-e2e: waiting up to ${TIMEOUT}s for the install to finish"
elapsed=0; next=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    sleep 15; elapsed=$((elapsed+15))
    kill -0 "$QPID" 2>/dev/null || break
    if [ "$elapsed" -ge "$next" ]; then snap "t${elapsed}s"; next=$((next+120)); fi
done
snap "final"
mon "quit"; sleep 3; kill -9 "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
echo "install-e2e: VM stopped; inspecting the target image"

# ── Verdict: inspect the target image offline ────────────────────────────────
# This is the assertion the whole test exists for. A disk that boots is not
# enough: the first-boot config has to be ON it, or the installed machine comes
# up with no account — which is exactly the failure this harness was written
# after.
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [ -n "${2:-}" ] && echo "         $2"; }

LOOP=$(losetup -Pf --show "$TARGET" 2>/dev/null) || { echo "install-e2e: cannot attach target"; exit 1; }
sleep 1
ROOTP=$(lsblk -nro NAME,LABEL "$LOOP" 2>/dev/null | awk '$2=="root"{print "/dev/"$1; exit}')
[ -n "$ROOTP" ] || ROOTP=$(lsblk -nro NAME,FSTYPE "$LOOP" 2>/dev/null | awk '$2=="btrfs"||$2=="ext4"{print "/dev/"$1; exit}')

if [ -z "$ROOTP" ]; then
    bad "the target disk was partitioned and formatted" "no root filesystem on $TARGET"
else
    ok "the target disk was partitioned and formatted ($ROOTP)"
    MNT=$(mktemp -d)
    if mount -o ro "$ROOTP" "$MNT" 2>/dev/null; then
        DEP=$(ls -d "$MNT"/ostree/deploy/*/deploy/*.[0-9] "$MNT"/*/ostree/deploy/*/deploy/*.[0-9] 2>/dev/null | head -1)
        if [ -n "$DEP" ]; then
            ok "an ostree deployment was written"
            if [ -f "$DEP/etc/powos/install.conf" ]; then
                ok "the first-boot config was placed ON the installed system"
                grep -qE '^POWOS_USERNAME=' "$DEP/etc/powos/install.conf" \
                    && ok "it carries the account settings" \
                    || bad "it carries the account settings"
            else
                bad "the first-boot config was placed ON the installed system" \
                    "the installed machine will come up with no account configured"
            fi
            [ -f "$DEP/usr/lib/systemd/system/plymouth-quit-wait.service.d/10-powos-timeout.conf" ] \
                && ok "PowOS drop-ins made it into the deployment" \
                || bad "PowOS drop-ins are missing from the deployment"
        else
            bad "an ostree deployment was written" "root fs has no deployment"
        fi
        umount "$MNT" 2>/dev/null
    else
        bad "the target root filesystem mounts" "$ROOTP"
    fi
    rmdir "$MNT" 2>/dev/null
fi
losetup -d "$LOOP" 2>/dev/null

echo ""
echo "== install-e2e: $PASS passed, $FAIL failed =="
echo "   screenshots: $SHOTS"
[ "$FAIL" -eq 0 ]
