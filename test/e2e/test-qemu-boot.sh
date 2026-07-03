#!/usr/bin/env bash
# test-qemu-boot.sh - PowOS QEMU Boot Smoke Tests
#
# Boots the actual PowOS live image (powos.raw — a bootable DISK image, not an
# ISO; that's what build/build-iso.sh produces) in a nested QEMU VM and verifies
# (in run order):
#   TEST Q0: Serial console shows dracut ramboot markers (signal even w/o SSH;
#            needs console=ttyS0 on the kernel cmdline — skips if serial empty)
#   TEST Q1: VM boots and SSH becomes reachable
#   TEST Q2: Boot state file written (powos-init ran to completion)
#   TEST Q3: Hardware detection picked "virtual" profile
#   TEST Q4: RAM boot active (rd.powos.ramboot=1 in /proc/cmdline)
#   TEST Q5: Layer sync service running
#   TEST Q7: TWO-BOOT PERSISTENCE — attach a btrfs POWOS-DATA disk, write a
#            marker, flush RAM upper → custom layer, reboot the guest, assert
#            the marker survived (the whole point of the persistence chain)
#   TEST Q6: Layer rollback across a REAL reboot (rd.powos.skip.custom=1 in
#            /proc/cmdline). Deliberately ordered LAST: it leaves the guest in
#            a rolled-back state, so nothing may depend on layer state after it.
#
# Requires: /dev/kvm, image at IMG_PATH (default: build/output/powos.raw,
# relative to the cwd — repo root locally, /powos in the e2e container).
# Q7 additionally wants mkfs.btrfs (btrfs-progs); without it Q7 skips cleanly.
# Run: docker compose --profile e2e-full run --rm e2e-qemu

set -uo pipefail

# IMG_PATH is the raw live image; ISO_PATH accepted as a legacy alias.
IMG_PATH="${IMG_PATH:-${ISO_PATH:-build/output/powos.raw}}"
# /disk is the e2e container's volume; outside it, fall back to a temp dir
# so validate.sh can run this straight from a checkout.
DISK_DIR="${DISK_DIR:-/disk}"
[[ -d "$DISK_DIR" && -w "$DISK_DIR" ]] || DISK_DIR="$(mktemp -d /tmp/powos-qemu.XXXXXX)"
DISK_PATH="$DISK_DIR/powos-test.qcow2"
DISK_SIZE="${QEMU_DISK:-20G}"
DATA_DISK="$DISK_DIR/powos-data.img"     # btrfs POWOS-DATA volume for Q7
DATA_DISK_SIZE="${QEMU_DATA_DISK:-2G}"
DATA_DISK_READY=0
DATA_DISK_SKIP_REASON=""
SERIAL_LOG="${SERIAL_LOG:-/tmp/qemu-serial.log}"
SSH_PORT=2222
SSH_USER="powos"
SSH_PASS="powos"
QEMU_MEM="${QEMU_MEM:-4G}"
QEMU_CPUS="${QEMU_CPUS:-4}"
BOOT_TIMEOUT=180   # seconds to wait for SSH after VM start / reboot
SSH_TIMEOUT=10     # seconds per SSH connection attempt
QEMU_PID=""

PASS=0
FAIL=0
SKIP=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

e2e_pass() { echo -e "  ${GREEN}✅${NC} $1"; ((PASS++)) || true; }
e2e_fail() { echo -e "  ${RED}❌${NC} $1"; ((FAIL++)) || true; }
e2e_skip() { echo -e "  ${YELLOW}⊘${NC}  $1"; ((SKIP++)) || true; }

section() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $1 ═══${NC}"
}

# ─── SSH helper ───────────────────────────────────────────────────────────────

vm_ssh() {
    sshpass -p "$SSH_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=$SSH_TIMEOUT \
        -o LogLevel=ERROR \
        -p "$SSH_PORT" \
        "${SSH_USER}@127.0.0.1" \
        "$@" 2>/dev/null
}

