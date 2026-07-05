#!/bin/bash
# test-update-self.sh - integration test for the `powos update self` deploy loop.
#
# This is the check that answers "can I edit PowOS source and update my running
# system?" It runs the REAL deploy path against a throwaway source tree and
# asserts the files actually land in the live system. Self-cleaning.
#
# Runs on a PowOS-like system where /usr is writable: the Docker test container
# or a booted PowOS image (RAM overlay makes /usr writable). It SKIPS cleanly if
# it can't modify system dirs (e.g. plain Windows/macOS dev box), so it never
# false-fails.
#
#   Docker:  docker exec powos bash /test/tier1/test-update-self.sh
#   Booted:  sudo bash test/tier1/test-update-self.sh

set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  ok   - $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }

# Locate the powos binary: installed first, else this repo's bin/powos.
POWOS_BIN="$(command -v powos 2>/dev/null || true)"
if [[ -z "$POWOS_BIN" ]]; then
    POWOS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/powos"
fi

echo "== update-self deploy loop =="

# Preconditions — skip (not fail) if we can't safely exercise the real deploy.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    skip "needs root to write /usr (run in the container or with sudo)"
    echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
    exit 0
fi
if [[ ! -x "$POWOS_BIN" ]]; then
    skip "powos binary not found/executable at $POWOS_BIN"
    echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
    exit 0
fi
if ! mkdir -p /usr/lib/powos 2>/dev/null || [[ ! -w /usr/lib/powos ]]; then
    skip "/usr/lib/powos not writable (not a RAM-boot/live system)"
    echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
    exit 0
fi
# `powos update self` deploys via `sudo cp` (unconditionally, even as root).
# On a minimal CI/container image without sudo the copies fail silently (real
# PowOS systems always have sudo), so skip rather than report a false failure.
if ! command -v sudo >/dev/null 2>&1; then
    skip "sudo not installed (update self uses 'sudo cp' to deploy)"
    echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
    exit 0
fi

# Build a minimal throwaway "source checkout" with uniquely-named probe files.
SRC="$(mktemp -d)"
MARK="__powos_update_probe_$$"
mkdir -p "$SRC/bin" "$SRC/lib"
printf '#!/bin/bash\necho probe\n' > "$SRC/bin/$MARK"
printf '# probe lib for update-self test\n' > "$SRC/lib/$MARK.sh"

cleanup() {
    rm -f "/usr/bin/$MARK" "/usr/lib/powos/$MARK.sh" 2>/dev/null || true
    rm -rf "$SRC" 2>/dev/null || true
}
trap cleanup EXIT

# Run the real deploy from our throwaway source.
echo "  running: POWOS_SRC=$SRC powos update self"
POWOS_SRC="$SRC" "$POWOS_BIN" update self >/dev/null 2>&1 || true

# Assert the probe files were deployed to the live system.
if [[ -f "/usr/bin/$MARK" ]]; then
    pass "bin/* deployed to /usr/bin/"
else
    fail "bin/* NOT deployed to /usr/bin/ (update self did not copy binaries)"
fi

if [[ -f "/usr/lib/powos/$MARK.sh" ]]; then
    pass "lib/* deployed to /usr/lib/powos/"
else
    fail "lib/* NOT deployed to /usr/lib/powos/ (update self did not copy libs)"
fi

# Sanity: the deployed binary should be executable.
if [[ -x "/usr/bin/$MARK" ]]; then
    pass "deployed binary is executable"
else
    fail "deployed binary is not executable (chmod +x missing)"
fi

echo
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
[[ $FAIL -eq 0 ]]
