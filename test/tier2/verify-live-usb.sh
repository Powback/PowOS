#!/usr/bin/env bash
# verify-live-usb.sh - boot a live-USB raw in QEMU and check the things that
# unit tests cannot: that it boots, and that the installer's disk menu shows
# real removable media correctly.
#
# WHY THIS EXISTS
# The installer's target-disk menu pre-highlights its first entry, and lsblk
# lists mmcblk/USB before nvme. On a Steam Deck that meant pressing Enter
# installed onto the SD card and erased the games on it. The fix orders
# internal disks first and flags removable ones — but every test of it so far
# used FIXTURES. This boots a real kernel, attaches a real USB block device,
# and asks the real code what it sees.
#
# The VM gets three disks on purpose:
#   virtio  the live image itself   (must be excluded — it is the boot media)
#   virtio  a blank "internal SSD"  (the legitimate install target)
#   usb     a blank "SD card"       (must be flagged removable and sorted last)
#
# Usage:
#   ./test/tier2/verify-live-usb.sh path/to/disk.raw [--keep]
#
# Requires qemu + OVMF. If they are not on the host it runs them from
# localhost/powos-qemu-runner (see the header of this repo's VM notes); the
# host only needs podman and /dev/kvm.

set -uo pipefail

RAW="${1:-}"
KEEP="${2:-}"
[[ -f "$RAW" ]] || { echo "usage: $0 <disk.raw> [--keep]"; exit 1; }
RAW=$(readlink -f "$RAW")

WORK=$(mktemp -d)
cleanup() { [[ "$KEEP" == "--keep" ]] || rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

RUNNER="${POWOS_QEMU_RUNNER:-localhost/powos-qemu-runner:latest}"
SSH_PORT="${SSH_PORT:-2223}"

echo "== preparing VM disks =="
# Never write to the caller's image: work on a copy-on-write overlay so a
# failed boot or a stray install cannot corrupt the artifact we are testing.
qemu_img() { podman run --rm -v "$WORK":/w -v "$(dirname "$RAW")":/src:ro -w /w "$RUNNER" qemu-img "$@"; }
qemu_img create -f qcow2 -F raw -b "/src/$(basename "$RAW")" /w/live.qcow2 >/dev/null 2>&1 \
    || { echo "  could not create the overlay"; exit 1; }
qemu_img create -f qcow2 /w/internal.qcow2 40G >/dev/null 2>&1
qemu_img create -f qcow2 /w/sdcard.qcow2   16G >/dev/null 2>&1
ok "overlay + blank internal disk + blank USB 'SD card' created"

echo ""
echo "== booting =="
CONSOLE="$WORK/console.log"
: > "$CONSOLE"

podman run -d --name powos-verify --device /dev/kvm \
    -v "$WORK":/w -p "$SSH_PORT:2222" "$RUNNER" \
    bash -c '
      cp /usr/share/edk2/ovmf/OVMF_CODE.fd /w/CODE.fd
      cp /usr/share/edk2/ovmf/OVMF_VARS.fd /w/VARS.fd
      exec qemu-system-x86_64 \
        -enable-kvm -machine q35,smm=on -cpu host -smp 4 -m 8G \
        -drive if=pflash,format=raw,readonly=on,file=/w/CODE.fd \
        -drive if=pflash,format=raw,file=/w/VARS.fd \
        -drive file=/w/live.qcow2,format=qcow2,if=virtio \
        -drive file=/w/internal.qcow2,format=qcow2,if=virtio \
        -device qemu-xhci,id=xhci \
        -drive if=none,id=sdcard,format=qcow2,file=/w/sdcard.qcow2 \
        -device usb-storage,bus=xhci.0,drive=sdcard,removable=on \
        -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
        -serial file:/w/console.log -display none -no-reboot' >/dev/null 2>&1 \
    || { echo "  could not start the VM"; exit 1; }

# Cover BOTH outcomes: a login prompt, and every failure signature we know how
# to recognise. Silence must not read as success.
success='Reached target Login Prompts|Started .*Login Manager|Started SDDM|Started Plasma Login|plasmalogin\.service.*Started'
failure='Kernel panic|Emergency mode|Reached target Emergency|Reached target Rescue|Failed to start plasmalogin|systemd-sysext\.service.*Failed|powos-overlay\.service.*failed|Failed to merge|Extension contains'

verdict=""
for _ in $(seq 1 120); do   # up to ~10 minutes
    if grep -qE "$failure" "$CONSOLE" 2>/dev/null; then verdict=fail; break; fi
    if grep -qE "$success" "$CONSOLE" 2>/dev/null; then verdict=up;   break; fi
    podman inspect powos-verify --format '{{.State.Running}}' 2>/dev/null | grep -q true || { verdict=died; break; }
    sleep 5
done

case "$verdict" in
    up)   ok "live image boots to a login prompt" ;;
    fail) bad "live image boots" "failure signature in console: $(grep -oE "$failure" "$CONSOLE" | head -1)" ;;
    died) bad "live image boots" "QEMU exited before reaching a login prompt" ;;
    *)    bad "live image boots" "no login/failure marker within the timeout" ;;
esac

if [[ "$verdict" == "up" ]]; then
    echo ""
    echo "== installer disk enumeration, on real block devices =="
    # sshd is enabled in the image; the powos user's password is 'powos'.
    ssh_run() {
        podman run --rm --network host "$RUNNER" \
            sshpass -p powos ssh -p "$SSH_PORT" \
              -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 powos@127.0.0.1 "$1" 2>/dev/null
    }
    listing=""
    for _ in $(seq 1 30); do
        listing=$(ssh_run 'source /usr/lib/powos/install-wizard.sh 2>/dev/null; iwz_list_disks')
        [[ -n "$listing" ]] && break
        sleep 5
    done

    if [[ -z "$listing" ]]; then
        bad "could reach the guest over SSH to inspect disks" "no output; sshd may not be up"
    else
        echo "$listing" | while IFS=$'\t' read -r dev size model rm tran; do
            printf '         %-14s %-7s removable=%-4s tran=%s\n' "$dev" "$size" "$rm" "$tran"
        done

        # The USB device must be seen AND flagged.
        if echo "$listing" | awk -F'\t' '$4=="yes"' | grep -q .; then
            ok "the USB 'SD card' is flagged removable on real hardware"
        else
            bad "USB device flagged removable" "nothing reported removable=yes"
        fi

        # The first entry is what a bare Enter selects. It must not be removable.
        first_rm=$(echo "$listing" | head -1 | awk -F'\t' '{print $4}')
        if [[ "$first_rm" == "no" ]]; then
            ok "first menu entry is an INTERNAL disk (Enter cannot pick the SD card)"
        else
            bad "first menu entry is internal" "first entry has removable='$first_rm'"
        fi

        # The live media itself must never be offered as a target.
        if echo "$listing" | grep -q "$(ssh_run 'lsblk -no PKNAME "$(blkid -L POWOS-DATA 2>/dev/null)" 2>/dev/null | head -1')"; then
            bad "the live boot media is excluded from install targets"
        else
            ok "the live boot media is not offered as an install target"
        fi
    fi
fi

echo ""
echo "  console log: $CONSOLE"
[[ "$KEEP" == "--keep" ]] && echo "  VM kept running as container 'powos-verify'" \
    || podman rm -f powos-verify >/dev/null 2>&1

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