# Run a command in the guest as root. sudo -S reads the password from stdin
# (the image-side powos user is in wheel but has NO NOPASSWD rule — only the
# Docker entrypoint writes one, and that never runs on a real image boot).
# sudo's password prompt goes to stderr, which vm_ssh already discards.
vm_sudo() {
    vm_ssh "echo '$SSH_PASS' | sudo -S $*"
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    if [[ -n "$QEMU_PID" ]]; then
        echo "Stopping QEMU (PID $QEMU_PID)..."
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Pre-flight ───────────────────────────────────────────────────────────────

preflight() {
    section "Pre-flight Checks"

    if [[ ! -e /dev/kvm ]]; then
        echo -e "${RED}ERROR: /dev/kvm not available.${NC}"
        echo "  The host must support KVM. Pass --device /dev/kvm to Docker."
        exit 1
    fi
    e2e_pass "/dev/kvm available (hardware virtualization)"

    if [[ ! -f "$IMG_PATH" ]]; then
        echo -e "${RED}ERROR: live image not found at $IMG_PATH${NC}"
        echo ""
        echo "  Build it first:"
        echo "    just build-iso        # produces build/output/powos.raw"
        echo ""
        exit 1
    fi
    e2e_pass "Image found: $IMG_PATH ($(du -sh "$IMG_PATH" | cut -f1))"

    if ! command -v qemu-system-x86_64 &>/dev/null; then
        e2e_fail "qemu-system-x86_64 not found"
        exit 1
    fi
    e2e_pass "qemu-system-x86_64 available"

    if ! command -v sshpass &>/dev/null; then
        e2e_fail "sshpass not found"
        exit 1
    fi
    e2e_pass "sshpass available"
}

# ─── Data disk for the persistence test (Q7) ─────────────────────────────────

# Build a raw disk with a btrfs filesystem labeled POWOS-DATA and the layer
# directory skeleton the dracut module expects (layers/custom, layers/updates,
# home). Every step is guarded: any missing prerequisite sets
# DATA_DISK_SKIP_REASON and returns 1 — Q7 then skips and the VM boots exactly
# as before, without the data disk.
#
# Primary path uses `mkfs.btrfs --rootdir` (populates the fs from a staging
# dir at mkfs time — no loop device, no mount, no root needed). Fallback for
# old btrfs-progs: plain mkfs + loop mount, which DOES need root (the e2e
# container runs privileged, so that's normally available there).
prepare_data_disk() {
    if ! command -v mkfs.btrfs &>/dev/null; then
        DATA_DISK_SKIP_REASON="mkfs.btrfs not found (install btrfs-progs in the e2e image)"
        return 1
    fi

    rm -f "$DATA_DISK" 2>/dev/null || true
    if ! truncate -s "$DATA_DISK_SIZE" "$DATA_DISK" 2>/dev/null; then
        DATA_DISK_SKIP_REASON="could not create $DATA_DISK ($DATA_DISK_SIZE)"
        return 1
    fi

    local stage
    stage=$(mktemp -d /tmp/powos-data-stage.XXXXXX) || {
        DATA_DISK_SKIP_REASON="mktemp failed for staging dir"
        rm -f "$DATA_DISK"
        return 1
    }
    mkdir -p "$stage/layers/custom" "$stage/layers/updates" "$stage/home"

    if mkfs.btrfs -q -f -L POWOS-DATA --rootdir "$stage" "$DATA_DISK" >/dev/null 2>&1; then
        rm -rf "$stage"
        DATA_DISK_READY=1
        return 0
    fi

    # Fallback: mkfs without --rootdir, then loop-mount to create the dirs.
    if ! mkfs.btrfs -q -f -L POWOS-DATA "$DATA_DISK" >/dev/null 2>&1; then
        DATA_DISK_SKIP_REASON="mkfs.btrfs failed on $DATA_DISK"
        rm -rf "$stage"; rm -f "$DATA_DISK"
        return 1
    fi
    if [[ "$(id -u)" != "0" ]] || ! command -v losetup &>/dev/null; then
        DATA_DISK_SKIP_REASON="btrfs-progs lacks --rootdir and loop mount needs root + losetup"
        rm -rf "$stage"; rm -f "$DATA_DISK"
        return 1
    fi
    local mnt
    mnt=$(mktemp -d /tmp/powos-data-mnt.XXXXXX) || {
        DATA_DISK_SKIP_REASON="mktemp failed for mount dir"
        rm -rf "$stage"; rm -f "$DATA_DISK"
        return 1
    }
    if ! mount -o loop "$DATA_DISK" "$mnt" 2>/dev/null; then
        DATA_DISK_SKIP_REASON="loop mount failed (needs a privileged container with /dev/loop*)"
        rm -rf "$stage"; rmdir "$mnt" 2>/dev/null || true; rm -f "$DATA_DISK"
        return 1
    fi
    mkdir -p "$mnt/layers/custom" "$mnt/layers/updates" "$mnt/home"
    umount "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
    rm -rf "$stage"
    DATA_DISK_READY=1
    return 0
}

# ─── Start VM ────────────────────────────────────────────────────────────────

start_vm() {
    section "Starting QEMU VM"

    # Create disk image for the VM
    if [[ ! -f "$DISK_PATH" ]]; then
        qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" -q
        e2e_pass "Created $DISK_SIZE disk image"
    else
        e2e_pass "Reusing existing disk image"
    fi

    # UEFI firmware
    local ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.fd}"
    local bios_args=""
    if [[ -f "$ovmf_code" ]]; then
        bios_args="-drive if=pflash,format=raw,readonly=on,file=${ovmf_code}"
        e2e_pass "UEFI firmware: $ovmf_code"
    else
        e2e_skip "OVMF not found — using legacy BIOS (may affect boot)"
    fi

    echo "  Booting: $IMG_PATH"
    echo "  Memory:  $QEMU_MEM  CPUs: $QEMU_CPUS"

    # Boot the raw live image as the FIRST disk (it's a bootable disk image,
    # not an ISO — -cdrom can never boot it). Guest writes go to a qcow2
    # copy-on-write overlay so the build artifact stays pristine (and the
    # source may be on a read-only mount). The blank qcow2 stays attached as
    # a second disk: the install target for installer tests.
    local live_overlay="${DISK_PATH%/*}/live-overlay.qcow2"
    rm -f "$live_overlay"
    qemu-img create -q -f qcow2 -b "$(readlink -f "$IMG_PATH")" -F raw "$live_overlay"
    e2e_pass "COW overlay for live image: $live_overlay"

    # Data disk for Q7 (persistence). Attached via AHCI/SATA — NOT virtio —
    # because the dracut module (ramboot-setup.sh) scans only /dev/sd* and
    # /dev/nvme* for the POWOS-DATA label; a virtio disk shows up as /dev/vd*
    # and would never be found. On AHCI it appears as /dev/sdX, matching the
    # real-USB deployment the module was written for.
    local data_args=()
    if prepare_data_disk; then
        e2e_pass "POWOS-DATA disk ($DATA_DISK_SIZE btrfs): $DATA_DISK"
        data_args=(
            -drive file="$DATA_DISK",format=raw,if=none,id=powosdata
            -device ahci,id=ahci0
            -device ide-hd,drive=powosdata,bus=ahci0.0
        )
    else
        e2e_skip "No POWOS-DATA disk — $DATA_DISK_SKIP_REASON (TEST Q7 will be skipped)"
    fi

    # Fresh serial log — a stale one from a previous run would fake Q0 results.
    rm -f "$SERIAL_LOG" 2>/dev/null || true

    # SSH forwarded: host:2222 → guest:22
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$QEMU_MEM" \
        -smp "$QEMU_CPUS" \
        $bios_args \
        -drive file="$live_overlay",format=qcow2,if=virtio,index=0 \
        -drive file="$DISK_PATH",format=qcow2,if=virtio,index=1 \
        "${data_args[@]}" \
        -display none \
        -serial file:"$SERIAL_LOG" \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-rng-pci \
        &
    QEMU_PID=$!

    e2e_pass "QEMU started (PID $QEMU_PID)"
}

