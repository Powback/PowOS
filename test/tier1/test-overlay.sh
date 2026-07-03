#!/usr/bin/env bash
# test-overlay.sh - Test the overlay management system
#
# Tests:
# 1. Overlay building
# 2. Enable/disable overlays
# 3. Extension structure creation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="${POWOS_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"
TEST_DIR="/tmp/powos-overlay-test-$$"

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

setup() {
    echo "Setting up test environment..."

    mkdir -p "$TEST_DIR/sources/hello-test"
    mkdir -p "$TEST_DIR/extensions"
    mkdir -p "$TEST_DIR/lib"

    # Copy overlay manager
    cp "$POWOS_ROOT/lib/overlay-manager.sh" "$TEST_DIR/lib/"

    # Create a test build script
    cat > "$TEST_DIR/sources/hello-test/build.sh" << 'EOF'
#!/usr/bin/env bash
OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR/usr/bin"
cat > "$OUTPUT_DIR/usr/bin/hello-test" << 'SCRIPT'
#!/bin/bash
echo "Hello from PowOS overlay!"
SCRIPT
chmod +x "$OUTPUT_DIR/usr/bin/hello-test"
echo "Built hello-test"
EOF

    export POWOS_ROOT="$TEST_DIR"
    export POWOS_DEV=1
}

teardown() {
    echo "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"

    ((TESTS_RUN++)) || true

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        ((TESTS_FAILED++)) || true
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"

    ((TESTS_RUN++)) || true

    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  File: $file"
        ((TESTS_FAILED++)) || true
    fi
}

assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory should exist}"

    ((TESTS_RUN++)) || true

    if [[ -d "$dir" ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Directory: $dir"
        ((TESTS_FAILED++)) || true
    fi
}

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
        ((TESTS_FAILED++)) || true
    fi
}

run_overlay() {
    bash "$TEST_DIR/lib/overlay-manager.sh" "$@" 2>&1
}

# ─────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────

test_source_exists() {
    echo ""
    echo "Test: Source directory exists"
    assert_dir_exists "$TEST_DIR/sources/hello-test" "Source directory created"
    assert_file_exists "$TEST_DIR/sources/hello-test/build.sh" "Build script exists"
}

test_build_overlay() {
    echo ""
    echo "Test: Build overlay"

    local output
    output=$(run_overlay build hello-test)

    assert_contains "$output" "Building overlay: hello-test" "Shows building message"
    assert_contains "$output" "Built overlay" "Shows completion message"
}

test_extension_structure() {
    echo ""
    echo "Test: Extension structure created"

    # Build first
    run_overlay build hello-test >/dev/null

    assert_dir_exists "$TEST_DIR/extensions/hello-test" "Extension directory created"
    assert_dir_exists "$TEST_DIR/extensions/hello-test/usr/bin" "usr/bin directory created"
    assert_file_exists "$TEST_DIR/extensions/hello-test/usr/bin/hello-test" "Binary created"
}

test_extension_release() {
    echo ""
    echo "Test: Extension release file created"

    # Build first
    run_overlay build hello-test >/dev/null

    local release_file="$TEST_DIR/extensions/hello-test/usr/lib/extension-release.d/extension-release.hello-test"
    assert_file_exists "$release_file" "Extension release file exists"
}

test_enable_overlay_dev_mode() {
    echo ""
    echo "Test: Enable overlay (dev mode)"

    # Build first
    run_overlay build hello-test >/dev/null

    local output
    output=$(run_overlay enable hello-test)

    assert_contains "$output" "(DEV)" "Shows dev mode indicator"
    assert_contains "$output" "Enabled" "Shows enabled message"
}

test_disable_overlay_dev_mode() {
    echo ""
    echo "Test: Disable overlay (dev mode)"

    local output
    output=$(run_overlay disable hello-test)

    assert_contains "$output" "(DEV)" "Shows dev mode indicator"
    assert_contains "$output" "Disabled" "Shows disabled message"
}

test_list_overlays() {
    echo ""
    echo "Test: List overlays"

    # Build first
    run_overlay build hello-test >/dev/null

    local output
    output=$(run_overlay list)

    assert_contains "$output" "hello-test" "Lists hello-test overlay"
    assert_contains "$output" "Sources" "Shows sources section"
    assert_contains "$output" "Built Extensions" "Shows extensions section"
}

test_clean_overlay() {
    echo ""
    echo "Test: Clean overlay"

    # Build first
    run_overlay build hello-test >/dev/null
    assert_dir_exists "$TEST_DIR/extensions/hello-test" "Extension exists before clean"

    # Clean
    run_overlay clean hello-test >/dev/null

    ((TESTS_RUN++)) || true
    if [[ ! -d "$TEST_DIR/extensions/hello-test" ]]; then
        echo -e "${GREEN}✓${NC} Extension removed after clean"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Extension should be removed after clean"
        ((TESTS_FAILED++)) || true
    fi
}

test_build_nonexistent() {
    echo ""
    echo "Test: Build nonexistent overlay"

    local output
    output=$(run_overlay build nonexistent 2>&1 || true)

    assert_contains "$output" "not found" "Shows error for missing source"
}

test_help_output() {
    echo ""
    echo "Test: Help output"

    local output
    output=$(run_overlay help)

    assert_contains "$output" "Usage:" "Shows usage"
    assert_contains "$output" "build" "Lists build command"
    assert_contains "$output" "enable" "Lists enable command"
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo " PowOS Test Suite: overlay-manager"
    echo "═══════════════════════════════════════════════════════════════════"

    # Setup
    setup

    # Run tests
    test_source_exists
    test_build_overlay
    test_extension_structure
    test_extension_release
    test_enable_overlay_dev_mode
    test_disable_overlay_dev_mode
    test_list_overlays
    test_clean_overlay
    test_build_nonexistent
    test_help_output

    # Teardown
    teardown

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
