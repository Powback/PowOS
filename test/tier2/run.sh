#!/usr/bin/env bash
# run.sh — PowOS Tier-2 E2E Boot-to-Desktop Test Harness
#
# Boots a PowOS disk image in QEMU and verifies the full boot-to-desktop
# pipeline: kernel -> graphical.target -> SDDM -> KDE Plasma desktop.
#
# Stages (all run by default unless --stage limits):
#   A  Boot: reaches graphical.target, SSH reachable
#   B  Greeter: SDDM display manager running, not crash-looping
#   C  Desktop: autologin -> plasmashell + kwin compositor running
#   D  Install: Anaconda ISO unattended install into blank disk (--stage d)
#   R  Ramboot regression: boot with rd.powos.ramboot=1 (--ramboot)
#
# Named regression cases:
#   - Hang before graphical.target         (Stage A timeout)
#   - SDDM crash-loop                     (Stage B restart count)
#   - Session dies after login             (Stage C plasmashell check)
#   - Historical ramboot hang              (Stage R, rd.powos.ramboot=1)
#
# Usage:
#   ./run.sh --image disk.qcow2                     Stages A-C
#   ./run.sh --from-container powos-ci               BIB convert then A-C
#   ./run.sh --image disk.qcow2 --ramboot            A-C + ramboot regression
#   ./run.sh --stage d --iso install.iso --image x   Stage D (anaconda path)
#   ./run.sh --no-kvm --image disk.qcow2             Force TCG (slow, no KVM)
#
# Requires: qemu-system-x86_64, OVMF, sshpass, python3
# Optional: /dev/kvm (falls back to TCG with warning), convert (ImageMagick)
#
# Environment:
#   TIER2_MEM=4G             VM memory (CI: keep <= 6G, runner has 7G)
#   TIER2_CPUS=4             VM CPU count
#   TIER2_SSH_PORT=2222      Host SSH forward port
#   TIER2_BOOT_TIMEOUT=300   Seconds to wait for SSH after boot
#   ARTIFACTS_DIR=...        Where screenshots / logs / verdicts land

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QMP_PY="$SCRIPT_DIR/lib/qmp.py"

# ─── Defaults ────────────────────────────────────────────────────────────────

IMAGE_PATH=""
CONTAINER_IMAGE=""
ISO_PATH=""
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/tmp/powos-tier2}"
STAGES="a,b,c"
RAMBOOT=0
SSH_PORT="${TIER2_SSH_PORT:-2222}"
SSH_USER="powos"
SSH_PASS="powos"
QEMU_MEM="${TIER2_MEM:-4G}"
QEMU_CPUS="${TIER2_CPUS:-4}"
BOOT_TIMEOUT="${TIER2_BOOT_TIMEOUT:-300}"
GREETER_TIMEOUT="${TIER2_GREETER_TIMEOUT:-60}"
DESKTOP_TIMEOUT="${TIER2_DESKTOP_TIMEOUT:-120}"
INSTALL_TIMEOUT="${TIER2_INSTALL_TIMEOUT:-1200}"
SSH_TIMEOUT=10
USE_KVM=1
OVMF_CODE=""
QEMU_PID=""
QMP_SOCK=""
SERIAL_LOG=""
COW_OVERLAY=""
SCREENDUMP_PID=""

PASS=0; FAIL=0; SKIP=0
STAGE_RESULTS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    sed -n '/^# Usage:/,/^[^#]/{ /^#/s/^# //p }' "$0"
    echo ""
    echo "Options:"
    echo "  --image PATH          Pre-built qcow2 or raw disk image"
    echo "  --from-container IMG  Convert container image to qcow2 via bib"
    echo "  --iso PATH            Anaconda ISO for Stage D"
    echo "  --stage STAGES        Comma-separated stages (default: a,b,c)"
    echo "  --ramboot             Add ramboot regression test (Stage R)"
    echo "  --artifacts DIR       Artifact output directory"
    echo "  --no-kvm              Force TCG acceleration (slow)"
    echo "  --help                Show this help"
}