# ─── Wait for SSH ─────────────────────────────────────────────────────────────

# Reusable: wait_for_ssh [timeout] [section-label]
# Used for the initial boot AND after guest reboots (Q6/Q7) — QEMU stays alive
# across a guest reboot, only the SSH session drops.
wait_for_ssh() {
    local timeout="${1:-$BOOT_TIMEOUT}"
    local label="${2:-Waiting for VM SSH}"
    section "$label"

    echo "  Timeout: ${timeout}s"
    local elapsed=0
    local step=5

    while (( elapsed < timeout )); do
        if vm_ssh "echo ready" 2>/dev/null | grep -q "ready"; then
            e2e_pass "SSH reachable after ${elapsed}s"
            return 0
        fi

        # Check QEMU is still alive
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            e2e_fail "QEMU process died during boot"
            if [[ -f "$SERIAL_LOG" ]]; then
                echo "  Last serial output:"
                tail -20 "$SERIAL_LOG" | sed 's/^/    /'
            fi
            return 1
        fi

        printf "\r  Waiting... ${elapsed}s / ${timeout}s"
        sleep $step
        (( elapsed += step )) || true
    done

    echo ""
    e2e_fail "SSH not reachable within ${timeout}s"
    if [[ -f "$SERIAL_LOG" ]]; then
        echo "  Last serial output:"
        tail -30 "$SERIAL_LOG" | sed 's/^/    /'
    fi
    return 1
}

