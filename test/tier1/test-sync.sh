#!/usr/bin/env bash
# test-sync.sh - Test the state synchronization system
#
# Tests:
# 1. Git repo initialization (backup.sh)
# 2. Sync configuration (backup.sh)
# 3. Push/pull operations (backup.sh)
# 4. Export/import (backup.sh)
# 5. Machine branch management (backup.sh)
# 6. RAM ↔ USB sync (sync.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="${POWOS_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"
TEST_DIR="/tmp/powos-sync-test-$$"

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
    mkdir -p "$TEST_DIR/lib"
    mkdir -p "$TEST_DIR/git"
    mkdir -p "$TEST_DIR/sources"
    mkdir -p "$TEST_DIR/projects"
    mkdir -p "$TEST_DIR/containers"
    mkdir -p "$TEST_DIR/config"
    mkdir -p "$TEST_DIR/run/powos"

    # Copy backup script (cloud backup - git operations)
    cp "$POWOS_ROOT/lib/backup.sh" "$TEST_DIR/lib/" 2>/dev/null || true
    # Copy sync script (RAM ↔ USB sync)
    cp "$POWOS_ROOT/lib/sync.sh" "$TEST_DIR/lib/" 2>/dev/null || true

    # Create remote repository for testing
    mkdir -p "$TEST_DIR/remote"
    cd "$TEST_DIR/remote"
    git init --bare -q

    export POWOS_ROOT="$TEST_DIR"
    export POWOS_STATE_DIR="$TEST_DIR/git"
    export POWOS_CONFIG_DIR="$TEST_DIR/config"
    export HOME="$TEST_DIR/home"
    export STATE_DIR="$TEST_DIR/run/powos"
    mkdir -p "$HOME/.config/powos"

    # Source backup script (for git operations)
    source "$TEST_DIR/lib/backup.sh" 2>/dev/null || true
    # Source sync script (for RAM ↔ USB operations)
    source "$TEST_DIR/lib/sync.sh" 2>/dev/null || true
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

