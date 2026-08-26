#!/bin/bash
# test-reload.sh — unit tests for `powos reload` (lib/reload.sh).
#
# cmd_reload is the "apply my local changes to this machine" command. It is a
# sequence of phases — resolve the checkout, refuse stale/broken code, decide
# live-vs-build, apply, report — and every one of those steps either sudo's,
# writes to /usr, or talks to systemd-sysext. So the phases it orchestrates
# are shadowed by RECORDERS with programmable exit codes: that makes every
# branch and every refusal reachable on any box, as an ordinary user, without
# touching the running system.
#
# Asserted on the CONTRACT — exit code, which phase ran, in what order — not
# on wording, so rewording a message cannot fail a test about a guard.

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. Last-command status is the right semantics for an assertion.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Prefer the WORKING TREE over the installed copy, or running the suite inside
# a PowOS image would silently test the baked lib instead of the change.
LIB="$REPO/lib/reload.sh"
[[ -f "$LIB" ]] || LIB="/usr/lib/powos/reload.sh"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== powos reload =="
bash -n "$LIB" && ok "reload.sh parses" || bad "reload.sh has a syntax error"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export POWOS_LIB="$REPO/lib"
export POWOS_DEV_APPLIED_FILE="$WORK/applied"
export HOME="$WORK/home"; mkdir -p "$HOME"
SRC="$WORK/src"; mkdir -p "$SRC/lib" "$SRC/.git"

# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source lib"; exit 1; }

# ── recorders for everything cmd_reload orchestrates ──────────────
# A FILE, not an array: cmd_reload runs `git ... | tail -2`, and a pipeline
# stage is a subshell — an array appended to there is discarded when it exits,
# so the recorder would silently miss exactly the call under test.
CALLS="$WORK/calls"; : > "$CALLS"
rec() { printf '%s\n' "$*" >> "$CALLS"; }
calls() { cat "$CALLS"; }
reset() { : > "$CALLS"; }
ncalls() { grep -c . "$CALLS"; }

reload_find()         { rec "find ${1:-}"; [[ "${FIND_RC:-0}" == 0 ]] && echo "$SRC"; return "${FIND_RC:-0}"; }
reload_remember()     { rec "remember"; }
reload_check_behind() { rec "check_behind"; }
reload_syntax_check() { rec "syntax_check"; return "${SYNTAX_RC:-0}"; }
reload_needs_build()  { rec "needs_build"; return "${NEEDS_BUILD_RC:-1}"; }
reload_changed_files(){ rec "changed_files"; printf '%s\n' ${CHANGED:-}; }
reload_usr_ro()       { rec "usr_ro"; return "${USR_RO_RC:-1}"; }
reload_drop_sysext()  { rec "drop_sysext"; }
reload_apply_sysext() { rec "apply_sysext $2"; return "${APPLY_RC:-0}"; }
reload_apply_live()   { rec "apply_live"; return "${APPLY_RC:-0}"; }
reload_post_apply()   { rec "post_apply"; }
reload_mark_applied() { rec "mark_applied"; }
confirm()             { rec "confirm"; return "${CONFIRM_RC:-1}"; }
git()                 { rec "git $*"; return "${GIT_RC:-0}"; }
cat > "$SRC/lib/build-image.sh" <<'BIMG'
cmd_build_image() { rec "build_image $*"; return "${BUILD_RC:-0}"; }
BIMG

# ══════════════════════════════════════════════════════════════════
echo "== option grammar =="
# ══════════════════════════════════════════════════════════════════
reset; out=$(cmd_reload --help 2>&1); rc=$?
check "--help prints the usage block and succeeds" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -q -- "--drop"'
check "--help does nothing else at all" '[[ "$(ncalls)" -eq 0 ]]'

reset; out=$(cmd_reload --wibble 2>&1); rc=$?
check "an unknown flag is refused"      '[[ $rc -ne 0 ]]'
check "an unknown flag applies nothing" '[[ "$(ncalls)" -eq 0 ]]'

