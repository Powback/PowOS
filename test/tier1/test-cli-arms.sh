#!/bin/bash
# test-cli-arms.sh - Tier-1 contract checks for the five `powos` commands that
# were split out of oversized single functions:
#
#   cmd_containers  CC 41 -> 14      cmd_install  CC 34 -> 10
#   cmd_status      CC 30 ->  1      cmd_layers   CC 21 ->  6
#   cmd_rollback    CC 17 -> 11
#
# These assert the CONTRACT, not the shape: a refactor that preserves the
# rendered reports, the verb table and the exit codes must pass; one that
# drops a section, forgets to wire up an extracted handler, or "tidies away"
# one of the two deliberately-preserved non-zero returns must fail. There are
# no assertions on the exact wording of a status line — that is what made two
# earlier suites in this repo fail on behaviour-preserving edits.
#
# Usage:  bash test/tier1/test-cli-arms.sh
#
# Everything here is read-only and runs unrooted. The commands that would
# drive podman/distrobox for real are run with a PATH that contains neither,
# so the refusal paths are exercised and nothing on the box is touched.

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

# bin/powos sets -e and resolves its lib dir from `dirname "$0"/../lib`, so it
# can only be sourced from a shell whose $0 IS the script. Do that in a child
# and call one function, so neither -e nor -u leaks into this harness.
call_fn() {
    bash -c 'source "$0" help >/dev/null 2>&1; f="$1"; shift; "$f" "$@"' "$POWOS" "$@"
}

# The body of one function, as text (for definition/wiring cross-checks).
fn_body() {
    awk -v f="^$1\\\\(\\\\) \\\\{" '$0 ~ f {on=1} on {print} on && /^\}$/ {exit}' "$POWOS"
}

# ── every extracted handler is defined AND called ─────────────────────────
#
# The failure this guards against is the one that makes a split-up command
# silently lose a section or a verb: extract a handler and never wire it in
# (or delete the handler and leave the call). Neither shows up as a syntax
# error and neither is loud at runtime.
echo "== extracted handlers: defined <-> called =="
for pair in "cmd_status:_status_" "cmd_containers:_containers_do_" \
            "cmd_layers:_layers_" "cmd_install:_install_"; do
    caller="${pair%%:*}"; prefix="${pair##*:}"
    body="$(fn_body "$caller")"
    defined="$(grep -oE "^${prefix}[a-z_]+\(\)" "$POWOS" | sed 's/()//' | sort -u)"
    check "$caller has handlers to check" '[[ -n "$defined" ]]'
    # "reachable" means called by the dispatcher OR by one of its siblings:
    # _install_host_atomic is a phase of _install_to_host, not a verb arm.
    # The sibling text must EXCLUDE the function itself — fn_body includes the
    # definition line, so a self-match would make this assertion vacuous (it
    # was, and an "unwire the handler" mutation walked straight through it).
    for f in $defined; do
        others=""
        for g in $defined; do
            [[ "$g" == "$f" ]] && continue
            others+="$(fn_body "$g")"$'\n'
        done
        check "$f is reachable from $caller" \
            'echo "$body" | grep -qw "$f" || echo "$others" | grep -qw "$f"'
    done
    for f in $(echo "$body" | grep -oE "${prefix}[a-z_]+" | sort -u); do
        check "$f called by $caller is defined" 'grep -q "^$f() {" "$POWOS"'
    done
done
check "_rollback_show is defined"  'grep -q "^_rollback_show() {" "$POWOS"'
check "_rollback_show is called"   'fn_body cmd_rollback | grep -qw _rollback_show'

# ── the status report still has every section, in order ───────────────────
#
# cmd_status is now nothing but an ordered list of section calls, so the
# report's order IS that list. Reordering the calls, or dropping one, must
# fail here.
echo "== powos status renders every section, in order =="
ST="$(bash "$POWOS" status 2>/dev/null)"
check "status produced output" '[[ -n "$ST" ]]'

SECTIONS=("Active Layers" "RAM Overlay" "User Data (/home)" "USB Drive" "Unplug Safety")
prev=0
for s in "${SECTIONS[@]}"; do
    ln="$(echo "$ST" | grep -nF "$s" | head -1 | cut -d: -f1)"
    if [[ -z "$ln" ]]; then
        bad "section '$s' present"
    elif [[ "$ln" -le "$prev" ]]; then
        bad "section '$s' out of order (line $ln, previous at $prev)"
    else
        ok "section '$s' present and in order"; prev="$ln"
    fi
done

# The order the sections are PRINTED must match the order cmd_status calls
# them — otherwise the two can drift and only the rendered report is right.
CALLS="$(fn_body cmd_status | grep -oE '_status_[a-z_]+' | tr '\n' ' ')"
check "cmd_status calls the sections in report order" \
    '[[ "$CALLS" == "_status_layers _status_ram_overlay _status_user_data _status_usb _status_safety " ]]'

# ── every documented containers verb has an arm ───────────────────────────
echo "== every documented 'containers' verb has a case arm =="
ARMS="$(fn_body cmd_containers | sed -n 's/^ *\([a-z|*]*\)).*/\1/p' | tr '|' '\n')"
for v in list start stop restart logs create enter remove assemble export prune podman sync; do
    check "verb '$v' has an arm" 'echo "$ARMS" | grep -qx "$v"'
