#!/bin/bash
# test-health-probes.sh - Tier-1 contract checks for `powos health` and the
# `powos update` dispatcher, both of which were split out of single oversized
# functions (cmd_health CC 101 -> 7, cmd_update CC 49 -> 8).
#
# These assert the CONTRACT, not the shape. A refactor that preserves the
# rendered report and the dispatch table must pass; one that drops a section,
# reorders the report, or extracts a probe and forgets to register it must
# fail. Deliberately NO assertions on the exact wording of a status line —
# that is what made two earlier suites fail on behaviour-preserving edits.
#
# Usage:  bash test/tier1/test-health-probes.sh
#
# Everything here is read-only and runs unrooted. `powos health` is invoked
# against a throwaway POWOS_ROOT so it cannot see a real git mirror and go to
# the network. `powos update` is NEVER invoked on a verb that applies
# anything: `packages` would run `dnf upgrade -y` on a box with the USB
# connected, and `self` would install into /usr.

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
[[ -f "$ROOT/bin/powos" ]] || ROOT="/var/lib/powos/src"
POWOS="$ROOT/bin/powos"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── the rendered report ───────────────────────────────────────────────────
echo "== powos health renders every section, in order =="
HEALTH="$(POWOS_ROOT="$TMP/root" bash "$POWOS" health 2>/dev/null)"
check "health produced output" '[[ -n "$HEALTH" ]]'
check "health exits 0" 'POWOS_ROOT="$TMP/root" bash "$POWOS" health >/dev/null 2>&1'

# Section headings are the load-bearing part of this report: they are what a
# user scrolls to, and what someone reading a pasted report looks for.
SECTIONS=("Layers" "RAM Overlay" "USB Drive" "Sync (RAM ↔ USB)"
          "Backup (USB → Cloud)" "User Data (CacheFS)" "Projects" "Overlays"
          "Containers" "AI System" "Hardware")

prev=0
for s in "${SECTIONS[@]}"; do
    ln="$(echo "$HEALTH" | grep -nF "$s" | head -1 | cut -d: -f1)"
    if [[ -z "$ln" ]]; then
        bad "section '$s' present"
    elif [[ "$ln" -le "$prev" ]]; then
        bad "section '$s' is out of order (line $ln, previous section at $prev)"
    else
        ok "section '$s' present and in order"
        prev="$ln"
    fi
done

check "report opens with the banner" 'echo "$HEALTH" | grep -q "PowOS Health Check"'
check "report closes with a verdict" \
    'echo "$HEALTH" | grep -qE "Issues: [0-9]+|All systems healthy"'

echo "== powos health --help documents the AI flag =="
HHELP="$(bash "$POWOS" health --help 2>/dev/null)"
check "--help exits 0"          'bash "$POWOS" health --help >/dev/null 2>&1'
check "--help mentions --ai"    'echo "$HHELP" | grep -q -- "--ai"'
# `grep -qv` is NOT a negation: it succeeds when ANY line fails to match, so
# it passes on almost anything. Negate the grep, not its lines.
check "--help is not the report" '! echo "$HHELP" | grep -q "PowOS Health Check"'

# ── probe registration ────────────────────────────────────────────────────
#
# cmd_health walks _HEALTH_PROBES. The failure this guards against is
# extracting a probe and never registering it: the section silently vanishes
# from the report and nothing else complains.
echo "== every registered probe exists, and every probe is registered =="
REGISTERED="$(sed -n '/^_HEALTH_PROBES=(/,/)/p' "$POWOS" \
    | tr -d '()' | sed 's/^_HEALTH_PROBES=//' | tr ' ' '\n' | grep -v '^$' | sort)"
check "the probe list is non-empty" '[[ -n "$REGISTERED" ]]'

for p in $REGISTERED; do
    check "registered probe '_health_$p' is defined" \
        "grep -q '^_health_${p}() {' \"\$POWOS\""
done

# The reverse direction. _health_* names that are NOT report sections are
# listed here explicitly, so adding a probe without registering it fails.
NOT_PROBES="issue warning summary usage ai_agent"
DEFINED="$(grep -oE '^_health_[a-z_]+\(\)' "$POWOS" | sed 's/^_health_//; s/()//' | sort)"
for d in $DEFINED; do
    case " $NOT_PROBES " in
        *" $d "*) continue ;;
    esac
    check "defined probe '_health_$d' is in _HEALTH_PROBES" \
        'echo "$REGISTERED" | grep -qx "$d"'
done

echo "== the counters survive set -e from zero =="
# `((n++))` returns 1 when n is 0 and aborts the shell under set -e. The
# helpers must not reintroduce that; this is the crash class that put
# `|| true` on every increment in the first place.
check "_health_issue/_health_warning are safe at zero" \
    'bash -c "
       set -euo pipefail
       eval \"\$(sed -n \"/^_health_issue()/,/^_health_warning()/p\" \"$POWOS\")\"
       _HEALTH_ISSUES=0; _HEALTH_WARNINGS=0
       _health_issue; _health_issue; _health_warning
       [[ \$_HEALTH_ISSUES -eq 2 && \$_HEALTH_WARNINGS -eq 1 ]]"'

# ── the update dispatcher ─────────────────────────────────────────────────
echo "== powos update dispatches every documented verb =="
UUSAGE="$(bash "$POWOS" update definitely-not-a-verb 2>/dev/null)"
check "unknown verb prints usage" 'echo "$UUSAGE" | grep -q "Usage: powos update"'
for verb in check os powos packages projects apply; do
    check "usage lists '$verb'"           'echo "$UUSAGE" | grep -q "$verb"'
    check "case has an arm for '$verb'"   \
        "sed -n '/^cmd_update() {/,/^}/p' \"\$POWOS\" | grep -qE '^ +($verb|[a-z|]*\\|$verb|$verb\\|[a-z|]*)\\)'"
done

# Every handler the dispatcher names must exist, and vice versa: an arm
# pointing at a function nobody defined is the way a split-up case breaks.
echo "== update handlers are defined and reachable =="
ARM_CALLS="$(sed -n '/^cmd_update() {/,/^}/p' "$POWOS" \
    | grep -oE '_update_[a-z_]+' | sort -u)"
check "the case calls extracted handlers" '[[ -n "$ARM_CALLS" ]]'
for h in $ARM_CALLS; do
    check "handler '$h' is defined" "grep -q '^${h}() {' \"\$POWOS\""
done
for h in $(grep -oE '^_update_[a-z_]+\(\)' "$POWOS" | sed 's/()//' | sort -u); do
    # helpers called by another handler rather than by the case are fine, so
    # only require that something in the file calls them at all
    check "handler '$h' is called" \
        "grep -qE '(^|[^a-z_])${h}([^a-z_(]|\$)' \"\$POWOS\""
done

echo "== update self refuses a missing source tree without touching /usr =="
OUT="$(bash "$POWOS" update self --from "$TMP/no-such-tree" 2>&1)"; RC=$?
check "exits non-zero"        '[[ $RC -ne 0 ]]'
check "names the missing dir" 'echo "$OUT" | grep -q "$TMP/no-such-tree"'
check "never reached install" '! echo "$OUT" | grep -q "Installing from Containerfile map"'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
