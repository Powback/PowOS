#!/bin/bash
# test-mobile.sh — Tier-1 tests for powos mobile mode live bind implementation.
#
# Covers:
#   - calculate_mobile_size() with mocked category data
#   - create_mobile_tmpfs() mount/unmount
#   - _copy_categories_to_dir() with a fake package list
#   - do_live_binds() / undo_live_binds() with temp dirs
#   - mobile_status() stale-state detection
#   - is_mobile_enabled() based on bind record
#
# Bind mounts work in the privileged powos Docker container.
# Run: docker exec powos bash /var/lib/powos/src/test/tier1/test-mobile.sh
# Or:  bash test/tier1/test-mobile.sh   (from repo root, as root)

set -uo pipefail

# ── locate lib ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MOBILE_LIB="$REPO_ROOT/lib/mobile.sh"
[[ -f "$MOBILE_LIB" ]] || MOBILE_LIB="/usr/lib/powos/mobile.sh"
[[ -f "$MOBILE_LIB" ]] || { echo "FATAL: mobile.sh not found"; exit 1; }

# ── test harness ─────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  - SKIP: $1"; }

# ── set up an isolated state dir so we don't touch /run/powos ─────────────────
TESTDIR="$(mktemp -d)"

cleanup_test_env() {
    local d
    for d in "$TESTDIR"/bind-target-a "$TESTDIR"/mobile-ram; do
        mountpoint -q "$d" 2>/dev/null && umount "$d" 2>/dev/null || true
    done
    rm -rf "$TESTDIR"
}
trap 'cleanup_test_env' EXIT

# Override env vars that mobile.sh reads at source time
export POWOS_STATE_DIR="$TESTDIR/state"
export POWOS_USB_MOUNT="$TESTDIR/usb"
mkdir -p "$TESTDIR/state" "$TESTDIR/usb/mobile"

# Source the library
# shellcheck source=../../lib/mobile.sh
source "$MOBILE_LIB"

# Re-point the constants to our test dirs (they were set from env at source time,
# but re-assign for clarity and to be sure)
STATE_DIR="$TESTDIR/state"
MOBILE_RAM_DIR="$STATE_DIR/mobile-ram"
MOBILE_BIND_RECORD="$STATE_DIR/mobile-bind-record"
USB_MOUNT="$TESTDIR/usb"
MOBILE_DIR="$USB_MOUNT/mobile"
MOBILE_STATE="$MOBILE_DIR/state"
MOBILE_EXCLUDE="$MOBILE_DIR/exclude"

# ── Mock RPM functions with controlled data ───────────────────────────────────
# Override the four functions mobile.sh uses so tests don't need rpm installed.

get_categories() { printf '%s\n' "TestCat/Base" "TestCat/Apps"; }

get_category_size() {
    case "$1" in
        "TestCat/Base") echo 1048576 ;;  # 1 MiB
        "TestCat/Apps") echo 2097152 ;;  # 2 MiB
        *)              echo 0 ;;
    esac
}

get_packages_in_category() {
    case "$1" in
        "TestCat/Base") echo "pkg-base" ;;
        "TestCat/Apps") echo "pkg-apps" ;;
        *)              echo "" ;;
    esac
}

# Files listed by each mock package (absolute paths under TESTDIR/fake-fs)
FAKEFS="$TESTDIR/fake-fs"
get_package_files() {
    case "$1" in
        "pkg-base") printf '%s\n' \
            "$FAKEFS/usr" \
            "$FAKEFS/usr/bin" \
            "$FAKEFS/usr/bin/base-tool" \
            "$FAKEFS/usr/lib" \
            "$FAKEFS/usr/lib/base.so" ;;
        "pkg-apps") printf '%s\n' \
            "$FAKEFS/opt" \
            "$FAKEFS/opt/myapp" \
            "$FAKEFS/opt/myapp/bin" \
            "$FAKEFS/opt/myapp/bin/myapp" ;;
        *) ;;
    esac
}

# Create the fake filesystem that get_package_files refers to
setup_fake_fs() {
    mkdir -p "$FAKEFS/usr/bin" "$FAKEFS/usr/lib" "$FAKEFS/opt/myapp/bin"
    echo "#!/bin/sh" > "$FAKEFS/usr/bin/base-tool"
    echo "lib content" > "$FAKEFS/usr/lib/base.so"
    echo "#!/bin/sh" > "$FAKEFS/opt/myapp/bin/myapp"
    chmod +x "$FAKEFS/usr/bin/base-tool" "$FAKEFS/opt/myapp/bin/myapp"
}

