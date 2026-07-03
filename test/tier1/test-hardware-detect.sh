#!/usr/bin/env bash
# test-hardware-detect.sh - Test the hardware detection system
#
# Tests:
# 1. Mock hardware detection
# 2. Profile selection logic
# 3. Different hardware scenarios

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="${POWOS_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ─────────────────────────────────────────────────────────────────
# Test Helpers
# ─────────────────────────────────────────────────────────────────

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Assertion failed}"

    ((TESTS_RUN++)) || true

    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to contain: $needle"
        echo "  Actual: $haystack"
        ((TESTS_FAILED++)) || true
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Assertion failed}"

    ((TESTS_RUN++)) || true

    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to contain: $needle"
        echo "  Actual: $haystack"
        ((TESTS_FAILED++)) || true
    fi
}

run_detect() {
    local mock_hw="${1:-}"
    local mock_power="${2:-ac}"
    local mock_virt="${3:-physical}"

    POWOS_DEV=1 \
    POWOS_MOCK_HARDWARE="$mock_hw" \
    POWOS_MOCK_POWER="$mock_power" \
    POWOS_MOCK_VIRT="$mock_virt" \
    POWOS_PROFILES_DIR="$POWOS_ROOT/config/profiles" \
    bash "$POWOS_ROOT/lib/hardware-detect.sh" detect 2>&1
}

# ─────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────

test_nvidia_desktop_detection() {
    echo ""
    echo "Test: Nvidia desktop detection"

    local output
    output=$(run_detect "nvidia-desktop" "ac" "physical")

    assert_contains "$output" "GPU: nvidia-desktop" "Detects nvidia-desktop GPU"
    assert_contains "$output" "desktop-performance" "Applies desktop-performance profile"
}

test_nvidia_mobile_battery() {
    echo ""
    echo "Test: Nvidia mobile on battery"

    local output
    output=$(run_detect "nvidia-mobile" "battery" "physical")

    assert_contains "$output" "GPU: nvidia-mobile" "Detects nvidia-mobile GPU"
    assert_contains "$output" "Power: battery" "Detects battery power"
    assert_contains "$output" "laptop-battery" "Applies laptop-battery profile"
}

test_nvidia_mobile_ac() {
    echo ""
    echo "Test: Nvidia mobile on AC power"

    local output
    output=$(run_detect "nvidia-mobile" "ac" "physical")

    assert_contains "$output" "GPU: nvidia-mobile" "Detects nvidia-mobile GPU"
    assert_contains "$output" "Power: ac" "Detects AC power"
    assert_contains "$output" "desktop-performance" "Applies desktop-performance profile"
}

test_intel_detection() {
    echo ""
    echo "Test: Intel GPU detection"

    local output
    output=$(run_detect "intel" "battery" "physical")

    assert_contains "$output" "GPU: intel" "Detects Intel GPU"
    assert_contains "$output" "laptop-battery" "Applies laptop-battery profile"
}

test_amd_detection() {
    echo ""
    echo "Test: AMD GPU detection"

    local output
    output=$(run_detect "amd" "ac" "physical")

    assert_contains "$output" "GPU: amd" "Detects AMD GPU"
}

test_unknown_hardware() {
    echo ""
    echo "Test: Unknown hardware fallback"

    local output
    output=$(run_detect "unknown" "ac" "physical")

    assert_contains "$output" "GPU: unknown" "Reports unknown GPU"
    assert_contains "$output" "Unknown GPU type" "Shows warning for unknown GPU"
}

test_status_command() {
    echo ""
    echo "Test: Status command"

    local output
    output=$(POWOS_MOCK_HARDWARE="nvidia-desktop" bash "$POWOS_ROOT/lib/hardware-detect.sh" status 2>&1)

    assert_contains "$output" "Current hardware status" "Shows status header"
    assert_contains "$output" "GPU:" "Shows GPU info"
}

test_help_command() {
    echo ""
    echo "Test: Help command"

    local output
    output=$(bash "$POWOS_ROOT/lib/hardware-detect.sh" help 2>&1)

    assert_contains "$output" "Usage:" "Shows usage"
    assert_contains "$output" "detect" "Lists detect command"
    assert_contains "$output" "status" "Lists status command"
}

test_dev_mode_no_changes() {
    echo ""
    echo "Test: Dev mode makes no real changes"

    local output
    output=$(run_detect "nvidia-desktop" "ac")

    assert_contains "$output" "(DEV)" "Shows dev mode indicator"
    assert_contains "$output" "Would load" "Shows simulated action"
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo " PowOS Test Suite: hardware-detect"
    echo "═══════════════════════════════════════════════════════════════════"

    # Check if hardware-detect.sh exists
    if [[ ! -f "$POWOS_ROOT/lib/hardware-detect.sh" ]]; then
        echo -e "${RED}Error: hardware-detect.sh not found${NC}"
        exit 1
    fi

    # Run tests
    test_nvidia_desktop_detection
    test_nvidia_mobile_battery
    test_nvidia_mobile_ac
    test_intel_detection
    test_amd_detection
    test_unknown_hardware
    test_status_command
    test_help_command
    test_dev_mode_no_changes

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo " Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
    echo "═══════════════════════════════════════════════════════════════════"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