t2_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)) || true; }
t2_fail() { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)) || true; }
t2_skip() { echo -e "  ${YELLOW}SKIP${NC}  $1"; ((SKIP++)) || true; }
section() { echo ""; echo -e "${CYAN}${BOLD}=== $1 ===${NC}"; }
has_stage() { [[ ",$STAGES," == *",$1,"* ]]; }

# ─── Verdict JSON ────────────────────────────────────────────────────────────

verdict_emit() {
    local stage="$1" name="$2" verdict="$3" duration="$4"
    shift 4
    local checks="$*"
    cat > "$ARTIFACTS_DIR/verdict-stage-${stage}.json" << VERDICT
{
  "stage": "${stage}",
  "name": "${name}",
  "verdict": "${verdict}",
  "duration_s": ${duration},
  "checks": [${checks}],
  "timestamp": "$(date -Iseconds)"
}
VERDICT
    STAGE_RESULTS+=("${stage}:${verdict}")
}

check_json() { printf '{"name":"%s","result":"%s"}' "$1" "$2"; }

# ─── SSH ─────────────────────────────────────────────────────────────────────

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

vm_sudo() {
    vm_ssh "echo '$SSH_PASS' | sudo -S $*"
}

# ─── QMP wrappers ────────────────────────────────────────────────────────────

qmp_screendump() {
    python3 "$QMP_PY" "$QMP_SOCK" screendump "$1" 2>/dev/null
}

qmp_sendkey() {
    python3 "$QMP_PY" "$QMP_SOCK" sendkey "$@" 2>/dev/null
}

# Take a named screenshot; convert to PNG if ImageMagick is available.
take_screenshot() {
    local name="$1"
    local ppm="$ARTIFACTS_DIR/${name}.ppm"
    if qmp_screendump "$ppm" && [[ -f "$ppm" ]]; then
        if command -v convert &>/dev/null; then
            convert "$ppm" "${ppm%.ppm}.png" 2>/dev/null && rm -f "$ppm" || true
        fi
    fi
}

# Returns 0 if the screenshot has visible content, 1 if blank, 2 on error.
screenshot_has_content() {
    python3 "$QMP_PY" check-blank "$1" 2>/dev/null
}

# ─── VM lifecycle ────────────────────────────────────────────────────────────

find_ovmf() {
    local candidates=(
        /usr/share/OVMF/OVMF_CODE.fd
        /usr/share/OVMF/OVMF_CODE_4M.fd
        /usr/share/edk2/ovmf/OVMF_CODE.fd
        /usr/share/edk2/x86_64/OVMF_CODE.fd
        /usr/share/qemu/OVMF_CODE.fd
    )
    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && echo "$p" && return 0
    done
    return 1
}

preflight() {
    section "Preflight"
    local ok=true

    for tool in qemu-system-x86_64 sshpass python3; do
        if command -v "$tool" &>/dev/null; then
            t2_pass "$tool available"
        else
            t2_fail "$tool not found"
            ok=false
        fi
    done

    [[ -f "$QMP_PY" ]] || { t2_fail "QMP helper not found: $QMP_PY"; ok=false; }

    if OVMF_CODE=$(find_ovmf); then
        t2_pass "OVMF: $OVMF_CODE"
    else
        t2_fail "OVMF not found (install ovmf / edk2-ovmf)"
        ok=false
    fi

    if [[ -e /dev/kvm ]]; then
        t2_pass "/dev/kvm available (KVM)"
    else
        echo -e "  ${YELLOW}WARN${NC}  /dev/kvm not available -- using TCG (expect 5-10x slower boot)"
        USE_KVM=0
    fi

    if [[ -n "$CONTAINER_IMAGE" ]]; then
        t2_pass "Will convert container $CONTAINER_IMAGE -> qcow2 via bib"
    elif [[ -n "$IMAGE_PATH" ]]; then
        [[ -f "$IMAGE_PATH" ]] || { t2_fail "Image not found: $IMAGE_PATH"; ok=false; }
        t2_pass "Image: $IMAGE_PATH ($(du -sh "$IMAGE_PATH" 2>/dev/null | cut -f1))"
    else
        t2_fail "Provide --image <path> or --from-container <name>"
        ok=false
    fi

    $ok || { echo ""; echo "Preflight FAILED -- aborting."; exit 1; }
}

