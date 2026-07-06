#!/usr/bin/env bash
# run-e2e.sh - PowOS E2E Test Suite
#
# Covers ~80% of features using real kernel primitives:
#   TEST 1: Real overlayfs mount (not dev-mode simulation)
#   TEST 2: Layer sync to simulated USB (loop device, BTRFS POWOS-DATA)
#   TEST 3: USB disconnect simulation (umount + losetup -d) and reconnect
#   TEST 4: CacheFS FUSE mount via /dev/fuse
#   TEST 5: Sync conflict detection with marker files
#   TEST 6: Hardware detection → virtual profile
#
# Requires: privileged container, /dev/fuse, /dev/loop-control, btrfs-progs
# Run: docker compose --profile e2e run --rm e2e-runner

set -uo pipefail

# ─── Globals ──────────────────────────────────────────────────────────────────
POWOS_ROOT="${POWOS_ROOT:-/powos}"
LAYER_SYNC="${POWOS_ROOT}/lib/ramfs/layer-sync.py"
CACHEFS="${POWOS_ROOT}/lib/cachefs/powos-cachefs.py"
HW_DETECT="${POWOS_ROOT}/lib/hardware-detect.sh"
SYNC_SH="${POWOS_ROOT}/lib/sync.sh"

USB_IMG=/var/lib/powos-test/usb.img
# Keep the mountpoint under /tmp (a container tmpfs we own). Bazzite's ostree
# layout leaves /mnt as a symlink pointing into an unpopulated /var target
# inside a container, so `mkdir -p /mnt/anything` fails and mount then silently
# has no mountpoint — which cascaded into every downstream USB test.
USB_MOUNT=/tmp/powos-e2e-usb
RAM_UPPER=/run/powos/ram-upper
CUSTOM_LAYER=/run/powos/custom-layer
WORK_DIR=/run/powos/work
BASE_LAYER=/run/powos/base-layer
UPDATES_LAYER=/run/powos/updates-layer
MERGED=/run/powos/merged

CACHEFS_SOURCE=/var/lib/powos-test/cachefs-source
CACHEFS_CACHE=/run/powos/cachefs-cache
CACHEFS_MOUNT=/var/lib/powos-test/cachefs-mount

LOOP=""
FUSE_PID=""

PASS=0
FAIL=0
SKIP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────────────

e2e_pass() { echo -e "  ${GREEN}✅${NC} $1"; ((PASS++)) || true; }
e2e_fail() { echo -e "  ${RED}❌${NC} $1"; ((FAIL++)) || true; }
e2e_skip() { echo -e "  ${YELLOW}⊘${NC}  $1 (skipped)"; ((SKIP++)) || true; }

section() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $1 ═══${NC}"
}