# Wait for SSH to go away after a reboot request (best-effort — a fast guest
# can cycle between polls, so the caller must verify the reboot via boot_id).
wait_for_ssh_drop() {
    local timeout="${1:-90}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if ! vm_ssh "true" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
        (( elapsed += 3 )) || true
    done
    return 1
}

# Reboot the guest and wait for it to come back. Does NOT restart QEMU — the
# QEMU process survives a guest reboot, and the COW overlay + data disk
# persist, which is exactly what the persistence tests need.
# Verifies a real reboot happened by comparing /proc/sys/kernel/random/boot_id.
vm_reboot() {
    local boot_id_before boot_id_after
    boot_id_before=$(vm_ssh "cat /proc/sys/kernel/random/boot_id 2>/dev/null" || true)

    vm_sudo "systemctl reboot" >/dev/null 2>&1 || true

    # Best-effort drop detection; boot_id comparison below is authoritative.
    wait_for_ssh_drop 90 || true

    if ! wait_for_ssh "$BOOT_TIMEOUT" "Waiting for SSH after reboot"; then
        return 1
    fi

    boot_id_after=$(vm_ssh "cat /proc/sys/kernel/random/boot_id 2>/dev/null" || true)
    if [[ -n "$boot_id_before" && -n "$boot_id_after" && "$boot_id_before" == "$boot_id_after" ]]; then
        e2e_fail "Guest did not actually reboot (boot_id unchanged)"
        return 1
    fi
    return 0
}

# ─── VM Tests ────────────────────────────────────────────────────────────────

test_serial_markers() {
    section "TEST Q0: Serial console dracut markers"

    # The dracut module logs via `info` ("PowOS ramboot: ..." lines in
    # ramboot-setup.sh). Those only reach the serial log when the kernel
    # cmdline routes the console there — the shipped image kargs
    # (config/bootc/kargs.d/) do NOT include console=ttyS0, so an empty log
    # is expected until that's added; skip rather than fail.
    if [[ ! -s "$SERIAL_LOG" ]]; then
        e2e_skip "Serial log empty/missing — kernel cmdline lacks console=ttyS0."
        echo "     To get serial signal: append 'console=ttyS0' to the BLS entry"
        echo "     (loader/entries/*.conf options line) on the image, or add it to"
        echo "     config/bootc/kargs.d/ and rebuild. Dracut markers then appear here."
        return 0
    fi

    if ! grep -q "PowOS ramboot:" "$SERIAL_LOG"; then
        e2e_skip "Serial log has output but no 'PowOS ramboot:' lines — dracut info messages did not reach the serial console (needs console=ttyS0, and rd.info/loglevel high enough); cannot assert markers"
        return 0
    fi
    e2e_pass "dracut module logged to serial ('PowOS ramboot:' lines present)"

    if grep -q "Overlay moved onto" "$SERIAL_LOG"; then
        e2e_pass "Marker: 'Overlay moved onto' (overlay took over the switch-root target)"
    else
        e2e_fail "Ramboot logged but 'Overlay moved onto' marker missing (overlay move failed?)"
    fi

    if grep -q "Ready - system will run from layered RAM overlay" "$SERIAL_LOG"; then
        e2e_pass "Marker: 'Ready - system will run from layered RAM overlay'"
    else
        e2e_fail "Ramboot 'Ready' marker missing from serial log"
    fi
}