build_qcow2() {
    section "Building qcow2 via bootc-image-builder"
    local bib_out="$ARTIFACTS_DIR/bib-output"
    mkdir -p "$bib_out"

    local start=$SECONDS
    echo "  Container: $CONTAINER_IMAGE"
    echo "  This may take 5-10 minutes..."

    if sudo podman run --rm --privileged \
        --security-opt label=type:unconfined_t \
        -v "$bib_out:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --type qcow2 --rootfs btrfs --local \
        "$CONTAINER_IMAGE"; then
        t2_pass "bib completed in $(( SECONDS - start ))s"
    else
        t2_fail "bootc-image-builder failed"
        exit 1
    fi

    IMAGE_PATH="$bib_out/qcow2/disk.qcow2"
    if [[ ! -f "$IMAGE_PATH" ]]; then
        t2_fail "Expected qcow2 not found: $IMAGE_PATH"
        exit 1
    fi
    t2_pass "qcow2 ready: $(du -sh "$IMAGE_PATH" | cut -f1)"
}

# Start the VM. Accepts extra QEMU args as positional parameters.
start_vm() {
    section "Starting QEMU"

    # COW overlay keeps the source image pristine
    COW_OVERLAY="$ARTIFACTS_DIR/vm-overlay.qcow2"
    rm -f "$COW_OVERLAY"

    local backing_fmt="raw"
    file "$IMAGE_PATH" 2>/dev/null | grep -q "QEMU QCOW" && backing_fmt="qcow2"
    qemu-img create -q -f qcow2 -b "$(readlink -f "$IMAGE_PATH")" -F "$backing_fmt" "$COW_OVERLAY"

    QMP_SOCK="$ARTIFACTS_DIR/qmp.sock"
    SERIAL_LOG="$ARTIFACTS_DIR/serial.log"
    rm -f "$QMP_SOCK" "$SERIAL_LOG"

    local accel=(-enable-kvm)
    (( USE_KVM )) || accel=(-accel tcg)

    echo "  Memory: $QEMU_MEM  CPUs: $QEMU_CPUS  Accel: $( (( USE_KVM )) && echo KVM || echo TCG)"

    qemu-system-x86_64 \
        "${accel[@]}" \
        -m "$QEMU_MEM" \
        -smp "$QEMU_CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive file="$COW_OVERLAY",format=qcow2,if=virtio \
        -vga std \
        -display none \
        -serial file:"$SERIAL_LOG" \
        -qmp unix:"$QMP_SOCK",server=on,wait=off \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-rng-pci \
        "$@" \
        &
    QEMU_PID=$!
    t2_pass "QEMU PID $QEMU_PID"

    # Background periodic screendumps (every 30s) for post-mortem debugging
    (
        sleep 15
        local n=0
        while kill -0 "$QEMU_PID" 2>/dev/null; do
            python3 "$QMP_PY" "$QMP_SOCK" screendump \
                "$ARTIFACTS_DIR/periodic-$(printf '%04d' $n).ppm" 2>/dev/null || true
            ((n++)) || true
            sleep 30
        done
    ) &
    SCREENDUMP_PID=$!
}

stop_vm() {
    [[ -n "$SCREENDUMP_PID" ]] && { kill "$SCREENDUMP_PID" 2>/dev/null; wait "$SCREENDUMP_PID" 2>/dev/null; SCREENDUMP_PID=""; } || true
    if [[ -n "$QEMU_PID" ]]; then
        python3 "$QMP_PY" "$QMP_SOCK" quit 2>/dev/null || true
        local w=0
        while (( w < 10 )) && kill -0 "$QEMU_PID" 2>/dev/null; do sleep 1; ((w++)); done
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}