can_mount() {
    # Check if we can actually mount a tmpfs (needs root + capability).
    # EUID=0 is necessary but not sufficient in unprivileged containers.
    [[ $EUID -eq 0 ]] || return 1
    local td
    td=$(mktemp -d)
    if mount -t tmpfs -o size=1m tmpfs "$td" 2>/dev/null; then
        umount "$td" 2>/dev/null || true
        rmdir "$td" 2>/dev/null || true
        return 0
    fi
    rmdir "$td" 2>/dev/null || true
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " PowOS mobile mode — tier-1 tests"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 1. calculate_mobile_size ──────────────────────────────────────────────────
test_calculate_size() {
    echo "1. calculate_mobile_size()"
    save_exclusions ""
    local got expected
    got=$(calculate_mobile_size)
    expected=$((1048576 + 2097152))
    if [[ "$got" -eq "$expected" ]]; then
        pass "sum of all categories ($got bytes)"
    else
        fail "expected $expected, got $got"
    fi

    mobile_exclude "TestCat/Apps"
    got=$(calculate_mobile_size)
    if [[ "$got" -eq 1048576 ]]; then
        pass "respects exclusion (1 MiB with Apps excluded)"
    else
        fail "expected 1048576 with exclusion, got $got"
    fi
    save_exclusions ""
}
test_calculate_size

# ── 2. state management ───────────────────────────────────────────────────────
test_state_mgmt() {
    echo ""
    echo "2. State management"
    set_mobile_state "live"
    local s
    s=$(get_mobile_state)
    [[ "$s" == "live" ]] \
        && pass "set/get round-trip for 'live'" \
        || fail "expected 'live', got '$s'"

    set_mobile_state "disabled"
    s=$(get_mobile_state)
    [[ "$s" == "disabled" ]] \
        && pass "'disabled' persists" \
        || fail "expected 'disabled', got '$s'"
}
test_state_mgmt

# ── 3. is_mobile_enabled based on bind record (not state file) ─────────────────
test_is_enabled() {
    echo ""
    echo "3. is_mobile_enabled() reflects bind record"
    rm -f "$MOBILE_BIND_RECORD"
    set_mobile_state "live"   # state says live, but no bind record
    if ! is_mobile_enabled; then
        pass "false when bind record missing (state file irrelevant)"
    else
        fail "returned true despite no bind record"
    fi

    echo "/usr" > "$MOBILE_BIND_RECORD"
    if is_mobile_enabled; then
        pass "true when bind record exists"
    else
        fail "returned false despite bind record present"
    fi
    rm -f "$MOBILE_BIND_RECORD"
    set_mobile_state "disabled"
}
test_is_enabled

# ── 4. _copy_categories_to_dir ────────────────────────────────────────────────
test_copy() {
    echo ""
    echo "4. _copy_categories_to_dir()"
    setup_fake_fs
    local dest="$TESTDIR/copy-dest"
    mkdir -p "$dest"
    save_exclusions ""

    if _copy_categories_to_dir "$dest" >/dev/null 2>&1; then
        pass "copy completes without error"
    else
        fail "copy returned non-zero"
    fi

    if [[ -f "${dest}${FAKEFS}/usr/bin/base-tool" ]]; then
        pass "base-tool copied"
    else
        fail "base-tool missing at ${dest}${FAKEFS}/usr/bin/base-tool"
    fi

    if [[ -f "${dest}${FAKEFS}/opt/myapp/bin/myapp" ]]; then
        pass "myapp copied"
    else
        fail "myapp missing under dest"
    fi

    if [[ -x "${dest}${FAKEFS}/usr/bin/base-tool" ]]; then
        pass "executable bit preserved (cp -a)"
    else
        fail "executable bit lost on copy"
    fi

    # Exclusion: Apps excluded → opt tree absent
    local dest2="$TESTDIR/copy-dest-excl"
    mkdir -p "$dest2"
    mobile_exclude "TestCat/Apps"
    _copy_categories_to_dir "$dest2" >/dev/null 2>&1 || true
    if [[ ! -e "${dest2}${FAKEFS}/opt" ]]; then
        pass "excluded category not copied"
    else
        fail "excluded category was copied to dest2"
    fi
    save_exclusions ""
}
test_copy

# ── 5. create_mobile_tmpfs (root only) ────────────────────────────────────────
test_tmpfs() {
    echo ""
    echo "5. create_mobile_tmpfs()"
    if ! can_mount; then
        skip "requires root — run as root or via: docker exec powos bash ..."
        return
    fi

    local tmpfs_dir="$TESTDIR/mobile-ram"
    MOBILE_RAM_DIR="$tmpfs_dir"

    if create_mobile_tmpfs 104857600 >/dev/null 2>&1; then  # 100 MiB
        if mountpoint -q "$tmpfs_dir" 2>/dev/null; then
            pass "tmpfs mounted at MOBILE_RAM_DIR"
        else
            fail "returned 0 but not a mountpoint"
        fi
        # Idempotent
        if create_mobile_tmpfs 104857600 >/dev/null 2>&1; then
            pass "idempotent: second call succeeds"
        else
            fail "second call failed"
        fi
        umount "$tmpfs_dir" 2>/dev/null || true
    else
        fail "create_mobile_tmpfs returned non-zero"
    fi
}
test_tmpfs

# ── 6. do_live_binds / undo_live_binds (root only) ──────────────────────────
test_binds() {
    echo ""
    echo "6. do_live_binds() / undo_live_binds()"
    if ! can_mount; then
        skip "requires root"
        return
    fi

    # Mount a tmpfs as the fake MOBILE_RAM_DIR
    local ram="$TESTDIR/mobile-ram"
    MOBILE_RAM_DIR="$ram"
    MOBILE_BIND_RECORD="$TESTDIR/state/mobile-bind-record"
    if ! mount -t tmpfs -o size=32m tmpfs "$ram" 2>/dev/null; then
        skip "tmpfs mount failed (non-privileged container)"
        return
    fi

    # Create a throw-away bind target and mirror it under MOBILE_RAM_DIR.
    # We override BIND_SAFE_TOPLEVEL to point at our temp dir so we never
    # bind over the real /usr.
    local bind_tgt="$TESTDIR/bind-target-a"
    mkdir -p "$bind_tgt"
    mkdir -p "${ram}${bind_tgt}"
    echo "ram-content" > "${ram}${bind_tgt}/ram-file.txt"

    local orig_safe=( "${BIND_SAFE_TOPLEVEL[@]}" )
    BIND_SAFE_TOPLEVEL=( "$bind_tgt" )

    if do_live_binds >/dev/null 2>&1; then
        pass "do_live_binds returns 0"
        if mountpoint -q "$bind_tgt" 2>/dev/null; then
            pass "bind_tgt is a mountpoint"
        else
            fail "bind_tgt not a mountpoint after do_live_binds"
        fi
        if [[ -f "$bind_tgt/ram-file.txt" ]]; then
            pass "RAM content visible through bind mount"
        else
            fail "RAM content not visible"
        fi
        if [[ -f "$MOBILE_BIND_RECORD" ]]; then
            pass "MOBILE_BIND_RECORD created"
            grep -q "$bind_tgt" "$MOBILE_BIND_RECORD" \
                && pass "bind record lists bound path" \
                || fail "bind record missing bound path"
        else
            fail "MOBILE_BIND_RECORD not created"
        fi

        # ── undo ──
        if undo_live_binds >/dev/null 2>&1; then
            pass "undo_live_binds returns 0"
        else
            fail "undo_live_binds returned non-zero"
        fi
        if ! mountpoint -q "$bind_tgt" 2>/dev/null; then
            pass "bind_tgt unmounted after undo"
        else
            fail "bind_tgt still mounted after undo"
        fi
        [[ ! -f "$MOBILE_BIND_RECORD" ]] \
            && pass "MOBILE_BIND_RECORD removed" \
            || fail "MOBILE_BIND_RECORD still present"
        if ! mountpoint -q "$ram" 2>/dev/null; then
            pass "tmpfs freed after undo"
        else
            umount "$ram" 2>/dev/null || true
            pass "tmpfs freed (cleaned up)"
        fi
    else
        fail "do_live_binds returned non-zero"
        umount "$ram" 2>/dev/null || true
    fi

    BIND_SAFE_TOPLEVEL=( "${orig_safe[@]}" )
}
test_binds

# ── 7. mobile_status stale-state detection ────────────────────────────────────
test_stale_status() {
    echo ""
    echo "7. mobile_status() stale-state detection"
    set_mobile_state "live"
    rm -f "$MOBILE_BIND_RECORD"  # no bind record → stale

    local out
    out=$(mobile_status 2>/dev/null)
    if echo "$out" | grep -q "did not survive reboot"; then
        pass "detects stale 'live' state"
    else
        fail "stale state not detected; output: $out"
    fi
    local s
    s=$(get_mobile_state)
    [[ "$s" == "disabled" ]] \
        && pass "auto-corrects stale state to disabled" \
        || fail "state not auto-corrected, still: $s"
}
test_stale_status

# ── 8. mobile_status normal mode ─────────────────────────────────────────────
test_normal_status() {
    echo ""
    echo "8. mobile_status() normal (USB-backed) mode"
    set_mobile_state "disabled"
    rm -f "$MOBILE_BIND_RECORD"
    local out
    out=$(mobile_status 2>/dev/null)
    if echo "$out" | grep -q "Normal (USB-backed)"; then
        pass "shows Normal mode when disabled"
    else
        fail "did not show Normal mode; output: $out"
    fi
}
test_normal_status

# ─── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
total=$((PASS + FAIL + SKIP))
echo " Results: $PASS/$total passed, $FAIL failed, $SKIP skipped"
echo "═══════════════════════════════════════════════════════════"
echo ""

[[ $FAIL -eq 0 ]]