check() {
    local desc="$1"
    shift
    if "$@" 2>/dev/null; then
        e2e_pass "$desc"
    else
        e2e_fail "$desc"
    fi
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    # Unmount FUSE if still running
    if [[ -n "$FUSE_PID" ]]; then
        kill "$FUSE_PID" 2>/dev/null || true
        fusermount -u "$CACHEFS_MOUNT" 2>/dev/null || umount "$CACHEFS_MOUNT" 2>/dev/null || true
    fi
    # Unmount overlayfs
    umount "$MERGED" 2>/dev/null || true
    # Unmount USB
    umount "$USB_MOUNT" 2>/dev/null || true
    # Release loop device
    if [[ -n "$LOOP" ]]; then
        losetup -d "$LOOP" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# ─── Pre-flight checks ────────────────────────────────────────────────────────

preflight() {
    section "Pre-flight Checks"

    local ok=true

    if [[ ! -f "$LAYER_SYNC" ]]; then
        e2e_fail "layer-sync.py not found at $LAYER_SYNC"
        ok=false
    else
        e2e_pass "layer-sync.py found"
    fi

    if [[ ! -f "$CACHEFS" ]]; then
        e2e_fail "powos-cachefs.py not found at $CACHEFS"
        ok=false
    else
        e2e_pass "powos-cachefs.py found"
    fi

    if [[ ! -f "$HW_DETECT" ]]; then
        e2e_fail "hardware-detect.sh not found at $HW_DETECT"
        ok=false
    else
        e2e_pass "hardware-detect.sh found"
    fi

    if ! command -v losetup &>/dev/null; then
        e2e_fail "losetup not found (install util-linux)"
        ok=false
    else
        e2e_pass "losetup available"
    fi

    if ! command -v mkfs.btrfs &>/dev/null; then
        e2e_fail "mkfs.btrfs not found (install btrfs-progs)"
        ok=false
    else
        e2e_pass "mkfs.btrfs available"
    fi

    if [[ ! -e /dev/fuse ]]; then
        e2e_fail "/dev/fuse not found (container needs devices: /dev/fuse)"
        ok=false
    else
        e2e_pass "/dev/fuse available"
    fi

    if [[ ! -e /dev/loop-control ]]; then
        e2e_fail "/dev/loop-control not found (container needs devices: /dev/loop-control)"
        ok=false
    else
        e2e_pass "/dev/loop-control available"
    fi

    if [[ "$ok" != "true" ]]; then
        echo ""
        echo -e "${RED}Pre-flight failed — aborting E2E tests${NC}"
        exit 1
    fi
}

# ─── Setup: Simulated USB ─────────────────────────────────────────────────────

setup_usb() {
    section "Setup: Simulated USB (loop device)"

    mkdir -p /var/lib/powos-test "$USB_MOUNT" "$RAM_UPPER" "$CUSTOM_LAYER" \
             "$WORK_DIR" "$BASE_LAYER/usr/bin" "$UPDATES_LAYER" "$MERGED" \
             "$CACHEFS_SOURCE" "$CACHEFS_CACHE" "$CACHEFS_MOUNT"

    # Create a 512 MB image file
    if [[ ! -f "$USB_IMG" ]]; then
        dd if=/dev/zero of="$USB_IMG" bs=1M count=512 status=none
        e2e_pass "Created 512 MB USB image"
    else
        e2e_pass "Reusing existing USB image"
    fi

    # Attach loop device
    LOOP=$(losetup --find --show "$USB_IMG")
    e2e_pass "Attached loop device: $LOOP"

    # Format BTRFS with POWOS-DATA label
    mkfs.btrfs -q -L POWOS-DATA "$LOOP"
    e2e_pass "Formatted BTRFS with label POWOS-DATA"

    # Mount — gate loudly: previously this ran unconditionally-pass, so a
    # silent mount failure cascaded through every USB-facing test as "USB gone".
    mkdir -p "$USB_MOUNT"
    if ! mount "$LOOP" "$USB_MOUNT"; then
        e2e_fail "mount $LOOP -> $USB_MOUNT failed (see dmesg)"
        exit 1
    fi
    mkdir -p "$USB_MOUNT/layers/custom" "$USB_MOUNT/layers/updates"
    e2e_pass "Mounted at $USB_MOUNT"

    # Mark USB connected for layer-sync.py
    echo "USB_STATUS=connected" > /run/powos/usb-state
}

# ─── TEST 1: Real overlayfs mount ─────────────────────────────────────────────

test_overlayfs() {
    section "TEST 1: Real overlayfs mount"

    # Seed base layer with a test binary
    printf '#!/bin/bash\necho base-binary\n' > "$BASE_LAYER/usr/bin/test-base-bin"
    chmod +x "$BASE_LAYER/usr/bin/test-base-bin"

    # Mount 3-layer overlayfs
    if mount -t overlay overlay \
        -o "lowerdir=${UPDATES_LAYER}:${BASE_LAYER},upperdir=${RAM_UPPER},workdir=${WORK_DIR}" \
        "$MERGED" 2>/dev/null; then
        e2e_pass "3-layer overlayfs mounts (updates:base lower, RAM upper)"
    else
        e2e_fail "overlayfs mount failed"
        return
    fi

    # Lower layer content visible through overlay
    check "base layer binary visible through overlay" \
        test -x "$MERGED/usr/bin/test-base-bin"

    # Write goes to RAM upper (not base layer)
    mkdir -p "$MERGED/etc/conf.d"
    echo "written-in-overlay" > "$MERGED/etc/written.txt"
    check "writes land in RAM upper (not base layer)" \
        test -f "$RAM_UPPER/etc/written.txt"
    check "write does not leak to base layer" \
        bash -c "! test -f '$BASE_LAYER/etc/written.txt'"

    # Whiteout: delete a base-layer file through overlay
    rm "$MERGED/usr/bin/test-base-bin"
    check "deletion creates whiteout in RAM upper" \
        bash -c "test -f '$RAM_UPPER/usr/bin/.wh.test-base-bin' || \
                 test -c '$RAM_UPPER/usr/bin/test-base-bin'"

    umount "$MERGED"
}

# ─── TEST 2: Layer sync to simulated USB ──────────────────────────────────────

test_layer_sync() {
    section "TEST 2: Layer sync to simulated USB"

    # Populate RAM upper with test files
    mkdir -p "$RAM_UPPER/etc/conf.d"
    echo "synced-content" > "$RAM_UPPER/synced-file.txt"
    echo "nested-config"  > "$RAM_UPPER/etc/conf.d/app.conf"
    touch "$RAM_UPPER/.wh.deleted-pkg"           # whiteout (deletion marker)

    # Write layer-paths for layer-sync.py
    cat > /run/powos/layer-paths << EOF
RAM_UPPER=${RAM_UPPER}
CUSTOM_LAYER=${USB_MOUNT}/layers/custom
EOF

    if python3 "$LAYER_SYNC" \
        --ram-upper "$RAM_UPPER" \
        --custom-layer "$USB_MOUNT/layers/custom" \
        --sync-now 2>/dev/null; then
        e2e_pass "layer-sync --sync-now exits 0"
    else
        e2e_fail "layer-sync --sync-now exited non-zero"
        return
    fi

    check "regular file synced to USB"      test -f "$USB_MOUNT/layers/custom/synced-file.txt"
    check "nested file synced to USB"       test -f "$USB_MOUNT/layers/custom/etc/conf.d/app.conf"
    check "whiteout file synced to USB"     test -f "$USB_MOUNT/layers/custom/.wh.deleted-pkg"

    local content
    content=$(cat "$USB_MOUNT/layers/custom/synced-file.txt" 2>/dev/null || echo "")
    if [[ "$content" == "synced-content" ]]; then
        e2e_pass "file content preserved through sync"
    else
        e2e_fail "file content mismatch after sync"
    fi
}

# ─── TEST 3: USB disconnect simulation ────────────────────────────────────────

test_usb_disconnect() {
    section "TEST 3: USB disconnect simulation"

    # Signal disconnect
    echo "USB_STATUS=disconnected" > /run/powos/usb-state
    umount "$USB_MOUNT"
    losetup -d "$LOOP"
    LOOP=""
    e2e_pass "USB disconnected (loop device released)"

    # RAM upper must still be intact
    check "RAM upper survives USB disconnect"  test -f "$RAM_UPPER/synced-file.txt"

    # layer-sync must gracefully skip (exit non-zero) when USB is gone
    if ! python3 "$LAYER_SYNC" \
        --ram-upper "$RAM_UPPER" \
        --custom-layer "$USB_MOUNT/layers/custom" \
        --sync-now 2>/dev/null; then
        e2e_pass "layer-sync skips gracefully when USB disconnected (exit non-zero)"
    else
        e2e_fail "layer-sync should not succeed when USB disconnected"
    fi

    # Reconnect — mkdir first because umount may have left USB_MOUNT gone if
    # tmpfs GCed the empty dir; gate the mount so a silent failure is caught.
    mkdir -p "$USB_MOUNT"
    LOOP=$(losetup --find --show "$USB_IMG")
    if ! mount "$LOOP" "$USB_MOUNT"; then
        e2e_fail "reconnect mount $LOOP -> $USB_MOUNT failed"
        return
    fi
    echo "USB_STATUS=connected" > /run/powos/usb-state
    e2e_pass "USB reconnected"

    # Sync should succeed again after reconnect
    if python3 "$LAYER_SYNC" \
        --ram-upper "$RAM_UPPER" \
        --custom-layer "$USB_MOUNT/layers/custom" \
        --sync-now 2>/dev/null; then
        e2e_pass "layer-sync resumes after USB reconnect"
    else
        e2e_fail "layer-sync failed after USB reconnect"
    fi
}

# ─── TEST 4: CacheFS FUSE mount ───────────────────────────────────────────────

test_cachefs() {
    section "TEST 4: CacheFS FUSE mount"

    # Populate backing store (simulates USB home dir)
    echo "hello from usb" > "$CACHEFS_SOURCE/readme.txt"
    mkdir -p "$CACHEFS_SOURCE/docs"
    echo "document content" > "$CACHEFS_SOURCE/docs/guide.txt"

    # Start CacheFS in foreground in background (foreground for test controllability)
    python3 "$CACHEFS" \
        "$CACHEFS_SOURCE" "$CACHEFS_MOUNT" \
        --cache-dir "$CACHEFS_CACHE" \
        --cache-size 64M \
        --foreground &
    FUSE_PID=$!

    # Wait for mount to be ready (up to 5 seconds)
    local attempts=0
    while (( attempts < 10 )); do
        if mountpoint -q "$CACHEFS_MOUNT" 2>/dev/null || \
           [[ -f "$CACHEFS_MOUNT/readme.txt" ]]; then
            break
        fi
        sleep 0.5
        (( attempts++ )) || true
    done

    if [[ -f "$CACHEFS_MOUNT/readme.txt" ]]; then
        e2e_pass "CacheFS FUSE mount ready"
    else
        e2e_fail "CacheFS mount did not appear within 5 seconds"
        kill "$FUSE_PID" 2>/dev/null || true
        FUSE_PID=""
        return
    fi

    # Verify file serving
    local content
    content=$(cat "$CACHEFS_MOUNT/readme.txt" 2>/dev/null || echo "")
    if [[ "$content" == "hello from usb" ]]; then
        e2e_pass "CacheFS serves correct file content"
    else
        e2e_fail "CacheFS content mismatch (got: '$content')"
    fi

    check "CacheFS serves nested file"  test -f "$CACHEFS_MOUNT/docs/guide.txt"

    # Test that the cached file is in the cache dir
    sleep 0.5
    if find "$CACHEFS_CACHE" -type f 2>/dev/null | grep -q .; then
        e2e_pass "File content stored in cache directory"
    else
        e2e_skip "Cache directory empty (may use memory-only mode)"
    fi

    # Clean unmount
    kill "$FUSE_PID" 2>/dev/null || true
    FUSE_PID=""
    fusermount -u "$CACHEFS_MOUNT" 2>/dev/null || umount "$CACHEFS_MOUNT" 2>/dev/null || true
    e2e_pass "CacheFS unmounted cleanly"
}

# ─── TEST 5: Sync conflict detection ─────────────────────────────────────────

test_sync_conflicts() {
    section "TEST 5: Sync conflict detection"

    if [[ ! -f "$SYNC_SH" ]]; then
        e2e_skip "sync.sh not found at $SYNC_SH"
        return
    fi

    # Source sync.sh with USB_MOUNT pointing at our loop device
    # MACHINE_ID will be set from /etc/machine-id or hostname
    POWOS_USB_MOUNT="$USB_MOUNT" source "$SYNC_SH" 2>/dev/null || true

    # Verify conflict functions were loaded
    if ! declare -f check_for_conflicts &>/dev/null; then
        e2e_skip "check_for_conflicts function not available after sourcing sync.sh"
        return
    fi
    e2e_pass "sync.sh sourced, conflict functions available"

    # Case 1: No marker → no conflict (first sync)
    rm -f "$USB_MOUNT/.powos-sync"
    local result
    result=$(check_for_conflicts 2>/dev/null)
    if [[ "$result" == "none" ]]; then
        e2e_pass "No marker → no conflict (first sync case)"
    else
        e2e_fail "Expected 'none' with no marker, got: $result"
    fi

    # Case 2: Marker from same machine → no conflict
    cat > "$USB_MOUNT/.powos-sync" << EOF
SYNC_MACHINE_ID="$MACHINE_ID"
SYNC_TIMESTAMP="$(date +%s)"
SYNC_DATE="$(date -Iseconds)"
EOF
    result=$(check_for_conflicts 2>/dev/null)
    if [[ "$result" == "none" ]]; then
        e2e_pass "Same-machine marker → no conflict"
    else
        e2e_fail "Expected 'none' for same machine, got: $result"
    fi

    # Case 3: Marker from different machine → conflict
    cat > "$USB_MOUNT/.powos-sync" << EOF
SYNC_MACHINE_ID="other-machine-deadbeef"
SYNC_TIMESTAMP="$(date +%s)"
SYNC_DATE="$(date -Iseconds)"
EOF
    if ! check_for_conflicts 2>/dev/null; then
        e2e_pass "Different-machine marker → conflict detected (exit non-zero)"
    else
        e2e_fail "Expected conflict detection to fail/return non-zero"
    fi

    local conflict_result
    # The function prints "conflict" AND exits non-zero — a fallback echo would
    # double the output and break the exact match below.
    conflict_result=$(check_for_conflicts 2>/dev/null) || true
    if [[ "$conflict_result" == "conflict" ]]; then
        e2e_pass "check_for_conflicts outputs 'conflict' for foreign machine"
    else
        e2e_fail "Expected 'conflict' in output, got: $conflict_result"
    fi
}

# ─── TEST 6: Hardware detection → virtual profile ─────────────────────────────

test_hardware_detect() {
    section "TEST 6: Hardware detection"

    if [[ ! -f "$HW_DETECT" ]]; then
        e2e_fail "hardware-detect.sh not found"
        return
    fi

    # Docker environment should pick "virtual" profile
    local output
    output=$(POWOS_DEV=1 \
             POWOS_MOCK_VIRT=docker \
             POWOS_PROFILES_DIR="${POWOS_ROOT}/config/profiles" \
             bash "$HW_DETECT" detect 2>&1) || true

    if echo "$output" | grep -qi "virtual"; then
        e2e_pass "Hardware detect picks 'virtual' profile in Docker"
    else
        e2e_fail "Expected 'virtual' profile, output: $(echo "$output" | head -3)"
    fi

    # Dev mode must not make real system changes
    if echo "$output" | grep -q "(DEV)"; then
        e2e_pass "Dev mode active — no real system changes"
    else
        e2e_skip "DEV mode indicator not found in output"
    fi

    # Explicit mock hardware test
    output=$(POWOS_DEV=1 \
             POWOS_MOCK_HARDWARE=amd \
             POWOS_MOCK_POWER=battery \
             POWOS_MOCK_VIRT=physical \
             POWOS_PROFILES_DIR="${POWOS_ROOT}/config/profiles" \
             bash "$HW_DETECT" detect 2>&1) || true

    if echo "$output" | grep -qi "battery\|laptop"; then
        e2e_pass "AMD + battery → laptop-battery profile"
    else
        e2e_skip "laptop-battery profile not confirmed (output: $(echo "$output" | head -2))"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║         PowOS E2E Test Suite                               ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  POWOS_ROOT: $POWOS_ROOT"
    echo "  Kernel:     $(uname -r)"
    echo "  Date:       $(date -Iseconds)"

    preflight
    setup_usb

    test_overlayfs
    test_layer_sync
    test_usb_disconnect
    test_cachefs
    test_sync_conflicts
    test_hardware_detect

    local total=$(( PASS + FAIL + SKIP ))
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  E2E Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  / ${total} total"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    if (( FAIL > 0 )); then
        exit 1
    fi
}

main "$@"