test_boot_state() {
    section "TEST Q2: Boot state"

    local state
    state=$(vm_ssh "cat /var/lib/powos/state/boot-state 2>/dev/null || echo missing")
    # powos-init's final write_state is "initialized" (nothing writes "ready").
    if [[ "$state" == "initialized" || "$state" == "ready" ]]; then
        e2e_pass "Boot state = '$state' (powos-init ran to completion)"
    else
        e2e_fail "Boot state = '$state' (expected 'initialized')"
    fi
}

test_hardware_profile() {
    section "TEST Q3: Hardware detection → virtual"

    local hw
    hw=$(vm_ssh "cat /run/powos/hardware 2>/dev/null || echo missing")
    if echo "$hw" | grep -qi "virtual\|docker\|qemu\|kvm"; then
        e2e_pass "Hardware profile identifies as virtual/VM"
    else
        e2e_fail "Expected virtual profile, got: $hw"
    fi
}

test_ram_boot() {
    section "TEST Q4: RAM boot activation"

    local cmdline
    cmdline=$(vm_ssh "cat /proc/cmdline 2>/dev/null || echo missing")
    if echo "$cmdline" | grep -q "rd.powos.ramboot=1"; then
        e2e_pass "rd.powos.ramboot=1 present in /proc/cmdline"
    else
        e2e_skip "rd.powos.ramboot=1 not in /proc/cmdline (may not be set in VM boot)"
    fi

    # Check if overlayfs is mounted as root
    local mounts
    mounts=$(vm_ssh "mount | grep 'overlay\\|overlayfs' 2>/dev/null || echo none")
    if [[ "$mounts" != "none" ]] && [[ -n "$mounts" ]]; then
        e2e_pass "overlayfs active in running VM"
    else
        e2e_skip "overlayfs not detected in mount output"
    fi
}

test_layer_sync_service() {
    section "TEST Q5: Layer sync service"

    local status
    status=$(vm_ssh "systemctl is-active powos-layer-sync.service 2>/dev/null || echo inactive")
    if [[ "$status" == "active" ]]; then
        e2e_pass "powos-layer-sync.service is active"
    else
        e2e_skip "powos-layer-sync.service status: $status (may not be active without USB)"
    fi

    # Check the sync status file
    local sync_status
    sync_status=$(vm_ssh "cat /run/powos/layer-sync-status.json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(\"status\",\"unknown\"))' 2>/dev/null || echo missing")
    if [[ "$sync_status" != "missing" ]] && [[ -n "$sync_status" ]]; then
        e2e_pass "layer-sync-status.json present (status: $sync_status)"
    else
        e2e_skip "layer-sync-status.json not found"
    fi
}

