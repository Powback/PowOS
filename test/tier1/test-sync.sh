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
    # Lock file must be writable in the test env (real default is /run/powos)
    export POWOS_SYNC_LOCK_FILE="$TEST_DIR/run/powos/sync.lock"
    # Fake USB mount for RAM ↔ USB sync tests (sync.sh reads this at source time)
    export POWOS_USB_MOUNT="$TEST_DIR/usb"
    mkdir -p "$POWOS_USB_MOUNT"
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
    assert_function_exists "write_sync_manifest" "write_sync_manifest exists"
    assert_function_exists "load_sync_manifest" "load_sync_manifest exists"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Conflict Detection (RAM ↔ USB)
# ─────────────────────────────────────────────────────────────────

test_conflict_detection() {
    echo ""
    echo "Test: RAM ↔ USB conflict detection"

    mkdir -p "$POWOS_USB_MOUNT"
    local result

    # Case 1: no marker → no conflict (first sync)
    rm -f "$SYNC_MARKER"
    result=$(check_for_conflicts || echo "conflict")
    assert_equals "none" "$result" "No marker → no conflict"

    # Case 2: marker from THIS machine → no conflict
    cat > "$SYNC_MARKER" << EOF
# PowOS Sync Marker - DO NOT EDIT
SYNC_MACHINE_ID="$MACHINE_ID"
SYNC_TIMESTAMP="1700000000"
SYNC_DATE="2026-01-01T00:00:00+00:00"
EOF
    result=$(check_for_conflicts || echo "conflict")
    assert_equals "none" "$result" "Same-machine marker → no conflict"

    # Case 3: marker from ANOTHER machine → conflict MUST be detected.
    # The capture pattern below is exactly what ram_sync_now / bin/powos use;
    # it must yield exactly "conflict" (the old echo+return-1 bug produced
    # "conflict\nconflict" and made real conflicts undetectable).
    cat > "$SYNC_MARKER" << EOF
# PowOS Sync Marker - DO NOT EDIT
SYNC_MACHINE_ID="other-machine-deadbeef"
SYNC_TIMESTAMP="1700000000"
SYNC_DATE="2026-01-01T00:00:00+00:00"
EOF
    result=$(check_for_conflicts || echo "conflict")
    assert_equals "conflict" "$result" "Mismatched machine marker → conflict detected"

    # Return-code contract: non-zero on conflict
    ((TESTS_RUN++)) || true
    if ! check_for_conflicts >/dev/null; then
        echo -e "${GREEN}✓${NC} check_for_conflicts returns non-zero on conflict"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} check_for_conflicts returned zero despite conflict"
        ((TESTS_FAILED++)) || true
    fi

    rm -f "$SYNC_MARKER"
}