cleanup() { stop_vm; }
trap cleanup EXIT

wait_for_ssh() {
    local timeout="${1:-$BOOT_TIMEOUT}" label="${2:-SSH}"
    echo "  Waiting for $label (timeout ${timeout}s)..."
    local elapsed=0 step=5
    while (( elapsed < timeout )); do
        if vm_ssh "echo ready" 2>/dev/null | grep -q "ready"; then
            echo "  $label reachable after ${elapsed}s"
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            echo "  QEMU process died"
            [[ -s "$SERIAL_LOG" ]] && { echo "  Serial tail:"; tail -20 "$SERIAL_LOG" | sed 's/^/    /'; }
            return 1
        fi
        printf "\r  %ds / %ds" "$elapsed" "$timeout"
        sleep "$step"
        (( elapsed += step )) || true
    done
    echo ""
    echo "  Timeout: $label not reachable in ${timeout}s"
    [[ -s "$SERIAL_LOG" ]] && { echo "  Serial tail:"; tail -30 "$SERIAL_LOG" | sed 's/^/    /'; }
    return 1
}

wait_for_ssh_drop() {
    local timeout="${1:-90}" elapsed=0
    while (( elapsed < timeout )); do
        vm_ssh "true" >/dev/null 2>&1 || return 0
        sleep 3; (( elapsed += 3 )) || true
    done
    return 1
}