reset; cmd_reload --drop >/dev/null 2>&1; rc=$?
check "--drop removes the overlay and stops"        '[[ $rc -eq 0 ]]'
check "--drop does not go looking for a checkout" \
    'calls | grep -q "^drop_sysext" && ! calls | grep -q "^find"'

reset; cmd_reload --where >/dev/null 2>&1; rc=$?
check "--where prints the source and stops"         '[[ $rc -eq 0 ]]'
check "--where REMEMBERS the checkout but applies nothing" \
    'calls | grep -q "^remember" && ! calls | grep -q "^syntax_check"'

# ══════════════════════════════════════════════════════════════════
echo "== refusals: no checkout, stale code, broken code =="
# ══════════════════════════════════════════════════════════════════
reset; out=$(FIND_RC=1 cmd_reload 2>&1); rc=$?
check "no checkout found → refused"    '[[ $rc -ne 0 ]]'
check "no checkout → nothing applied"  '! calls | grep -q "^syntax_check"'

# SAFETY: a syntax error in the checkout would brick the live CLI.
reset; SYNTAX_RC=1 cmd_reload >/dev/null 2>&1; rc=$?
check "a syntax error in the checkout is REFUSED"  '[[ $rc -ne 0 ]]'
check "nothing is applied after a syntax error" \
    '! calls | grep -qE "^(apply_live|apply_sysext|build_image)"'

# Never silently apply stale code: a plain reload checks whether the checkout
# is behind its upstream; --pull skips that because it is about to pull.
reset; cmd_reload >/dev/null 2>&1
check "a plain reload checks for staleness first"  'calls | grep -q "^check_behind"'
reset; cmd_reload --pull >/dev/null 2>&1
check "--pull pulls instead of warning" \
    'calls | grep -q "^git" && ! calls | grep -q "^check_behind"'
reset; GIT_RC=1 cmd_reload --pull >/dev/null 2>&1; rc=$?
check "a failed pull does not abort the apply (applies what is there)" \
    '[[ $rc -eq 0 ]] && calls | grep -qE "^apply_(live|sysext)"'

# ══════════════════════════════════════════════════════════════════
echo "== live vs build: changes a live apply cannot pick up =="
# ══════════════════════════════════════════════════════════════════
reset; NEEDS_BUILD_RC=0 CHANGED=Containerfile cmd_reload >/dev/null 2>&1
check "build-time changes prompt for a build" 'calls | grep -q "^confirm"'
check "declining still applies the hot-reloadable parts" \
    'calls | grep -qE "^apply_(live|sysext)" && ! calls | grep -q "^build_image"'
reset; NEEDS_BUILD_RC=0 CONFIRM_RC=0 CHANGED=Containerfile cmd_reload >/dev/null 2>&1
check "accepting switches to the full build" \
    'calls | grep -q "^build_image" && ! calls | grep -qE "^apply_(live|sysext)"'
reset; NEEDS_BUILD_RC=0 CHANGED=Containerfile cmd_reload --live >/dev/null 2>&1
check "--live forces the live path without asking" \
    '! calls | grep -q "^confirm" && calls | grep -qE "^apply_(live|sysext)"'

reset; cmd_reload --build >/dev/null 2>&1; rc=$?
check "--build bakes and switches"                 '[[ $rc -eq 0 ]] && calls | grep -q "^build_image --switch"'
check "--build marks the tree as applied on success" 'calls | grep -q "^mark_applied"'
reset; BUILD_RC=2 cmd_reload --build >/dev/null 2>&1; rc=$?
check "a failed build propagates its exit code"    '[[ $rc -eq 2 ]]'
check "a failed build does NOT mark the tree applied" '! calls | grep -q "^mark_applied"'
# The overlay must go BEFORE the switch, or it shadows the freshly built base.
reset; USR_RO_RC=0 cmd_reload --build >/dev/null 2>&1
check "--build drops the sysext overlay before switching" \
    '[[ "$(calls | grep -nE "^(drop_sysext|build_image)" | head -1 | cut -d: -f2)" == "drop_sysext" ]]'