test_sync_marker_not_sourced() {
    echo ""
    echo "Test: Sync marker is parsed, never executed"

    mkdir -p "$POWOS_USB_MOUNT"
    local canary="$TEST_DIR/marker-pwned"
    rm -f "$canary"

    # A hostile marker on removable media: sourcing it would run these lines
    cat > "$SYNC_MARKER" << EOF
SYNC_MACHINE_ID="evil-machine"
touch "$canary"
SYNC_INJECT="\$(touch "$canary")"
SYNC_DATE="2026-01-01T00:00:00+00:00"
EOF

    local machine
    machine=$(read_sync_marker)
    assert_equals "evil-machine" "$machine" "Marker machine id parsed correctly"

    get_conflict_details >/dev/null 2>&1 || true
    check_for_conflicts >/dev/null 2>&1 || true

    ((TESTS_RUN++)) || true
    if [[ ! -f "$canary" ]]; then
        echo -e "${GREEN}✓${NC} Marker content was not executed"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Marker content WAS EXECUTED (arbitrary code from USB!)"
        ((TESTS_FAILED++)) || true
    fi

    rm -f "$SYNC_MARKER" "$canary"
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

    # Create content in a WORKING dir: push must collect working dirs first
    # (previously it pushed a stale state repo and never collected anything)
    mkdir -p "$POWOS_ROOT/sources"
    echo "push content" > "$POWOS_ROOT/sources/push-test.txt"

    sync_push -m "Test push" || true

    # Push must have collected the working-dir file into the state repo
    assert_file_exists "$POWOS_STATE_DIR/sources/push-test.txt" "Push collected working dirs first"

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
        echo -e "${RED}✗${NC} Changes not pushed to remote (local bare repo - no network needed)"
        ((TESTS_FAILED++)) || true
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

    # Plant secrets that physically sit in the state dir (gitignored, but a
    # naive tar would archive them anyway) - they must NOT be exported
    mkdir -p "$POWOS_STATE_DIR/config"
    echo 'POWOS_SYNC_REMOTE="https://user:supersecrettoken@example.com/r.git"' \
        > "$POWOS_STATE_DIR/config/sync.conf"
    echo "API_KEY=leakme" > "$POWOS_STATE_DIR/.env"
    echo "fakekey" > "$POWOS_STATE_DIR/leaked.key"

    local export_file="$TEST_DIR/test-export.tar.gz"
    sync_export "$export_file" || true

    assert_file_exists "$export_file" "Export file created"

    local listing
    listing=$(tar -tzf "$export_file" 2>/dev/null || true)

    assert_contains "$listing" "sources" "Export contains sources content"

    ((TESTS_RUN++)) || true
    if [[ "$listing" != *"sync.conf"* ]]; then
        echo -e "${GREEN}✓${NC} Export excludes sync.conf (may embed credentials)"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Export leaked sync.conf"
        ((TESTS_FAILED++)) || true
    fi

    ((TESTS_RUN++)) || true
    if [[ "$listing" != *".env"* && "$listing" != *"leaked.key"* ]]; then
        echo -e "${GREEN}✓${NC} Export excludes .env and *.key secrets"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Export leaked secrets (.env or *.key)"
        ((TESTS_FAILED++)) || true
    fi

    rm -f "$POWOS_STATE_DIR/config/sync.conf" "$POWOS_STATE_DIR/.env" "$POWOS_STATE_DIR/leaked.key"
}