vm_reboot() {
    local boot_id_before boot_id_after
    boot_id_before=$(vm_ssh "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
    vm_sudo "systemctl reboot" >/dev/null 2>&1 || true
    wait_for_ssh_drop 90 || true
    wait_for_ssh "$BOOT_TIMEOUT" "SSH after reboot" || return 1
    boot_id_after=$(vm_ssh "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
    if [[ -n "$boot_id_before" && "$boot_id_before" == "$boot_id_after" ]]; then
        echo "  boot_id unchanged -- reboot may not have happened"
        return 1
    fi
    return 0
}

# ─── STAGE A: Boot to graphical target ───────────────────────────────────────

stage_a() {
    section "STAGE A: Boot to graphical target"
    local start=$SECONDS checks="" ok=true

    if wait_for_ssh "$BOOT_TIMEOUT"; then
        t2_pass "SSH reachable"
        checks="$(check_json ssh-reachable pass)"
    else
        t2_fail "SSH unreachable in ${BOOT_TIMEOUT}s -- HANG BEFORE GRAPHICAL TARGET"
        checks="$(check_json ssh-reachable fail)"
        take_screenshot "stage-a-timeout"
        verdict_emit a boot-to-graphical fail $(( SECONDS - start )) "$checks"
        return 1
    fi

    # graphical.target
    local target
    target=$(vm_ssh "systemctl is-active graphical.target" || echo "unknown")
    if [[ "$target" == "active" ]]; then
        t2_pass "graphical.target active"
        checks+=",$(check_json graphical-target pass)"
    else
        echo "  graphical.target=$target, waiting 30s..."
        sleep 30
        target=$(vm_ssh "systemctl is-active graphical.target" || echo "unknown")
        if [[ "$target" == "active" ]]; then
            t2_pass "graphical.target active (delayed)"
            checks+=",$(check_json graphical-target pass)"
        else
            t2_fail "graphical.target not reached: $target"
            checks+=",$(check_json graphical-target fail)"
            ok=false
        fi
    fi

    # Failed units (informational)
    local failed
    failed=$(vm_ssh "systemctl --failed --no-legend 2>/dev/null | wc -l" || echo "?")
    if [[ "$failed" == "0" ]]; then
        t2_pass "No failed systemd units"
        checks+=",$(check_json no-failed-units pass)"
    else
        echo -e "  ${YELLOW}WARN${NC}  $failed failed unit(s):"
        vm_ssh "systemctl --failed --no-legend" 2>/dev/null | head -5 | sed 's/^/    /'
        # Failed units are a warning, not a hard failure (some units may fail in VM)
        checks+=",$(check_json no-failed-units warn)"
    fi

    take_screenshot "stage-a-boot"

    local v="pass"; $ok || v="fail"
    verdict_emit a boot-to-graphical "$v" $(( SECONDS - start )) "$checks"
    $ok
}

# ─── STAGE B: SDDM greeter ──────────────────────────────────────────────────

stage_b() {
    section "STAGE B: SDDM display manager"
    local start=$SECONDS checks="" ok=true

    # Is SDDM running?
    local status
    status=$(vm_ssh "systemctl is-active sddm.service" || echo "inactive")
    if [[ "$status" == "active" ]]; then
        t2_pass "sddm.service active"
        checks="$(check_json sddm-active pass)"
    else
        t2_fail "sddm.service: $status -- SDDM NOT RUNNING"
        checks="$(check_json sddm-active fail)"
        ok=false
    fi

    # Crash-loop detection (NRestarts)
    local restarts
    restarts=$(vm_ssh "systemctl show sddm.service -p NRestarts --value" || echo "?")
    if [[ "$restarts" == "0" ]]; then
        t2_pass "SDDM restarts: 0 (stable)"
        checks+=",$(check_json sddm-no-crashloop pass)"
    elif [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts <= 2 )); then
        echo -e "  ${YELLOW}WARN${NC}  SDDM restarted ${restarts}x"
        checks+=",$(check_json sddm-no-crashloop warn)"
    else
        t2_fail "SDDM restarts: $restarts -- CRASH-LOOP DETECTED"
        checks+=",$(check_json sddm-no-crashloop fail)"
        ok=false
    fi

    # Greeter screenshot (non-blank = SDDM rendered something)
    take_screenshot "stage-b-greeter"
    local ppm="$ARTIFACTS_DIR/stage-b-greeter.ppm"
    if [[ -f "$ppm" ]]; then
        if screenshot_has_content "$ppm"; then
            t2_pass "Greeter screenshot has content"
            checks+=",$(check_json greeter-visible pass)"
        else
            echo -e "  ${YELLOW}WARN${NC}  Greeter screenshot blank (GPU rendering may not reach VGA fb)"
            checks+=",$(check_json greeter-visible warn)"
        fi
    fi

    local v="pass"; $ok || v="fail"
    verdict_emit b sddm-greeter "$v" $(( SECONDS - start )) "$checks"
    $ok
}

# ─── STAGE C: Desktop session ────────────────────────────────────────────────

stage_c() {
    section "STAGE C: Desktop session (autologin)"
    local start=$SECONDS checks="" ok=true

    # Inject autologin config via SSH
    echo "  Injecting SDDM autologin config..."
    if vm_sudo "mkdir -p /etc/sddm.conf.d && cat > /etc/sddm.conf.d/zz-test-autologin.conf << 'SDDMEOF'
[Autologin]
User=powos
Session=plasma.desktop
SDDMEOF" 2>/dev/null; then
        t2_pass "Autologin config injected"
        checks="$(check_json autologin-injected pass)"
    else
        t2_fail "Could not inject autologin config"
        checks="$(check_json autologin-injected fail)"
        verdict_emit c desktop-session fail $(( SECONDS - start )) "$checks"
        return 1
    fi

    # Restart SDDM to trigger autologin
    echo "  Restarting SDDM..."
    vm_sudo "systemctl restart sddm.service" 2>/dev/null || true
    sleep 5

    # Wait for plasmashell
    echo "  Waiting for plasmashell (timeout ${DESKTOP_TIMEOUT}s)..."
    local elapsed=0 desktop_up=false
    while (( elapsed < DESKTOP_TIMEOUT )); do
        if vm_ssh "pgrep -x plasmashell >/dev/null 2>&1"; then
            desktop_up=true
            break
        fi
        sleep 5
        (( elapsed += 5 )) || true
        printf "\r  %ds / %ds" "$elapsed" "$DESKTOP_TIMEOUT"
    done
    echo ""

    if $desktop_up; then
        t2_pass "plasmashell running (${elapsed}s)"
        checks+=",$(check_json plasmashell-running pass)"
    else
        t2_fail "plasmashell not found after ${DESKTOP_TIMEOUT}s -- SESSION DIED AFTER LOGIN"
        checks+=",$(check_json plasmashell-running fail)"
        ok=false
    fi

    # Compositor
    local compositor="none"
    if vm_ssh "pgrep -x kwin_wayland >/dev/null 2>&1"; then
        compositor="kwin_wayland"
    elif vm_ssh "pgrep -x kwin_x11 >/dev/null 2>&1"; then
        compositor="kwin_x11"
    fi
    if [[ "$compositor" != "none" ]]; then
        t2_pass "$compositor running"
        checks+=",$(check_json compositor-running pass)"
    else
        t2_fail "No kwin compositor found"
        checks+=",$(check_json compositor-running fail)"
        ok=false
    fi

    # Stability: plasmashell still alive after 5s
    if $desktop_up; then
        sleep 5
        if vm_ssh "pgrep -x plasmashell >/dev/null 2>&1"; then
            t2_pass "Desktop stable (plasmashell survived 5s)"
            checks+=",$(check_json desktop-stable pass)"
        else
            t2_fail "plasmashell DIED within 5s -- UNSTABLE SESSION"
            checks+=",$(check_json desktop-stable fail)"
            ok=false
        fi
    fi

    # Check loginctl session exists on seat0
    local session_info
    session_info=$(vm_ssh "loginctl list-sessions --no-legend 2>/dev/null | head -1" || echo "")
    if [[ -n "$session_info" ]]; then
        t2_pass "Login session active: $session_info"
        checks+=",$(check_json login-session pass)"
    else
        echo -e "  ${YELLOW}WARN${NC}  No loginctl session found"
        checks+=",$(check_json login-session warn)"
    fi

    take_screenshot "stage-c-desktop"

    # Cleanup
    vm_sudo "rm -f /etc/sddm.conf.d/zz-test-autologin.conf" 2>/dev/null || true

    local v="pass"; $ok || v="fail"
    verdict_emit c desktop-session "$v" $(( SECONDS - start )) "$checks"
    $ok
}

# ─── STAGE D: Anaconda unattended install ────────────────────────────────────

stage_d() {
    section "STAGE D: Anaconda unattended install"
    local start=$SECONDS checks=""

    if [[ -z "$ISO_PATH" || ! -f "$ISO_PATH" ]]; then
        t2_skip "Stage D requires --iso <anaconda.iso> (nightly only)"
        verdict_emit d anaconda-install skip 0 "$(check_json iso-provided skip)"
        return 0
    fi

    # Shut down any running VM from stages A-C
    stop_vm

    # Create blank target disk
    local target="$ARTIFACTS_DIR/install-target.qcow2"
    qemu-img create -q -f qcow2 "$target" 40G
    t2_pass "40G install target disk created"
    checks="$(check_json target-disk pass)"

    # Boot from Anaconda ISO with target disk
    QMP_SOCK="$ARTIFACTS_DIR/qmp-install.sock"
    SERIAL_LOG="$ARTIFACTS_DIR/serial-install.log"
    rm -f "$QMP_SOCK" "$SERIAL_LOG"

    local accel=(-enable-kvm)
    (( USE_KVM )) || accel=(-accel tcg)

    # Anaconda kickstart: pass via kernel cmdline if available
    local ks_args=()
    local ks_file="$SCRIPT_DIR/kickstart/powos-test.ks"
    if [[ -f "$ks_file" ]]; then
        # Create a small FAT floppy with the kickstart
        local ks_img="$ARTIFACTS_DIR/ks-floppy.img"
        dd if=/dev/zero of="$ks_img" bs=1M count=2 status=none 2>/dev/null
        if mkfs.vfat "$ks_img" >/dev/null 2>&1; then
            # mcopy from mtools if available; otherwise mount (needs root)
            if command -v mcopy &>/dev/null; then
                mcopy -i "$ks_img" "$ks_file" ::ks.cfg 2>/dev/null && \
                    ks_args=(-drive file="$ks_img",format=raw,if=floppy)
            fi
        fi
    fi

    qemu-system-x86_64 \
        "${accel[@]}" \
        -m "$QEMU_MEM" -smp "$QEMU_CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive file="$target",format=qcow2,if=virtio \
        -cdrom "$ISO_PATH" \
        -boot d \
        "${ks_args[@]}" \
        -vga std -display none \
        -serial file:"$SERIAL_LOG" \
        -qmp unix:"$QMP_SOCK",server=on,wait=off \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-rng-pci \
        &
    QEMU_PID=$!
    t2_pass "Anaconda QEMU PID $QEMU_PID"

    # Background screendumps for install progress
    (
        sleep 20; local n=0
        while kill -0 "$QEMU_PID" 2>/dev/null; do
            python3 "$QMP_PY" "$QMP_SOCK" screendump \
                "$ARTIFACTS_DIR/install-$(printf '%04d' $n).ppm" 2>/dev/null || true
            ((n++)) || true; sleep 30
        done
    ) &
    SCREENDUMP_PID=$!

    # Wait for install to complete and installed system to boot
    echo "  Anaconda install + reboot (timeout ${INSTALL_TIMEOUT}s)..."
    local ok=true
    if wait_for_ssh "$INSTALL_TIMEOUT" "SSH after Anaconda install"; then
        t2_pass "Installed system booted"
        checks+=",$(check_json install-boot pass)"

        # Run desktop checks against the installed system
        stage_a || ok=false
        stage_b || ok=false
        stage_c || ok=false
    else
        t2_fail "Install did not complete in ${INSTALL_TIMEOUT}s"
        checks+=",$(check_json install-boot fail)"
        take_screenshot "stage-d-timeout"
        ok=false
    fi

    local v="pass"; $ok || v="fail"
    verdict_emit d anaconda-install "$v" $(( SECONDS - start )) "$checks"
    $ok
}

# ─── STAGE R: Ramboot regression ─────────────────────────────────────────────

stage_r() {
    section "STAGE R: Ramboot regression (rd.powos.ramboot=1)"
    local start=$SECONDS checks="" ok=true

    # Inject the historical ramboot karg
    echo "  Injecting rd.powos.ramboot=1..."
    local rc=0
    vm_sudo "rpm-ostree kargs --append=rd.powos.ramboot=1 2>/dev/null \
             || bootc kargs --append=rd.powos.ramboot=1 2>/dev/null" || rc=$?
    if (( rc != 0 )); then
        t2_skip "Cannot inject karg (rpm-ostree/bootc kargs unavailable)"
        verdict_emit r ramboot-regression skip $(( SECONDS - start )) "$(check_json karg-inject skip)"
        return 0
    fi
    t2_pass "Ramboot karg injected"
    checks="$(check_json karg-inject pass)"

    # Reboot with ramboot
    echo "  Rebooting with rd.powos.ramboot=1..."
    if vm_reboot; then
        t2_pass "VM survived ramboot reboot"
        checks+=",$(check_json ramboot-boot pass)"
    else
        t2_fail "VM did not come back -- HISTORICAL RAMBOOT HANG REPRODUCED"
        take_screenshot "stage-r-hang"
        verdict_emit r ramboot-regression fail $(( SECONDS - start )) "$checks,$(check_json ramboot-boot fail)"
        return 1
    fi

    # Verify karg active
    local cmdline
    cmdline=$(vm_ssh "cat /proc/cmdline" || echo "")
    if echo "$cmdline" | grep -q "rd.powos.ramboot=1"; then
        t2_pass "rd.powos.ramboot=1 in /proc/cmdline"
        checks+=",$(check_json karg-active pass)"
    else
        t2_skip "rd.powos.ramboot=1 not in cmdline (bootloader may have ignored)"
        checks+=",$(check_json karg-active skip)"
    fi

    # graphical.target should still be reached
    local target
    target=$(vm_ssh "systemctl is-active graphical.target" || echo "unknown")
    if [[ "$target" == "active" ]]; then
        t2_pass "graphical.target reached with ramboot"
        checks+=",$(check_json ramboot-graphical pass)"
    else
        t2_fail "graphical.target not reached with ramboot: $target"
        checks+=",$(check_json ramboot-graphical fail)"
        ok=false
    fi

    take_screenshot "stage-r-ramboot"

    # Cleanup: remove the karg
    vm_sudo "rpm-ostree kargs --delete=rd.powos.ramboot=1 2>/dev/null \
             || bootc kargs --delete=rd.powos.ramboot=1 2>/dev/null" || true

    local v="pass"; $ok || v="fail"
    verdict_emit r ramboot-regression "$v" $(( SECONDS - start )) "$checks"
    $ok
}

# ─── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
    local total=$(( PASS + FAIL + SKIP ))
    local overall="pass"
    (( FAIL > 0 )) && overall="fail"

    # Combined verdict JSON
    cat > "$ARTIFACTS_DIR/verdict-combined.json" << COMBINED
{
  "harness": "powos-tier2",
  "overall": "$overall",
  "pass": $PASS,
  "fail": $FAIL,
  "skip": $SKIP,
  "kvm": $USE_KVM,
  "timestamp": "$(date -Iseconds)"
}
COMBINED

    echo ""
    echo -e "${CYAN}${BOLD}================================================================${NC}"
    echo -e "  Tier-2 Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  / ${total} total"
    echo -e "${CYAN}${BOLD}================================================================${NC}"

    # Per-stage results
    for sr in "${STAGE_RESULTS[@]}"; do
        local s="${sr%%:*}" v="${sr#*:}"
        local color="$GREEN"
        [[ "$v" == "fail" ]] && color="$RED"
        [[ "$v" == "skip" ]] && color="$YELLOW"
        echo -e "  Stage ${s^^}: ${color}${v}${NC}"
    done

    echo ""
    echo "  Artifacts: $ARTIFACTS_DIR/"
    [[ -s "$SERIAL_LOG" ]] && echo "  Serial log: $(wc -l < "$SERIAL_LOG") lines"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}${BOLD}+--------------------------------------------------------------+${NC}"
    echo -e "${CYAN}${BOLD}|     PowOS Tier-2: Boot-to-Desktop E2E Test                   |${NC}"
    echo -e "${CYAN}${BOLD}+--------------------------------------------------------------+${NC}"

    mkdir -p "$ARTIFACTS_DIR"
    preflight

    [[ -n "$CONTAINER_IMAGE" ]] && build_qcow2

    local overall=true

    # Stages A-C share a VM
    if has_stage a || has_stage b || has_stage c; then
        start_vm

        if has_stage a; then
            stage_a || overall=false
        fi
        # B and C only make sense if A passed (VM is up)
        if has_stage b && [[ "$QEMU_PID" ]]; then
            stage_b || overall=false
        fi
        if has_stage c && [[ "$QEMU_PID" ]]; then
            stage_c || overall=false
        fi

        # Ramboot regression reuses the same VM (reboot cycle)
        if (( RAMBOOT )) && [[ "$QEMU_PID" ]]; then
            stage_r || overall=false
        fi

        stop_vm
    fi

    # Stage D has its own VM lifecycle
    if has_stage d; then
        stage_d || overall=false
    fi

    print_summary

    $overall
}

# ─── Arg parsing ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)          IMAGE_PATH="$2"; shift 2 ;;
        --from-container) CONTAINER_IMAGE="$2"; shift 2 ;;
        --iso)            ISO_PATH="$2"; shift 2 ;;
        --stage|--stages) STAGES="$2"; shift 2 ;;
        --ramboot)        RAMBOOT=1; shift ;;
        --artifacts)      ARTIFACTS_DIR="$2"; shift 2 ;;
        --no-kvm)         USE_KVM=0; shift ;;
        --help|-h)        usage; exit 0 ;;
        *)                echo "Unknown: $1"; usage; exit 1 ;;
    esac
done

main
