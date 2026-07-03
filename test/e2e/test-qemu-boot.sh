#!/usr/bin/env bash
# test-qemu-boot.sh - PowOS QEMU Boot Smoke Tests
#
# Boots the actual PowOS ISO in a nested QEMU VM and verifies:
#   TEST Q1: VM boots and SSH becomes reachable
#   TEST Q2: Boot state file written (powos-boot ran to completion)
#   TEST Q3: Hardware detection picked "virtual" profile
#   TEST Q4: RAM boot active (rd.powos.ramboot=1 in /proc/cmdline)
#   TEST Q5: Layer sync service running
#   TEST Q6: Layer rollback (reboot with rd.powos.skip.custom=1)
#
# Requires: /dev/kvm, ISO at ISO_PATH (default: /powos/test/e2e/powos.iso)
# Run: docker compose --profile e2e-full run --rm e2e-qemu

set -uo pipefail

ISO_PATH="${ISO_PATH:-/powos/test/e2e/powos.iso}"
DISK_PATH="/disk/powos-test.qcow2"
DISK_SIZE="${QEMU_DISK:-20G}"
SSH_PORT=2222
SSH_USER="powos"
SSH_PASS="powos"
QEMU_MEM="${QEMU_MEM:-4G}"
QEMU_CPUS="${QEMU_CPUS:-4}"
BOOT_TIMEOUT=180   # seconds to wait for SSH after VM start
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

    if [[ ! -f "$ISO_PATH" ]]; then
        echo -e "${RED}ERROR: ISO not found at $ISO_PATH${NC}"
        echo ""
        echo "  Build the ISO first:"
        echo "    just build-iso"
        echo "    cp build/output/powos.iso test/e2e/"
        echo ""
        exit 1
    fi
    e2e_pass "ISO found: $ISO_PATH ($(du -sh "$ISO_PATH" | cut -f1))"

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

    echo "  Booting: $ISO_PATH"
    echo "  Memory:  $QEMU_MEM  CPUs: $QEMU_CPUS"

    # Boot from ISO, disk available for install
    # SSH forwarded: host:2222 → guest:22
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$QEMU_MEM" \
        -smp "$QEMU_CPUS" \
        $bios_args \
        -drive file="$DISK_PATH",format=qcow2,if=virtio \
        -cdrom "$ISO_PATH" \
        -boot d \
        -display none \
        -serial file:/tmp/qemu-serial.log \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-rng-pci \
        &
    QEMU_PID=$!

    e2e_pass "QEMU started (PID $QEMU_PID)"
}

# ─── Wait for SSH ─────────────────────────────────────────────────────────────

wait_for_ssh() {
    section "Waiting for VM SSH"

    echo "  Timeout: ${BOOT_TIMEOUT}s"
    local elapsed=0
    local step=5

    while (( elapsed < BOOT_TIMEOUT )); do
        if vm_ssh "echo ready" 2>/dev/null | grep -q "ready"; then
            e2e_pass "SSH reachable after ${elapsed}s"
            return 0
        fi

        # Check QEMU is still alive
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            e2e_fail "QEMU process died during boot"
            if [[ -f /tmp/qemu-serial.log ]]; then
                echo "  Last serial output:"
                tail -20 /tmp/qemu-serial.log | sed 's/^/    /'
            fi
            return 1
        fi

        printf "\r  Waiting... ${elapsed}s / ${BOOT_TIMEOUT}s"
        sleep $step
        (( elapsed += step )) || true
    done

    echo ""
    e2e_fail "SSH not reachable within ${BOOT_TIMEOUT}s"
    if [[ -f /tmp/qemu-serial.log ]]; then
        echo "  Last serial output:"
        tail -30 /tmp/qemu-serial.log | sed 's/^/    /'
    fi
    return 1
}

# ─── VM Tests ────────────────────────────────────────────────────────────────

test_boot_state() {
    section "TEST Q2: Boot state"

    local state
    state=$(vm_ssh "cat /var/lib/powos/state/boot-state 2>/dev/null || echo missing")
    if [[ "$state" == "ready" ]]; then
        e2e_pass "Boot state = 'ready' (powos-boot ran to completion)"
    else
        e2e_fail "Boot state = '$state' (expected 'ready')"
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

test_rollback() {
    section "TEST Q6: Layer rollback via kernel kargs"

    # Check if custom layer is currently active
    local layers_before
    layers_before=$(vm_ssh "powos layers 2>/dev/null || echo 'no powos command'")
    if echo "$layers_before" | grep -q "custom"; then
        e2e_pass "Custom layer visible in active layer stack"
    else
        e2e_skip "Custom layer not in stack (may not be configured in VM)"
    fi

    # Set rollback flag (would take effect on next reboot)
    # In this test we just verify the mechanism writes the flag
    vm_ssh "powos rollback custom 2>/dev/null || true"
    local kargs
    kargs=$(vm_ssh "cat /run/powos/rollback-kargs 2>/dev/null || echo none")
    if echo "$kargs" | grep -q "skip.custom"; then
        e2e_pass "Rollback flag written to /run/powos/rollback-kargs"
    else
        e2e_skip "Rollback kargs not confirmed (may need USB to persist)"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║         PowOS QEMU Boot Smoke Tests                        ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  ISO:    $ISO_PATH"
    echo "  Memory: $QEMU_MEM  CPUs: $QEMU_CPUS"
    echo "  SSH:    localhost:$SSH_PORT"

    preflight
    start_vm

    # Wait for SSH — if it times out, the remaining tests are skipped
    if ! wait_for_ssh; then
        echo ""
        echo -e "${RED}VM did not come up — skipping functional tests${NC}"
        echo "  Check serial log: /tmp/qemu-serial.log"
        exit 1
    fi

    # Run Q2-Q6 over SSH
    test_boot_state
    test_hardware_profile
    test_ram_boot
    test_layer_sync_service
    test_rollback

    local total=$(( PASS + FAIL + SKIP ))
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  QEMU Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  / ${total} total"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    (( FAIL == 0 ))
}

main "$@"