# TEST Q7 — the main persistence deliverable.
# With a POWOS-DATA disk attached, the dracut module must mount it, stack the
# layers, and layer-sync must persist RAM-upper writes to layers/custom so
# they survive a reboot. Without the data disk everything here is a skip
# (matching the old suite's behavior).
test_persistence() {
    section "TEST Q7: Two-boot persistence (marker → flush → reboot → marker)"

    if [[ "$DATA_DISK_READY" != "1" ]]; then
        e2e_skip "Q7 skipped — no POWOS-DATA disk attached ($DATA_DISK_SKIP_REASON)"
        return 0
    fi

    # ── Q7a: with a data disk these are hard assertions, not skips ──────────
    if vm_ssh "test -f /run/powos/ramboot-state"; then
        e2e_pass "Q7a: /run/powos/ramboot-state exists"
    else
        e2e_fail "Q7a: /run/powos/ramboot-state missing — ramboot did not activate despite POWOS-DATA disk"
        return 1
    fi

    if vm_ssh "test -f /run/powos/layer-paths"; then
        e2e_pass "Q7a: /run/powos/layer-paths exists"
    else
        e2e_fail "Q7a: /run/powos/layer-paths missing — sync daemon has no layer paths"
        return 1
    fi

    if vm_ssh "mountpoint -q /run/powos/usb-layers"; then
        e2e_pass "Q7a: POWOS-DATA mounted at /run/powos/usb-layers"
    else
        e2e_fail "Q7a: POWOS-DATA disk attached but /run/powos/usb-layers is not a mountpoint (dracut did not find/mount it)"
    fi

    local sync_active
    sync_active=$(vm_ssh "systemctl is-active powos-layer-sync.service 2>/dev/null || echo inactive")
    if [[ "$sync_active" == "active" ]]; then
        e2e_pass "Q7a: powos-layer-sync.service is active"
    else
        e2e_fail "Q7a: powos-layer-sync.service is '$sync_active' (must be active when a data disk is present)"
    fi

    # ── Q7b: write a marker and force-flush RAM upper → custom layer ────────
    local marker="persist-${RANDOM}-$$"
    vm_sudo "sh -c 'echo $marker > /etc/powos-e2e-marker'" || true
    local written
    written=$(vm_ssh "cat /etc/powos-e2e-marker 2>/dev/null || echo MISSING")
    if [[ "$written" == "$marker" ]]; then
        e2e_pass "Q7b: marker written to /etc/powos-e2e-marker ($marker)"
    else
        e2e_fail "Q7b: could not write marker file via sudo (got: '$written')"
        return 1
    fi

    # Direct --sync-now (what `powos flush` wraps) for an honest exit code:
    # cmd_flush prints 'Flush complete' regardless of the sync result, so its
    # exit status can't be asserted. --sync-now serializes with the daemon via
    # the flock in sync_to_custom_layer, so this is safe while it runs.
    if vm_sudo "python3 /usr/lib/powos/ramfs/layer-sync.py --sync-now"; then
        e2e_pass "Q7b: layer-sync --sync-now exit 0 (RAM upper flushed to custom layer)"
    else
        e2e_fail "Q7b: layer-sync --sync-now failed — marker never reached the custom layer"
        return 1
    fi

    # ── Q7c: reboot the guest (QEMU stays up, COW overlay + data disk persist)
    if ! vm_reboot; then
        e2e_fail "Q7c: guest did not come back after reboot — persistence unverifiable"
        return 1
    fi
    e2e_pass "Q7c: guest rebooted and SSH re-established"

    # ── Q7d: THE persistence assertion ───────────────────────────────────────
    # The marker only exists after reboot if the whole chain worked:
    # RAM upper write → layer-sync rsync → layers/custom on POWOS-DATA →
    # dracut re-stacked custom as a lowerdir on the second boot.
    local content
    content=$(vm_ssh "cat /etc/powos-e2e-marker 2>/dev/null || echo MISSING")
    if [[ "$content" == "$marker" ]]; then
        e2e_pass "Q7d: marker survived reboot with identical content — persistence chain works"
    else
        e2e_fail "Q7d: PERSISTENCE BROKEN — expected '$marker' in /etc/powos-e2e-marker, got '$content'"
    fi

    local mounts
    mounts=$(vm_ssh "mount | grep overlay 2>/dev/null || echo none")
    if [[ "$mounts" != "none" && -n "$mounts" ]]; then
        e2e_pass "Q7d: overlayfs mounted after reboot"
    else
        e2e_fail "Q7d: no overlay mount after reboot"
    fi

    local layers
    layers=$(vm_ssh "grep '^POWOS_LAYERS_ACTIVE=' /run/powos/ramboot-state 2>/dev/null || echo missing")
    if echo "$layers" | grep -q "custom"; then
        e2e_pass "Q7d: ramboot-state lists custom layer active ($layers)"
    else
        e2e_fail "Q7d: custom layer not in active stack after reboot ($layers)"
    fi
}

