#!/bin/bash
# run-all.sh - Discover and run every Tier-1 test.
#
# WHY THIS EXISTS: CI used to hand-enumerate which tier-1 tests to run. That
# list silently fell behind — 21 of 31 suites were never executed in CI,
# including every test for the mod manager, the games partition, and the
# help/dispatch contract. A test nobody runs is not a test.
#
# So: this runner GLOBS test/tier1/. Drop a new test file in and it runs, in
# CI and locally, with nothing to remember and no list to update.
#
# Usage:
#   bash test/tier1/run-all.sh              # all non-quarantined tests
#   bash test/tier1/run-all.sh --all        # include quarantined
#   bash test/tier1/run-all.sh --list       # show what would run
#   bash test/tier1/run-all.sh test-games   # run matching tests only

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
cd "$REPO_ROOT" || exit 1

# ── Quarantine ────────────────────────────────────────────────────────────
#
# Tests that do NOT gate the build. Every entry needs a reason and should be
# treated as debt, not as a resting place. Quarantined tests still RUN (so you
# can see them) — they just don't fail the suite.
#
# Keep this list short. If it grows, that is the signal, not the solution.
declare -A QUARANTINE=(
  # Empty, and it should stay that way. Everything that used to live here was
  # either a stale assertion about a deliberately-removed feature, or noise
  # from the pipefail/SIGPIPE flake — both fixed rather than parked.
)

# Tests needing a container/root, run in the image stage instead of here.
declare -A NEEDS_IMAGE=()

WANT_ALL=false; LIST_ONLY=false; FILTER=""
for a in "$@"; do
    case "$a" in
        --all)  WANT_ALL=true ;;
        --list) LIST_ONLY=true ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *)      FILTER="$a" ;;
    esac
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; YELLOW=""; BOLD=""; DIM=""; NC=""; }

mapfile -t TESTS < <(find test/tier1 -maxdepth 1 \( -name 'test-*.sh' -o -name 'test-*.py' \) \
                     ! -name 'run-all.sh' | sort)

if [[ -n "$FILTER" ]]; then
    mapfile -t TESTS < <(printf '%s\n' "${TESTS[@]}" | grep -- "$FILTER")
fi

if $LIST_ONLY; then
    for t in "${TESTS[@]}"; do
        b="$(basename "$t")"
        printf '%s%s\n' "$b" "${QUARANTINE[$b]:+  ${DIM}[quarantined]${NC}}"
    done
    exit 0
fi

echo "${BOLD}Tier-1 suite${NC} — ${#TESTS[@]} test files discovered"
echo

FAILED=(); QUARANTINED_FAIL=(); PASSED=0

for t in "${TESTS[@]}"; do
    b="$(basename "$t")"
    quarantined=false
    if [[ -n "${QUARANTINE[$b]:-}" ]] && ! $WANT_ALL; then quarantined=true; fi

    case "$t" in
        *.py) out="$(timeout 300 python3 "$t" 2>&1)"; rc=$? ;;
        *)    out="$(timeout 300 bash   "$t" 2>&1)"; rc=$? ;;
    esac

    # Most suites print a "Results: N passed, M failed" line; surface it.
    summary="$(grep -Eio 'results:[^=]*' <<< "$out" | tail -1 | sed 's/[[:space:]]*$//')"
    [[ -n "$summary" ]] || summary="(no summary; rc=$rc)"

    if (( rc == 0 )); then
        printf '  %s✓%s %-34s %s\n' "$GREEN" "$NC" "$b" "$DIM$summary$NC"
        PASSED=$((PASSED+1))
    elif $quarantined; then
        printf '  %s~%s %-34s %s\n' "$YELLOW" "$NC" "$b" "$YELLOW$summary  [quarantined]$NC"
        QUARANTINED_FAIL+=("$b")
    else
        printf '  %s✗%s %-34s %s\n' "$RED" "$NC" "$b" "$RED$summary$NC"
        FAILED+=("$b")
        # Show what actually failed — a red line with no detail is useless in CI.
        grep -iE '^\s*(FAIL|✗)' <<< "$out" | head -12 | sed 's/^/      /'
    fi
done

echo
echo "${BOLD}Summary${NC}: $PASSED passed, ${#FAILED[@]} failed, ${#QUARANTINED_FAIL[@]} quarantined-failing"

if (( ${#QUARANTINED_FAIL[@]} )); then
    echo
    echo "${YELLOW}Quarantined (not blocking — this is debt):${NC}"
    for b in "${QUARANTINED_FAIL[@]}"; do
        echo "  $b — ${QUARANTINE[$b]}"
    done
fi

if (( ${#FAILED[@]} )); then
    echo
    echo "${RED}FAILED:${NC} ${FAILED[*]}"
    exit 1
fi
echo "${GREEN}All non-quarantined tier-1 tests passed.${NC}"