mv "$SRC/lib/build-image.sh" "$WORK/build-image.parked"
reset; out=$(POWOS_LIB=/nonexistent cmd_reload --build 2>&1); rc=$?
check "--build with no build-image.sh anywhere is refused" '[[ $rc -ne 0 ]]'
check "--build with no builder switches nothing" '! calls | grep -q "^build_image"'
mv "$WORK/build-image.parked" "$SRC/lib/build-image.sh"

# ══════════════════════════════════════════════════════════════════
echo "== apply: the right mechanism, and every exit code =="
# ══════════════════════════════════════════════════════════════════
reset; USR_RO_RC=1 cmd_reload >/dev/null 2>&1
check "writable /usr → direct copy"      'calls | grep -q "^apply_live"'
reset; USR_RO_RC=0 cmd_reload >/dev/null 2>&1
check "read-only /usr → systemd-sysext"  'calls | grep -q "^apply_sysext"'
reset; USR_RO_RC=0 cmd_reload >/dev/null 2>&1
check "persistent by default (/var/lib/extensions)" \
    'calls | grep -q "^apply_sysext /var/lib/extensions"'
reset; USR_RO_RC=0 cmd_reload --once >/dev/null 2>&1
check "--once is ephemeral (/run/extensions, cleared on reboot)" \
    'calls | grep -q "^apply_sysext /run/extensions"'

for pair in "42:reverted" "3:refresh" "4:merge"; do
    code="${pair%%:*}"
    reset; USR_RO_RC=0 APPLY_RC="$code" cmd_reload >/dev/null 2>&1; rc=$?
    check "apply exit $code is reported as a failure"  '[[ $rc -ne 0 ]]'
    check "apply exit $code does NOT mark the tree applied" '! calls | grep -q "^mark_applied"'
done
reset; APPLY_RC=9 cmd_reload >/dev/null 2>&1; rc=$?
check "an unrecognised apply failure passes its code through" '[[ $rc -eq 9 ]]'

reset; APPLY_RC=0 cmd_reload >/dev/null 2>&1; rc=$?
check "a successful apply returns 0"  '[[ $rc -eq 0 ]]'
check "a successful apply runs the follow-up work, THEN marks it applied" \
    '[[ "$(calls | grep -nE "^(post_apply|mark_applied)" | head -1 | cut -d: -f2)" == "post_apply" ]]'

# ── reload_apply publishes which mechanism was used ───────────────
reset; USR_RO_RC=0 reload_apply "$SRC" /var/lib/extensions >/dev/null 2>&1
check "reload_apply records that a sysext overlay was used" '[[ "$RELOAD_APPLIED_RO" == 1 ]]'
reset; USR_RO_RC=1 reload_apply "$SRC" /var/lib/extensions >/dev/null 2>&1
check "reload_apply records a direct /usr apply"            '[[ "$RELOAD_APPLIED_RO" == 0 ]]'

# ── reload_report: only a sysext apply can be rolled back ─────────
out=$(reload_report 1 0 2>&1)
check "persistent sysext apply explains the rollback"  'echo "$out" | grep -q -- "--drop"'
out=$(reload_report 1 1 2>&1)
check "ephemeral apply says it is cleared on reboot"   'echo "$out" | grep -qi "reboot"'
out=$(reload_report 0 0 2>&1)
check "a direct /usr apply offers no sysext rollback"  '! echo "$out" | grep -q -- "--drop"'

# ── reload_refresh_source: pull only when asked ───────────────────
reset; reload_refresh_source "$SRC" 0 >/dev/null 2>&1
check "refresh: without --pull it only warns about staleness" \
    'calls | grep -q "^check_behind" && ! calls | grep -q "^git"'
reset; reload_refresh_source "$SRC" 1 >/dev/null 2>&1
check "refresh: with --pull it pulls and skips the warning" \
    'calls | grep -q "^git .*pull" && ! calls | grep -q "^check_behind"'
reset; reload_refresh_source "$WORK/nogit" 1; rc=$?
check "refresh: a checkout with no .git is not pulled" \
    '[[ $rc -eq 0 ]] && ! calls | grep -q "^git"'

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
