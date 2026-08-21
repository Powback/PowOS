#!/usr/bin/env bash
# test-overlay-prune.sh - Regression test for the sysext additive-only guard
#
# A sysext may only ADD to /usr. dnf --installroot resolves a full dependency
# closure, so an un-pruned overlay ships glibc, OpenSSL, systemd libs and bash
# built for the overlay's target release. Merging that over a running host on a
# newer release swaps its core libraries for older ones: the first time this
# shipped it killed sshd instantly and cost a machine its remote access.
#
# powos_prune_overlay_usr() is what stops that, so it gets its own tests.
# Everything here runs against fixture directories — no dnf, no network, no
# root, and it never touches the real /usr.
#
# Tests:
# 1. A file the reference /usr already provides is pruned
# 2. A genuinely new file is kept
# 3. The critical libraries that broke the Deck are pruned specifically
# 4. Nested paths keep their directory structure
# 5. Symlinks are pruned/kept like regular files
# 6. A DANGLING symlink on the host still counts as present
# 7. A symlinked ANCESTOR on the host is never turned into a directory
# 8. An overlay that adds nothing fails instead of shipping empty
# 9. The real reference /usr is never written to

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="${POWOS_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"
TEST_DIR="/tmp/powos-prune-test-$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# shellcheck source=/dev/null
source "$POWOS_ROOT/lib/build-helpers.sh"

# ─────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────

ok() {
    local message="$1"
    ((TESTS_RUN++)) || true
    ((TESTS_PASSED++)) || true
    echo -e "${GREEN}✓${NC} $message"
}

no() {
    local message="$1" detail="${2:-}"
    ((TESTS_RUN++)) || true
    ((TESTS_FAILED++)) || true
    echo -e "${RED}✗${NC} $message"
    [[ -n "$detail" ]] && echo "    $detail"
}

assert_absent() {
    local path="$1" message="$2"
    if [[ -e "$path" || -L "$path" ]]; then
        no "$message" "SHADOWED the host: $path exists in the overlay"
    else
        ok "$message"
    fi
}

assert_present() {
    local path="$1" message="$2"
    if [[ -e "$path" || -L "$path" ]]; then
        ok "$message"
    else
        no "$message" "missing from the overlay: $path"
    fi
}

# Build a fixture pair: a fake host /usr and a fake dnf temp root.
# Usage: make_fixture <name>  -> sets REF_USR, TEMP_ROOT, OUT_DIR
make_fixture() {
    local name="$1"
    REF_USR="$TEST_DIR/$name/ref/usr"
    TEMP_ROOT="$TEST_DIR/$name/temp"
    OUT_DIR="$TEST_DIR/$name/out"
    mkdir -p "$REF_USR" "$TEMP_ROOT/usr" "$OUT_DIR/usr"
}

setup() {
    echo "Setting up test environment..."
    mkdir -p "$TEST_DIR"
}

