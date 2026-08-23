#!/bin/bash
# test-errexit-pipefail.sh - Tier-1 guard against the install aborting itself.
#
# bin/powos runs under `set -e`. lib/install-system.sh does `set -uo pipefail`
# at the top — and because it is SOURCED, that pipefail applies to bin/powos's
# shell as well. The combination turns every failure-tolerant pipeline into a
# process-killer:
#
#     vk=$(grep -o 'rd.powos.variant=[^ ]*' /proc/cmdline 2>/dev/null | head -1)
#
# grep exits 1 when the karg is absent (it is absent on every medium we build),
# pipefail hands that up as the pipeline's status, the assignment inherits it,
# and errexit kills the installer. On a Steam Deck that fired ONE LINE after
# "Installation complete!": the disk was written, the bootloader installed, and
# the wizard still reported "Installer failed" and never copied the first-boot
# config onto the new system — which left it with no account configured.
#
# Every such assignment must therefore carry its own `||` fallback.
#
# Usage:  bash test/tier1/test-errexit-pipefail.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

# ── 1. Static: no unguarded pipeline assignments in the errexit-exposed libs ──
for lib in install-system.sh variants.sh; do
    f="$ROOT/lib/$lib"
    [[ -f "$f" ]] || continue
    bare=$(awk '
        /^[[:space:]]*#/           { next }
        /[A-Za-z_][A-Za-z0-9_]*=\$\(/ && /\|/ {
            if ($0 ~ /\|\|/) next          # has a fallback
            printf "%d: %s\n", NR, $0
        }' "$f")
    if [[ -z "$bare" ]]; then
        ok "$lib: every pipeline assignment has a || fallback"
    else
        bad "$lib: pipeline assignment with no fallback (errexit+pipefail kills the CLI)" "$bare"
    fi
done

# ── 2. Functional: the post-install tail must survive errexit + pipefail ──────
# This is the exact sequence that ran on the Deck after bootc succeeded.
out=$(cd "$ROOT" && bash -c '
    set -e
    POWOS_LIB=$PWD/lib
    source lib/install-system.sh          # brings its own set -uo pipefail
    ISV_DRY_RUN=0; ISV_TARGET=/dev/null; ISV_MODE=whole-disk; ISV_GAMES_DISK=""
    timedatectl() { return 1; }           # never touch the host clock from a test
    [[ -n "$ISV_GAMES_DISK" ]] && isv_create_games_on_separate_disk
    isv_post_install >/dev/null 2>&1
    echo REACHED_DONE
' 2>/dev/null) || true
if [[ "$out" == *REACHED_DONE* ]]; then
    ok "post-install tail completes under errexit+pipefail (no rd.powos.variant karg)"
else
    bad "post-install tail completes under errexit+pipefail" \
        "the installer aborts after a SUCCESSFUL install and reports failure"
fi

# ── 3. The mechanism itself, so the reason stays legible ─────────────────────
mech=$(bash -c 'set -eo pipefail; v=$(grep -o zzz-absent /proc/cmdline 2>/dev/null | head -1); echo SURVIVED' 2>/dev/null) || true
if [[ "$mech" != *SURVIVED* ]]; then
    ok "confirmed: errexit+pipefail does kill an unguarded pipeline assignment"
else
    bad "the failure mechanism no longer reproduces" \
        "bash changed behaviour, or /proc/cmdline now contains the pattern — revisit this test"
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