done
# ...and every arm is documented, so a verb cannot be added without a usage
# line. Only the PRIMARY spelling of each arm is checked: `ls`, `rm`, `delete`
# and `destroy` are deliberate aliases the usage text does not list, and
# `stats` has been undocumented since it was added — documenting it would
# change what `powos containers` prints, which is a behaviour change and does
# not belong in a refactor. Both exemptions are named, not silently skipped.
USAGE="$(call_fn _containers_do_usage 2>/dev/null)"
# NB: iterate with `read`, not `for v in $PRIMARY` — one of the arms IS `*`,
# and unquoted word-splitting would glob it into the repo's directory listing
# and then assert that "README.md" is a documented container verb.
PRIMARY="$(fn_body cmd_containers | sed -n 's/^ *\([a-z|*]*\)).*/\1/p' | cut -d'|' -f1)"
while read -r v; do
    [[ -z "$v" || "$v" == "*" || "$v" == "stats" ]] && continue
    check "verb '$v' is documented in the usage text" \
        'echo "$USAGE" | grep -qE "^  $v( |\[|<)"'
done <<< "$PRIMARY"
check "the undocumented-verb exemption is still just 'stats'" \
    '! echo "$USAGE" | grep -qE "^  stats"'

# ── refusals: argument checks still refuse, with the same exit code ───────
#
# Run with a PATH that has no podman and no distrobox: every one of these must
# refuse on its own argument check, before it ever reaches a tool.
echo "== argument checks refuse with a non-zero exit =="
BARE="$TMP/bin"; mkdir -p "$BARE"
for t in bash sed awk grep cat cut head tr sort wc mktemp rm mkdir python3 dirname; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$BARE/$t"
done
run_bare() { PATH="$BARE" bash "$POWOS" "$@" >/dev/null 2>&1; }

check "containers create <nothing> refuses"  '! run_bare containers create'
check "containers enter <nothing> refuses"   '! run_bare containers enter'
check "containers remove <nothing> refuses"  '! run_bare containers remove'
check "containers logs <nothing> refuses"    '! run_bare containers logs'
check "containers export <nothing> refuses"  '! run_bare containers export'
check "containers export <no app> refuses"   '! run_bare containers export dev'
check "containers start <nothing> refuses"   '! run_bare containers start'
check "containers stop <nothing> refuses"    '! run_bare containers stop'
check "containers restart <nothing> refuses" '! run_bare containers restart'
check "containers <unknown verb> prints usage and succeeds" 'run_bare containers bogus'
check "rollback <unknown target> refuses"    '! run_bare rollback bogus'
check "layers <unknown subcmd> succeeds"     'run_bare layers bogus'
check "layers clear <nothing> succeeds"      'run_bare layers clear'
check "layers clear <unknown> succeeds"      'run_bare layers clear bogus'

echo "== cmd_install argument handling =="
check "install --help exits 0"          'call_fn cmd_install --help >/dev/null 2>&1'
check "install -h exits 0"              'call_fn cmd_install -h >/dev/null 2>&1'
check "install --help is the usage"     'call_fn cmd_install --help 2>/dev/null | grep -q -- "--container"'
check "install with no packages refuses" '! call_fn cmd_install >/dev/null 2>&1'
check "install with only flags refuses"  '! call_fn cmd_install --host >/dev/null 2>&1'
check "install refusal names the fix"    'call_fn cmd_install 2>/dev/null | grep -q -- "--help"'

# ── the two exit statuses that were deliberately preserved ────────────────
#
# Both of these functions end in a test that is FALSE in a common case, so
# they return non-zero. That is what the inline case arms did before the
# split, and "fix" it here and you change an exit code inside a refactor.
# Each assertion below fails if someone appends `return 0`.
echo "== preserved non-zero returns (NOT bugs introduced by the split) =="

stats_rc() {
    PATH="$BARE" bash -c 'source "$0" help >/dev/null 2>&1
                          set +e
                          PATH=/nonexistent
                          _containers_do_stats "" >/dev/null 2>&1
                          echo $?' "$POWOS"
}
check "_containers_do_stats returns non-zero when podman is absent" \
    '[[ "$(stats_rc)" != "0" ]]'

# _rollback_show: the last thing it runs is `[[ $POWOS_SKIP_UPDATES == 1 ]]`.
mkdir -p "$TMP/state"
printf 'POWOS_SKIP_CUSTOM=1\nPOWOS_SKIP_UPDATES=0\n' > "$TMP/state/ramboot-state"
rb_rc() {
    bash -c 'source "$0" help >/dev/null 2>&1
             set +e
             STATE_DIR="$1"
             _rollback_show "$1/kargs" >/dev/null 2>&1
             echo $?' "$POWOS" "$TMP/state"
}
check "_rollback_show returns non-zero when only the custom flag is set" \
    '[[ "$(rb_rc)" != "0" ]]'
printf 'POWOS_SKIP_CUSTOM=0\nPOWOS_SKIP_UPDATES=1\n' > "$TMP/state/ramboot-state"
check "_rollback_show returns zero when the updates flag is set" \
    '[[ "$(rb_rc)" == "0" ]]'

# ── the complexity ratchet covers this file ───────────────────────────────
echo "== complexity =="
check "bin/powos is within its complexity budget" \
    'python3 "$ROOT/build/complexity.py" --check "$POWOS" >/dev/null'
check "no function in bin/powos is above 15" \
    '[[ "$(python3 "$ROOT/build/complexity.py" "$POWOS" | grep -c "CC>15: 0")" -eq 1 ]]'

echo ""
# "Results: N passed, M failed" is the line test/tier1/run-all.sh greps for to
# show a per-suite summary; without it the runner prints "(no summary)".
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