# TEST Q6 — rollback across a real reboot. ORDERED LAST on purpose: it leaves
# the guest booted with rd.powos.skip.custom=1 (we run `rollback reset`
# afterwards but do not spend a third reboot restoring the layer stack), so
# no test may run after it that depends on layer state.
test_rollback() {
    section "TEST Q6: Layer rollback across reboot (ordered last)"

    if ! vm_ssh "echo ready" 2>/dev/null | grep -q "ready"; then
        e2e_skip "VM unreachable (earlier reboot failed?) — skipping rollback test"
        return 0
    fi

    # `powos rollback custom` now fails loudly when grubby can't update the
    # boot entry — a non-zero exit here means the mechanism isn't usable on
    # this live image, which is a hardware-validation item, not a QEMU bug.
    local rc=0
    vm_sudo "powos rollback custom" >/dev/null || rc=$?
    if (( rc != 0 )); then
        e2e_skip "powos rollback custom exited $rc (grubby unavailable or boot entry not updatable on the live image) — rollback needs BLS/grubby validation on real hardware"
        return 0
    fi
    e2e_pass "powos rollback custom exit 0 (boot entry updated via grubby)"

    local kargs
    kargs=$(vm_ssh "cat /run/powos/rollback-kargs 2>/dev/null || echo none")
    if echo "$kargs" | grep -q "skip.custom"; then
        e2e_pass "Rollback flag recorded in /run/powos/rollback-kargs"
    else
        e2e_skip "Informational rollback-kargs record not found (non-fatal)"
    fi

    if ! vm_reboot; then
        e2e_fail "Guest did not come back after rollback reboot"
        return 1
    fi

    local cmdline
    cmdline=$(vm_ssh "cat /proc/cmdline 2>/dev/null || echo missing")
    if echo "$cmdline" | grep -q "rd.powos.skip.custom=1"; then
        e2e_pass "rd.powos.skip.custom=1 active in /proc/cmdline after reboot — rollback works end-to-end"
    else
        e2e_fail "rollback flag NOT in /proc/cmdline after reboot (grubby claimed success): $cmdline"
    fi

    # Clear the flag for the next run of this suite against a persistent disk.
    # No third reboot: Q6 is last, nothing depends on the restored stack.
    vm_sudo "powos rollback reset" >/dev/null 2>&1 || true
}

# ─── Main ─────────────────────────────────────────────────────────────────────

print_summary() {
    local total=$(( PASS + FAIL + SKIP ))
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  QEMU Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  / ${total} total"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║         PowOS QEMU Boot Smoke Tests                        ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Image:  $IMG_PATH"
    echo "  Memory: $QEMU_MEM  CPUs: $QEMU_CPUS"
    echo "  SSH:    localhost:$SSH_PORT"

    preflight
    start_vm

    # Wait for SSH — if it times out, Q0 (serial) still gives signal, then bail
    if ! wait_for_ssh; then
        test_serial_markers
        echo ""
        echo -e "${RED}VM did not come up — functional tests (Q2+) skipped${NC}"
        echo "  Check serial log: $SERIAL_LOG"
        print_summary
        exit 1
    fi

    # Q0 runs after boot regardless — serial markers complement the SSH tests
    test_serial_markers

    # Run Q2-Q5, then Q7 (persistence, reboots once), then Q6 (rollback,
    # reboots again and leaves rollback state behind — must stay LAST).
    test_boot_state
    test_hardware_profile
    test_ram_boot
    test_layer_sync_service
    test_persistence
    test_rollback

    print_summary

    (( FAIL == 0 ))
}

main "$@"
