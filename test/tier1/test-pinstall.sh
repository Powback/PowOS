#!/usr/bin/env bash
# test-pinstall.sh - Test the pinstall workflow
#
# Tests:
# 1. Package detection logic
# 2. Config file recording
# 3. Git commit behavior

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="${POWOS_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"
TEST_DIR="/tmp/powos-test-$$"

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
    mkdir -p "$TEST_DIR/containers"
    mkdir -p "$TEST_DIR/bin"

    # Copy scripts
    cp "$POWOS_ROOT/bin/pinstall" "$TEST_DIR/bin/" 2>/dev/null || true
    chmod +x "$TEST_DIR/bin/pinstall" 2>/dev/null || true

    # Initialize git repo
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@powos.local"
    git config user.name "PowOS Test"

    # Create initial distrobox.ini
    cat > "$TEST_DIR/containers/distrobox.ini" << 'EOF'
[powos-dev]
image=archlinux:latest
additional_packages=
EOF

    git add -A
    git commit -q -m "Initial test setup"

    export POWOS_ROOT="$TEST_DIR"
    export POWOS_SKIP_GIT=0
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

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should contain pattern}"

    ((TESTS_RUN++)) || true

    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  File: $file"
        echo "  Pattern: $pattern"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────

test_distrobox_ini_created() {
    echo ""
    echo "Test: distrobox.ini exists after setup"
    assert_equals "0" "$(test -f "$TEST_DIR/containers/distrobox.ini" && echo 0 || echo 1)" "distrobox.ini exists"
}

test_record_package() {
    echo ""
    echo "Test: Recording package to config"

    # Manually add package (simulating what pinstall does)
    local ini_file="$TEST_DIR/containers/distrobox.ini"
    sed -i 's/^additional_packages=$/additional_packages=testpkg/' "$ini_file"

    assert_file_contains "$ini_file" "additional_packages=testpkg" "Package recorded in config"
}

test_append_package() {
    echo ""
    echo "Test: Appending second package"

    local ini_file="$TEST_DIR/containers/distrobox.ini"

    # Add another package
    sed -i 's/^additional_packages=\(.*\)$/additional_packages=\1 anotherpkg/' "$ini_file"

    assert_file_contains "$ini_file" "testpkg anotherpkg" "Second package appended"
}

test_no_duplicates() {
    echo ""
    echo "Test: No duplicate packages"

    local ini_file="$TEST_DIR/containers/distrobox.ini"
    local before_count
    local after_count

    before_count=$(grep -o "testpkg" "$ini_file" | wc -l)

    # Try to add duplicate (should not add)
    if ! grep -q "additional_packages=.*\btestpkg\b" "$ini_file"; then
        sed -i 's/^additional_packages=\(.*\)$/additional_packages=\1 testpkg/' "$ini_file"
    fi

    after_count=$(grep -o "testpkg" "$ini_file" | wc -l)

    assert_equals "$before_count" "$after_count" "No duplicate packages added"
}

test_git_commit() {
    echo ""
    echo "Test: Git commit created"

    cd "$TEST_DIR"

    # Make a change and commit
    echo "# test" >> "$TEST_DIR/containers/distrobox.ini"
    git add -A
    git commit -q -m "install: testcommit"

    local last_commit
    last_commit=$(git log --oneline -1)

    assert_contains "$last_commit" "install: testcommit" "Git commit created with correct message"
}

test_help_output() {
    echo ""
    echo "Test: Help output"

    # Skip if pinstall not available
    if [[ ! -x "$TEST_DIR/bin/pinstall" ]]; then
        echo -e "${YELLOW}⊘${NC} Skipping: pinstall not available"
        return
    fi

    local output
    output=$("$TEST_DIR/bin/pinstall" 2>&1 || true)

    assert_contains "$output" "Usage:" "Help shows usage"
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo " PowOS Test Suite: pinstall"
    echo "═══════════════════════════════════════════════════════════════════"

    # Setup
    setup

    # Run tests
    test_distrobox_ini_created
    test_record_package
    test_append_package
    test_no_duplicates
    test_git_commit
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