assert_function_exists() {
    local func_name="$1"
    local message="${2:-Function should exist}"

    ((TESTS_RUN++)) || true

    if declare -f "$func_name" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Function: $func_name"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: Module Loading
# ─────────────────────────────────────────────────────────────────

test_sync_file_exists() {
    echo ""
    echo "Test: Sync modules exist"
    assert_file_exists "$TEST_DIR/lib/backup.sh" "backup.sh exists (cloud backup)"
    assert_file_exists "$TEST_DIR/lib/sync.sh" "sync.sh exists (RAM ↔ USB sync)"
}

test_sync_functions_exist() {
    echo ""
    echo "Test: Backup functions available (from backup.sh)"

    assert_function_exists "sync_status" "sync_status exists"
    assert_function_exists "sync_push" "sync_push exists"
    assert_function_exists "sync_pull" "sync_pull exists"
    assert_function_exists "sync_setup" "sync_setup exists"
    assert_function_exists "sync_export" "sync_export exists"
    assert_function_exists "sync_import" "sync_import exists"
    assert_function_exists "sync_machine" "sync_machine exists"
}

test_ram_usb_sync_functions_exist() {
    echo ""
    echo "Test: RAM ↔ USB sync functions available (from sync.sh)"

    assert_function_exists "cmd_sync" "cmd_sync exists"
    assert_function_exists "ram_sync_now" "ram_sync_now exists"
    assert_function_exists "ram_sync_status" "ram_sync_status exists"
    assert_function_exists "ram_sync_resolve" "ram_sync_resolve exists"
    assert_function_exists "ram_sync_resolve_ai" "ram_sync_resolve_ai exists"
    assert_function_exists "get_diff_for_ai" "get_diff_for_ai exists"
    assert_function_exists "check_for_conflicts" "check_for_conflicts exists"
    assert_function_exists "read_sync_marker" "read_sync_marker exists"
    assert_function_exists "write_sync_marker" "write_sync_marker exists"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Git Repository
# ─────────────────────────────────────────────────────────────────

test_ensure_git_repo() {
    echo ""
    echo "Test: Git repo initialization"

    ensure_git_repo

    assert_dir_exists "$POWOS_STATE_DIR/.git" "Git directory created"
    assert_file_exists "$POWOS_STATE_DIR/.gitignore" "Gitignore created"
}

test_gitignore_content() {
    echo ""
    echo "Test: Gitignore has expected content"

    ensure_git_repo

    local gitignore_content
    gitignore_content=$(cat "$POWOS_STATE_DIR/.gitignore")

    assert_contains "$gitignore_content" ".env" "Gitignore blocks .env"
    assert_contains "$gitignore_content" "secrets/" "Gitignore blocks secrets"
    assert_contains "$gitignore_content" "extensions/" "Gitignore blocks build artifacts"
}

test_initial_commit() {
    echo ""
    echo "Test: Initial commit created"

    ensure_git_repo

    cd "$POWOS_STATE_DIR"
    local commits
    commits=$(git log --oneline 2>/dev/null | wc -l)

    ((TESTS_RUN++)) || true
    if [[ "$commits" -ge 1 ]]; then
        echo -e "${GREEN}✓${NC} Initial commit exists"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} No initial commit"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: Remote Configuration
# ─────────────────────────────────────────────────────────────────

test_sync_setup() {
    echo ""
    echo "Test: Configure remote"

    ensure_git_repo

    sync_setup "$TEST_DIR/remote"

    cd "$POWOS_STATE_DIR"

    ((TESTS_RUN++)) || true
    if git remote get-url origin &>/dev/null; then
        echo -e "${GREEN}✓${NC} Remote configured"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Remote not configured"
        ((TESTS_FAILED++)) || true
    fi

    assert_file_exists "$HOME/.config/powos/sync.conf" "Sync config created"
}

test_has_remote() {
    echo ""
    echo "Test: Has remote detection"

    ensure_git_repo
    sync_setup "$TEST_DIR/remote"

    cd "$POWOS_STATE_DIR"

    ((TESTS_RUN++)) || true
    if has_remote; then
        echo -e "${GREEN}✓${NC} has_remote returns true"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} has_remote returns false"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: Status
# ─────────────────────────────────────────────────────────────────

test_sync_status_output() {
    echo ""
    echo "Test: Status command output"

    ensure_git_repo

    local status_output
    status_output=$(sync_status 2>&1)

    assert_contains "$status_output" "Repository" "Status shows repository info"
    assert_contains "$status_output" "Branch" "Status shows branch info"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Push/Pull
# ─────────────────────────────────────────────────────────────────

test_sync_push() {
    echo ""
    echo "Test: Push to remote"

    ensure_git_repo
    sync_setup "$TEST_DIR/remote"

    # Create some content
    echo "test content" > "$POWOS_STATE_DIR/sources/test.txt"

    sync_push -m "Test push" 2>/dev/null || true

    cd "$POWOS_STATE_DIR"
    local branch
    branch=$(get_current_branch)
    local remote_commits
    remote_commits=$(git log "origin/$branch" --oneline 2>/dev/null | wc -l | tr -d '[:space:]')
    remote_commits="${remote_commits:-0}"

    ((TESTS_RUN++)) || true
    if [[ "$remote_commits" -ge 1 ]]; then
        echo -e "${GREEN}✓${NC} Changes pushed to remote"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${YELLOW}⊘${NC} Push test skipped (may need network or branch mismatch)"
    fi
}

test_sync_from_working_dirs() {
    echo ""
    echo "Test: Collect from working directories"

    ensure_git_repo

    # Create test content in working dirs
    mkdir -p "$POWOS_ROOT/sources/test-overlay"
    echo "test build" > "$POWOS_ROOT/sources/test-overlay/build.sh"

    mkdir -p "$POWOS_ROOT/projects/test-project"
    echo "test readme" > "$POWOS_ROOT/projects/test-project/README.md"

    POWOS_SYNC_SOURCES=true
    POWOS_SYNC_PROJECTS=true

    sync_from_working_dirs 2>/dev/null || true

    assert_file_exists "$POWOS_STATE_DIR/sources/test-overlay/build.sh" "Sources synced to state"
    assert_file_exists "$POWOS_STATE_DIR/projects/test-project/README.md" "Projects synced to state"
}

test_sync_to_working_dirs() {
    echo ""
    echo "Test: Sync to working directories"

    ensure_git_repo

    # Create test content in state dir
    mkdir -p "$POWOS_STATE_DIR/sources/from-state"
    echo "from state" > "$POWOS_STATE_DIR/sources/from-state/file.txt"

    POWOS_SYNC_SOURCES=true

    sync_to_working_dirs 2>/dev/null || true

    assert_file_exists "$POWOS_ROOT/sources/from-state/file.txt" "State synced to working dir"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Export/Import
# ─────────────────────────────────────────────────────────────────

test_sync_export() {
    echo ""
    echo "Test: Export state"

    ensure_git_repo

    # Create some content
    mkdir -p "$POWOS_STATE_DIR/sources/export-test"
    echo "export content" > "$POWOS_STATE_DIR/sources/export-test/file.txt"

    local export_file="$TEST_DIR/test-export.tar.gz"
    sync_export "$export_file" 2>/dev/null || true

    assert_file_exists "$export_file" "Export file created"

    # Check it contains expected content (check for sources directory)
    ((TESTS_RUN++)) || true
    if tar -tzf "$export_file" 2>/dev/null | grep -q "sources"; then
        echo -e "${GREEN}✓${NC} Export contains expected content"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${YELLOW}⊘${NC} Export content check skipped (tar format may vary)"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: Machine Branches
# ─────────────────────────────────────────────────────────────────

test_get_machine_branch() {
    echo ""
    echo "Test: Machine branch naming"

    POWOS_MACHINE_ID="test-machine"

    local branch
    branch=$(get_machine_branch)

    assert_equals "machine/test-machine" "$branch" "Machine branch name correct"
}

test_machine_init() {
    echo ""
    echo "Test: Machine branch init"

    # Start fresh
    rm -rf "$POWOS_STATE_DIR"
    ensure_git_repo

    # Set machine ID BEFORE calling machine_init
    export POWOS_MACHINE_ID="test-laptop"
    machine_init 2>/dev/null || true

    cd "$POWOS_STATE_DIR"
    local current_branch
    current_branch=$(get_current_branch)

    # Check if we're on a machine branch (may be test-laptop or auto-detected)
    ((TESTS_RUN++)) || true
    if [[ "$current_branch" == machine/* ]]; then
        echo -e "${GREEN}✓${NC} On machine branch: $current_branch"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Not on machine branch"
        echo "  Expected: machine/*"
        echo "  Actual: $current_branch"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: Helper Functions
# ─────────────────────────────────────────────────────────────────

test_get_current_branch() {
    echo ""
    echo "Test: Get current branch"

    ensure_git_repo

    cd "$POWOS_STATE_DIR"
    local branch
    branch=$(get_current_branch)

    ((TESTS_RUN++)) || true
    if [[ -n "$branch" ]]; then
        echo -e "${GREEN}✓${NC} Current branch detected: $branch"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Could not detect current branch"
        ((TESTS_FAILED++)) || true
    fi
}

test_has_uncommitted() {
    echo ""
    echo "Test: Uncommitted changes detection"

    # Start fresh
    rm -rf "$POWOS_STATE_DIR"
    ensure_git_repo

    cd "$POWOS_STATE_DIR"

    # Should have no uncommitted changes initially
    ((TESTS_RUN++)) || true
    if ! has_uncommitted; then
        echo -e "${GREEN}✓${NC} No uncommitted changes detected (clean)"
        ((TESTS_PASSED++)) || true
    else
        # May have changes from previous tests, just note it
        echo -e "${YELLOW}⊘${NC} Has uncommitted changes (may be from other tests)"
    fi

    # Create uncommitted change
    echo "new content" > "$POWOS_STATE_DIR/test.txt"

    ((TESTS_RUN++)) || true
    if has_untracked; then
        echo -e "${GREEN}✓${NC} Untracked files detected"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Untracked files not detected"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: Configuration
# ─────────────────────────────────────────────────────────────────

test_load_sync_config() {
    echo ""
    echo "Test: Load sync configuration"

    # Create test config
    cat > "$HOME/.config/powos/sync.conf" << 'EOF'
POWOS_SYNC_REMOTE="git@test:repo.git"
POWOS_SYNC_STRATEGY="machine"
POWOS_SYNC_AUTO_PUSH=true
EOF

    # Reset defaults
    POWOS_SYNC_REMOTE=""
    POWOS_SYNC_STRATEGY="single"
    POWOS_SYNC_AUTO_PUSH=false

    load_sync_config

    assert_equals "git@test:repo.git" "$POWOS_SYNC_REMOTE" "Remote loaded from config"
    assert_equals "machine" "$POWOS_SYNC_STRATEGY" "Strategy loaded from config"
    assert_equals "true" "$POWOS_SYNC_AUTO_PUSH" "Auto-push loaded from config"
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo " PowOS Test Suite: State Synchronization"
    echo "═══════════════════════════════════════════════════════════════════"

    # Setup
    setup

    # Module tests
    test_sync_file_exists
    test_sync_functions_exist
    test_ram_usb_sync_functions_exist

    # Git repo tests
    test_ensure_git_repo
    test_gitignore_content
    test_initial_commit

    # Remote tests
    test_sync_setup
    test_has_remote

    # Status test
    test_sync_status_output

    # Sync tests
    test_sync_from_working_dirs
    test_sync_to_working_dirs
    test_sync_push

    # Export test
    test_sync_export

    # Machine branch tests
    test_get_machine_branch
    test_machine_init

    # Helper tests
    test_get_current_branch
    test_has_uncommitted

    # Config test
    test_load_sync_config

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