teardown() {
    echo "Cleaning up..."
    rm -rf "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────

test_prunes_what_the_host_has() {
    echo ""
    echo "TEST: files already on the host are pruned"
    make_fixture prunes

    mkdir -p "$REF_USR/bin"
    echo "host bash" > "$REF_USR/bin/bash"
    mkdir -p "$TEMP_ROOT/usr/bin"
    echo "overlay bash" > "$TEMP_ROOT/usr/bin/bash"
    echo "brand new" > "$TEMP_ROOT/usr/bin/powos-game-mode"

    powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null

    assert_absent  "$OUT_DIR/usr/bin/bash"            "bash present on host is pruned"
    assert_present "$OUT_DIR/usr/bin/powos-game-mode" "new file is kept"
}

test_prunes_the_libraries_that_broke_the_deck() {
    echo ""
    echo "TEST: the specific core libraries that killed sshd are pruned"
    make_fixture deck

    # Exactly what the 784MB overlay shipped over a running /usr.
    local critical=(
        lib64/libc.so.6
        lib64/libcrypto.so.3
        lib64/libssl.so.3
        lib64/libsystemd.so.0
        bin/bash
    )
    for rel in "${critical[@]}"; do
        mkdir -p "$REF_USR/$(dirname "$rel")" "$TEMP_ROOT/usr/$(dirname "$rel")"
        echo "host version"    > "$REF_USR/$rel"
        echo "overlay version" > "$TEMP_ROOT/usr/$rel"
    done
    # ...plus one file that genuinely belongs to the overlay, so the guard has
    # something to keep and does not fail for the wrong reason.
    mkdir -p "$TEMP_ROOT/usr/bin"
    echo "real payload" > "$TEMP_ROOT/usr/bin/gamescope-session-plus"

    powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null

    for rel in "${critical[@]}"; do
        assert_absent "$OUT_DIR/usr/$rel" "$rel is pruned, not shadowed"
    done
    assert_present "$OUT_DIR/usr/bin/gamescope-session-plus" "the overlay's own payload survives"
}

test_keeps_nested_structure() {
    echo ""
    echo "TEST: nested new paths keep their directory structure"
    make_fixture nested

    mkdir -p "$TEMP_ROOT/usr/share/applications" "$TEMP_ROOT/usr/lib/systemd/system"
    echo "desktop"  > "$TEMP_ROOT/usr/share/applications/powos-game-mode.desktop"
    echo "unit"     > "$TEMP_ROOT/usr/lib/systemd/system/powos-thing.service"

    powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null

    assert_present "$OUT_DIR/usr/share/applications/powos-game-mode.desktop" "nested desktop file kept"
    assert_present "$OUT_DIR/usr/lib/systemd/system/powos-thing.service"     "nested unit file kept"
}

test_handles_symlinks() {
    echo ""
    echo "TEST: symlinks are pruned/kept like regular files"
    make_fixture links

    mkdir -p "$REF_USR/bin" "$TEMP_ROOT/usr/bin"
    echo "target" > "$REF_USR/bin/sh-target"
    ln -s sh-target "$REF_USR/bin/sh"
    ln -s sh-target "$TEMP_ROOT/usr/bin/sh"          # host already has it
    ln -s powos-game-mode "$TEMP_ROOT/usr/bin/pgm"   # genuinely new

    powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null

    assert_absent  "$OUT_DIR/usr/bin/sh"  "symlink already on host is pruned"
    assert_present "$OUT_DIR/usr/bin/pgm" "new symlink is kept"

    ((TESTS_RUN++)) || true
    if [[ -L "$OUT_DIR/usr/bin/pgm" ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}✓${NC} new symlink stays a symlink (cp -a, not deref)"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}✗${NC} new symlink stays a symlink (cp -a, not deref)"
    fi
}

test_dangling_host_symlink_still_counts() {
    echo ""
    echo "TEST: a dangling symlink on the host still blocks shadowing"
    make_fixture dangling

    mkdir -p "$REF_USR/bin" "$TEMP_ROOT/usr/bin"
    ln -s /nonexistent-target "$REF_USR/bin/broken"   # -e says false, -L says true
    echo "overlay version" > "$TEMP_ROOT/usr/bin/broken"
    echo "payload"         > "$TEMP_ROOT/usr/bin/keeper"

    powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null

    assert_absent  "$OUT_DIR/usr/bin/broken" "dangling host symlink is not shadowed"
    assert_present "$OUT_DIR/usr/bin/keeper" "unrelated new file still kept"
}

test_never_replaces_a_host_symlink_dir() {
    echo ""
    echo "TEST: a symlinked ANCESTOR on the host is never turned into a directory"
    make_fixture ancestor

    # Exactly the ostree layout: /usr/local -> ../var/usrlocal
    mkdir -p "$REF_USR" "$TEST_DIR/ancestor/ref/var/usrlocal"
    ln -s ../var/usrlocal "$REF_USR/local"

    # A package that ships /usr/local/sbin/... (real: filesystem//usr/local/sbin)
    mkdir -p "$TEMP_ROOT/usr/local/sbin" "$TEMP_ROOT/usr/bin"
    echo "tool"    > "$TEMP_ROOT/usr/local/sbin/some-tool"
    echo "payload" > "$TEMP_ROOT/usr/bin/keeper"

    powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null

    assert_absent "$OUT_DIR/usr/local/sbin/some-tool" \
        "file under a symlinked host dir is pruned"
    assert_present "$OUT_DIR/usr/bin/keeper" "unrelated new file still kept"

    ((TESTS_RUN++)) || true
    if [[ -d "$OUT_DIR/usr/local" && ! -L "$OUT_DIR/usr/local" ]]; then
        ((TESTS_FAILED++)) || true
        echo -e "${RED}✗${NC} /usr/local is not materialised as a real directory"
        echo "    would mask the host symlink and hide /var/usrlocal"
    else
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}✓${NC} /usr/local is not materialised as a real directory"
    fi
}

test_empty_overlay_fails() {
    echo ""
    echo "TEST: an overlay that adds nothing fails loudly"
    make_fixture empty

    mkdir -p "$REF_USR/bin" "$TEMP_ROOT/usr/bin"
    echo "host" > "$REF_USR/bin/bash"
    echo "dupe" > "$TEMP_ROOT/usr/bin/bash"

    ((TESTS_RUN++)) || true
    if powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null 2>&1; then
        ((TESTS_FAILED++)) || true
        echo -e "${RED}✗${NC} returns non-zero when nothing new remains"
        echo "    it succeeded — an all-shadow overlay would ship"
    else
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}✓${NC} returns non-zero when nothing new remains"
    fi
}

test_reference_usr_untouched() {
    echo ""
    echo "TEST: the reference /usr is never written to"
    make_fixture readonly

    mkdir -p "$REF_USR/bin" "$TEMP_ROOT/usr/bin"
    echo "host bash" > "$REF_USR/bin/bash"
    echo "new"       > "$TEMP_ROOT/usr/bin/brand-new"

    local before after
    before="$(find "$REF_USR" | sort; cat "$REF_USR/bin/bash")"
    powos_prune_overlay_usr "$TEMP_ROOT" "$OUT_DIR" "$REF_USR" > /dev/null
    after="$(find "$REF_USR" | sort; cat "$REF_USR/bin/bash")"

    ((TESTS_RUN++)) || true
    if [[ "$before" == "$after" ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}✓${NC} reference /usr unchanged (contents and file list)"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}✗${NC} reference /usr unchanged (contents and file list)"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo " Overlay prune guard (sysext must only ADD to /usr)"
    echo "═══════════════════════════════════════════════════════════════════"

    setup

    test_prunes_what_the_host_has
    test_prunes_the_libraries_that_broke_the_deck
    test_keeps_nested_structure
    test_handles_symlinks
    test_dangling_host_symlink_still_counts
    test_never_replaces_a_host_symlink_dir
    test_empty_overlay_fails
    test_reference_usr_untouched

    teardown

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo " Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
    echo "═══════════════════════════════════════════════════════════════════"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