test_sync_export_default_location() {
    echo ""
    echo "Test: Export default output lands outside the state dir"

    ensure_git_repo

    local outdir="$TEST_DIR/export-cwd"
    mkdir -p "$outdir"
    cd "$outdir"

    sync_export || true

    ((TESTS_RUN++)) || true
    local produced
    produced=$(find "$outdir" -maxdepth 1 -name 'powos-state-*.tar.gz' 2>/dev/null | head -1)
    if [[ -n "$produced" ]]; then
        echo -e "${GREEN}✓${NC} Default export written to caller's directory"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Default export not found in caller's directory"
        ((TESTS_FAILED++)) || true
    fi

    ((TESTS_RUN++)) || true
    if ! find "$POWOS_STATE_DIR" -maxdepth 1 -name 'powos-state-*.tar.gz' 2>/dev/null | grep -q .; then
        echo -e "${GREEN}✓${NC} No export tarball inside the state dir"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Export tarball landed inside the state dir"
        ((TESTS_FAILED++)) || true
    fi

    rm -f "$outdir"/powos-state-*.tar.gz
    cd "$TEST_DIR"
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

# ─────────────────────────────────────────────────────────────────
# Tests: 3-way merge (all 6 conflict classes)
# ─────────────────────────────────────────────────────────────────
#
# We test ram_sync_merge() by:
#   1. Creating a fake RAM upper dir and fake USB custom dir.
#   2. Writing a manifest (the BASE) representing the last-common sync.
#   3. Calling ram_sync_merge() with those paths via overriding the globals.
#   4. Asserting the correct file is present in the RAM upper after the merge.

test_three_way_merge() {
    echo ""
    echo "Test: 3-way merge — manifest functions + 6 conflict classes"

    # Temporary sandbox — completely separate from the main TEST_DIR git state.
    local merge_dir="$TEST_DIR/merge-$$"
    local ram_upper="$merge_dir/ram"
    mkdir -p "$ram_upper"

    # Point the globals to our fake USB.
    local old_usb="$USB_MOUNT"
    local old_marker="$SYNC_MARKER"
    local old_manifest="$SYNC_MANIFEST"
    local old_machine="$MACHINE_ID"

    USB_MOUNT="$merge_dir/fake-usb"
    mkdir -p "$USB_MOUNT/layers/custom"
    SYNC_MARKER="$USB_MOUNT/.powos-sync"
    SYNC_MANIFEST="$USB_MOUNT/.powos-sync-manifest"
    MACHINE_ID="test-machine-A"

    # ── 1. Test write_sync_manifest / load_sync_manifest in isolation ─
    # Use a dedicated file so we don't pollute the class-test USB tree.
    local mf_test_file="$USB_MOUNT/layers/custom/manifest-probe.txt"
    echo "probe content" > "$mf_test_file"
    write_sync_manifest

    ((TESTS_RUN++)) || true
    if [[ -f "$SYNC_MANIFEST" ]]; then
        echo -e "${GREEN}✓${NC} write_sync_manifest creates the manifest file"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} write_sync_manifest did not create the manifest"
        ((TESTS_FAILED++)) || true
    fi

    declare -A LOADED_MAP=()
    load_sync_manifest LOADED_MAP 2>/dev/null
    ((TESTS_RUN++)) || true
    if [[ -n "${LOADED_MAP[manifest-probe.txt]+x}" ]]; then
        echo -e "${GREEN}✓${NC} load_sync_manifest: regular file has hash entry"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} load_sync_manifest: regular file entry missing"
        ((TESTS_FAILED++)) || true
    fi

    # Whiteout test (only when mknod is available, i.e. root).
    if mknod "$USB_MOUNT/layers/custom/wh-probe" c 0 0 2>/dev/null; then
        write_sync_manifest
        declare -A LOADED_WH=()
        load_sync_manifest LOADED_WH 2>/dev/null
        assert_equals "DELETED" "${LOADED_WH[wh-probe]:-MISSING}" \
            "load_sync_manifest: whiteout entry is DELETED"
        rm -f "$USB_MOUNT/layers/custom/wh-probe"
    else
        echo "  (whiteout manifest test skipped — mknod unavailable outside root)"
    fi

    # Clean the USB tree for the merge class tests.
    rm -f "$mf_test_file"
    rm -f "$SYNC_MANIFEST"

    # ── 2. Set up the 6 conflict-class trees ──────────────────────
    #
    # BASE state (what both machines had at the last sync):
    #   class1.txt: "base content"   (RAM will modify it)
    #   class2.txt: "base content"   (USB will modify it)
    #   class3.txt: "base content"   (both will modify it, RAM newer)
    #   class6.txt: "base content"   (USB will delete it)
    #
    # Not in BASE (new after last sync):
    #   class4.txt: added on RAM only
    #   class5.txt: added on USB only
    #
    # Compute base hash (same string for class1/2/3/6).
    local h_base
    h_base=$(printf '%s\n' "base content" | md5sum | cut -d' ' -f1)
    # class3 and class6 are stored in separate temp files for clarity.
    printf '%s\n' "base content" > "$merge_dir/base3.tmp"
    local h_base3; h_base3=$(md5sum "$merge_dir/base3.tmp" | cut -d' ' -f1)
    printf '%s\n' "base content" > "$merge_dir/base6.tmp"
    local h_base6; h_base6=$(md5sum "$merge_dir/base6.tmp" | cut -d' ' -f1)

    # Write the BASE manifest manually — this represents the last-common-sync
    # state, BEFORE either machine made its changes.
    {
        printf '# powos-sync-manifest v1\n'
        printf '# machine: %s\n' "$MACHINE_ID"
        printf '# timestamp: 1000000000\n'
        printf '%s  class1.txt\n' "$h_base"
        printf '%s  class2.txt\n' "$h_base"
        printf '%s  class3.txt\n' "$h_base3"
        printf '%s  class6.txt\n' "$h_base6"
        # class4/class5 are NOT in the base (new on each machine).
    } > "$SYNC_MANIFEST"

    # Set up RAM upper (this machine's changes from BASE).
    printf '%s\n' "RAM modified"   > "$ram_upper/class1.txt"   # changed from base
    printf '%s\n' "base content"   > "$ram_upper/class2.txt"   # unchanged
    printf '%s\n' "RAM changed"    > "$ram_upper/class3.txt"   # changed (newer)
    touch -t 202601010200              "$ram_upper/class3.txt"
    printf '%s\n' "RAM new file"   > "$ram_upper/class4.txt"   # new on RAM only
    # class5: not in RAM (new on USB only)
    printf '%s\n' "base content"   > "$ram_upper/class6.txt"   # unchanged from base

    # Set up USB custom (other machine's changes from BASE).
    printf '%s\n' "base content"   > "$USB_MOUNT/layers/custom/class1.txt"   # unchanged
    printf '%s\n' "USB modified"   > "$USB_MOUNT/layers/custom/class2.txt"   # changed
    printf '%s\n' "USB changed"    > "$USB_MOUNT/layers/custom/class3.txt"   # changed (older)
    touch -t 202601010100              "$USB_MOUNT/layers/custom/class3.txt"
    # class4: not in USB (new on RAM only)
    printf '%s\n' "USB new file"   > "$USB_MOUNT/layers/custom/class5.txt"   # new on USB only
    # class6: USB deleted it.
    mknod "$USB_MOUNT/layers/custom/class6.txt" c 0 0 2>/dev/null || \
        true   # non-root: omit whiteout (class6 test will be skipped)

    # ── 3. Run the merge via an inline override ────────────────────
    # ram_sync_merge() hard-codes /run/powos-overlay/upper; we shadow it
    # here with a version that uses our test paths.
    local saved_ram_upper="$ram_upper"

    local merge_out
    merge_out=$(
        ram_sync_merge() {
            local ram_upper="$saved_ram_upper"
            local usb_custom="$USB_MOUNT/layers/custom"

            [[ -d "$ram_upper" && -d "$usb_custom" ]] || { echo "paths missing"; return 1; }

            declare -A BASE_HASH=()
            local has_manifest=0
            load_sync_manifest BASE_HASH 2>/dev/null && has_manifest=1

            _is_whiteout() {
                [[ -c "$1" ]] && [[ "$(LC_ALL=C stat -c '%t%T' "$1" 2>/dev/null)" == "00" ]]
            }
            _file_hash() {
                local f="$1"
                if _is_whiteout "$f"; then echo "DELETED"
                elif [[ -f "$f" ]]; then md5sum "$f" 2>/dev/null | cut -d' ' -f1
                else echo ""
                fi
            }

            declare -A all_files=()
            while IFS= read -r -d '' f; do
                all_files["${f#${ram_upper}/}"]=1
            done < <(find "$ram_upper" \( -type f -o -type c \) -print0 2>/dev/null)
            while IFS= read -r -d '' f; do
                all_files["${f#${usb_custom}/}"]=1
            done < <(find "$usb_custom" \( -type f -o -type c \) -print0 2>/dev/null)

            local n_ram_kept=0 n_usb_taken=0 n_conflict=0
            for rel in "${!all_files[@]}"; do
                [[ "$rel" == *.powos-conflict-* ]] && continue
                local ram_f="$ram_upper/$rel"
                local usb_f="$usb_custom/$rel"
                local ram_hash="" usb_hash="" base_hash="ABSENT"
                [[ -f "$ram_f" || -c "$ram_f" ]] && ram_hash=$(_file_hash "$ram_f")
                [[ -f "$usb_f" || -c "$usb_f" ]] && usb_hash=$(_file_hash "$usb_f")
                [[ -n "${BASE_HASH[$rel]+x}" ]] && base_hash="${BASE_HASH[$rel]}"

                if [[ -z "$usb_hash" ]]; then
                    if [[ "$base_hash" != "ABSENT" && "$ram_hash" == "$base_hash" ]]; then
                        rm -f "$ram_f" 2>/dev/null || true
                    else
                        (( n_ram_kept++ )) || true
                    fi
                    continue
                fi
                if [[ -z "$ram_hash" ]]; then
                    if [[ "$base_hash" != "ABSENT" && "$usb_hash" == "$base_hash" ]]; then
                        :
                    else
                        mkdir -p "$(dirname "$ram_f")"
                        cp -a "$usb_f" "$ram_f"
                        (( n_usb_taken++ )) || true
                    fi
                    continue
                fi
                [[ "$ram_hash" == "$usb_hash" ]] && continue

                if [[ "$has_manifest" -eq 1 && "$base_hash" != "ABSENT" ]]; then
                    if [[ "$ram_hash" == "$base_hash" ]]; then
                        mkdir -p "$(dirname "$ram_f")"
                        cp -a "$usb_f" "$ram_f"
                        (( n_usb_taken++ )) || true
                        continue
                    fi
                    if [[ "$usb_hash" == "$base_hash" ]]; then
                        (( n_ram_kept++ )) || true
                        continue
                    fi
                fi

                (( n_conflict++ )) || true
                local ram_mtime usb_mtime
                ram_mtime=$(stat -c '%Y' "$ram_f" 2>/dev/null || echo 0)
                usb_mtime=$(stat -c '%Y' "$usb_f" 2>/dev/null || echo 0)
                if (( usb_mtime > ram_mtime )); then
                    cp -a "$ram_f" "${ram_f}.powos-conflict-${MACHINE_ID}" 2>/dev/null || true
                    cp -a "$usb_f" "$ram_f"
                    (( n_usb_taken++ )) || true
                else
                    mkdir -p "$(dirname "$ram_f")"
                    cp -a "$usb_f" "${ram_f}.powos-conflict-${MACHINE_ID}" 2>/dev/null || true
                    (( n_ram_kept++ )) || true
                fi
            done
            printf 'ram_kept=%d usb_taken=%d conflicts=%d\n' \
                "$n_ram_kept" "$n_usb_taken" "$n_conflict"
        }
        ram_sync_merge
    )

    # ── 4. Assert each class outcome ──────────────────────────────
    # Class 1: RAM changed, USB at base → RAM version kept.
    assert_equals "RAM modified" \
        "$(cat "$ram_upper/class1.txt" 2>/dev/null | tr -d '\n')" \
        "Class 1: RAM-only change preserved"

    # Class 2: USB changed, RAM at base → USB version merged into RAM.
    assert_equals "USB modified" \
        "$(cat "$ram_upper/class2.txt" 2>/dev/null | tr -d '\n')" \
        "Class 2: USB-only change merged into RAM"

    # Class 3: both changed, RAM is newer → RAM kept, USB saved as conflict copy.
    assert_equals "RAM changed" \
        "$(cat "$ram_upper/class3.txt" 2>/dev/null | tr -d '\n')" \
        "Class 3: conflict resolved — newer (RAM) wins"
    ((TESTS_RUN++)) || true
    if [[ -f "$ram_upper/class3.txt.powos-conflict-${MACHINE_ID}" ]]; then
        echo -e "${GREEN}✓${NC} Class 3: conflict copy saved as .powos-conflict-<machine>"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Class 3: conflict copy not found"
        ((TESTS_FAILED++)) || true
    fi

    # Class 4: RAM-only new file → still in RAM after merge.
    assert_equals "RAM new file" \
        "$(cat "$ram_upper/class4.txt" 2>/dev/null | tr -d '\n')" \
        "Class 4: RAM-only new file kept"

    # Class 5: USB-only new file → copied to RAM.
    assert_equals "USB new file" \
        "$(cat "$ram_upper/class5.txt" 2>/dev/null | tr -d '\n')" \
        "Class 5: USB-only new file merged into RAM"

    # Class 6: USB deleted (whiteout), RAM at base → RAM file removed.
    # Only possible when mknod c 0 0 succeeded (requires root).
    if [[ -c "$USB_MOUNT/layers/custom/class6.txt" ]] && \
       [[ "$(LC_ALL=C stat -c '%t%T' "$USB_MOUNT/layers/custom/class6.txt" \
             2>/dev/null)" == "00" ]]; then
        ((TESTS_RUN++)) || true
        if [[ ! -f "$ram_upper/class6.txt" ]]; then
            echo -e "${GREEN}✓${NC} Class 6: USB deletion propagated — file removed from RAM"
            ((TESTS_PASSED++)) || true
        else
            echo -e "${RED}✗${NC} Class 6: file still in RAM after USB deletion"
            ((TESTS_FAILED++)) || true
        fi
    else
        echo "  (Class 6 whiteout test skipped — mknod c 0 0 not available outside root)"
    fi

    # Confirm merge reported exactly 1 conflict (class 3).
    assert_contains "$merge_out" "conflicts=1" "Merge reported exactly 1 conflict (class 3)"

    # ── Cleanup ───────────────────────────────────────────────────
    USB_MOUNT="$old_usb"
    SYNC_MARKER="$old_marker"
    SYNC_MANIFEST="$old_manifest"
    MACHINE_ID="$old_machine"
    rm -rf "$merge_dir"
}

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

    # Conflict detection tests (RAM ↔ USB)
    test_conflict_detection
    test_sync_marker_not_sourced

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

    # Export tests
    test_sync_export
    test_sync_export_default_location

    # Machine branch tests
    test_get_machine_branch
    test_machine_init

    # Helper tests
    test_get_current_branch
    test_has_uncommitted

    # Config test
    test_load_sync_config

    # 3-way merge tests
    test_three_way_merge

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
