#!/bin/bash
# test-pause-reason.sh: friction f114 - "ship + verify queues paused with no reason or owner shown". Nothing at
# task start said the queue was paused, so the deploy order couldn't be planned.
#
# Covers tools/phone/ship.sh (pause --why/--until, status, request before it queues) and
# tools/phone/verify/queue.sh (pause --why/--until, list), both against sandboxed queue dirs - never the real
# ~/.cache/powos-ship-queue or ~/.cache/powos-verify-queue, never the real phone, never real launchd.
#   test/tier1/test-pause-reason.sh      exit 0 = all pass
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/pause-reason-test.XXXXXX")
# pkill -f "$T" is safe here: $T is a fresh mktemp path, guaranteed not to match any unrelated process - it only
# reaps anything this test itself spawned in the background (ship.sh request kicks a runner if none is up).
cleanup() { pkill -f "$T" >/dev/null 2>&1 || true; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"; }
trap cleanup EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig
mkdir -p "$HOME/.cache"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "       $2"; }

# ============================= tools/phone/ship.sh =============================================================
# A sandboxed checkout (own copy of ship.sh, so $REPO resolves inside $T - never the real PowOS tree) with one
# commit already pushed, so `request`'s ancestor check passes.
SA="$T/ship-agent"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$SA" 2>/dev/null
(cd "$SA" && git checkout -q -b worktree-powos-multiplatform
  mkdir -p tools/phone
  cp "$src/tools/phone/ship.sh" tools/phone/ship.sh
  echo seed > seed.txt
  git add -A && git commit -qm seed && git push -q origin worktree-powos-multiplatform 2>/dev/null)

SQ="$T/ship-queue"
run_ship() { (cd "$SA" && SHIP_DIR="$SQ" SHIP_QUIET_S=1 SHIP_QUIET_SHELL_S=1 SHIP_POLL_S=1 bash tools/phone/ship.sh "$@") 2>&1; }

out=$(run_ship pause --why "deploy order check" --until "after f114 lands"); rc=$?
[ $rc -eq 0 ] && ok "ship.sh pause --why --until exits 0" || bad "ship.sh pause --why --until exits 0" "rc=$rc: $out"
grep -q "by ship-agent: deploy order check" <<<"$out" && ok "pause's own message names who and why" \
  || bad "pause's own message names who and why" "$out"
grep -q "until after f114 lands" <<<"$out" && ok "pause's own message names until" || bad "pause's own message names until" "$out"
grep -q '^who=ship-agent$' "$SQ/paused" 2>/dev/null && ok "paused file records who=" || bad "paused file records who=" "$(cat "$SQ/paused" 2>/dev/null)"
grep -q '^why=' "$SQ/paused" 2>/dev/null && ok "paused file records why=" || bad "paused file records why=" "$(cat "$SQ/paused" 2>/dev/null)"

out=$(run_ship pause); rc=$?
[ $rc -ne 0 ] && grep -qi "why.*required" <<<"$out" && ok "pause without --why is refused" || bad "pause without --why is refused" "rc=$rc: $out"

out=$(run_ship status)
grep -q "PAUSED by ship-agent: deploy order check (until after f114 lands)" <<<"$out" \
  && ok "status shows who/why/until" || bad "status shows who/why/until" "$out"

out=$(run_ship request --silent)
grep -q "the ship service is PAUSED by ship-agent: deploy order check (until after f114 lands)" <<<"$out" \
  && ok "request prints the pause reason before it queues" || bad "request prints the pause reason before it queues" "$out"
# "before it queues": the pause line must come before the "ship requested" line in the same output.
pause_ln=$(grep -n "the ship service is PAUSED" <<<"$out" | head -1 | cut -d: -f1)
req_ln=$(grep -n "^ship requested" <<<"$out" | head -1 | cut -d: -f1)
[ -n "$pause_ln" ] && [ -n "$req_ln" ] && [ "$pause_ln" -lt "$req_ln" ] \
  && ok "the pause notice really does print before the request is queued" \
  || bad "the pause notice really does print before the request is queued" "$out"
ls "$SQ"/*.req >/dev/null 2>&1 && ok "the request still queues despite the pause (warns, never blocks)" \
  || bad "the request still queues despite the pause (warns, never blocks)" "$(ls "$SQ" 2>/dev/null)"

run_ship resume >/dev/null
out=$(run_ship status)
grep -qi PAUSED <<<"$out" && bad "status after resume must not still say PAUSED" "$out" \
  || ok "resume clears the pause"

# ============================================= tools/phone/verify/queue.sh ======================================
VA="$T/verify-agent"
git clone -q "$T/origin.git" "$VA" 2>/dev/null
(cd "$VA" && git checkout -q worktree-powos-multiplatform)
mkdir -p "$VA/tools/phone/verify"
cp "$src/tools/phone/verify/queue.sh" "$VA/tools/phone/verify/queue.sh"

VQ="$T/verify-queue"
run_queue() { (cd "$VA" && QUEUE_DIR="$VQ" bash tools/phone/verify/queue.sh "$@") 2>&1; }

out=$(run_queue pause); rc=$?
[ $rc -ne 0 ] && grep -qi "why.*required" <<<"$out" && ok "queue.sh pause without --why is refused" \
  || bad "queue.sh pause without --why is refused" "rc=$rc: $out"

out=$(run_queue pause --why "waiting on a phone update" --until "tonight"); rc=$?
[ $rc -eq 0 ] && ok "queue.sh pause --why --until exits 0" || bad "queue.sh pause --why --until exits 0" "rc=$rc: $out"
grep -q "by verify-agent: waiting on a phone update" <<<"$out" && ok "queue.sh pause's own message names who and why" \
  || bad "queue.sh pause's own message names who and why" "$out"

out=$(run_queue list)
grep -q "PAUSED by verify-agent: waiting on a phone update (until tonight)" <<<"$out" \
  && ok "queue.sh list shows who/why/until" || bad "queue.sh list shows who/why/until" "$out"

run_queue resume >/dev/null
out=$(run_queue list)
grep -qi PAUSED <<<"$out" && bad "queue.sh list after resume must not still say PAUSED" "$out" \
  || ok "queue.sh resume clears the pause"

# A bare `touch` (what the phone's status-pill tap used to leave, and what an old/foreign paused file looks like)
# must not crash `list` - it just can't show a reason.
touch "$VQ/paused"
# (not checking $? here: `list`'s own last pipeline can report rc=1 whenever no done/*.log exist yet - a
# pre-existing, unrelated quirk; this check is only about paused_info() tolerating a bare `touch`.)
out=$(run_queue list)
grep -q "PAUSED by unknown" <<<"$out" \
  && ok "a reasonless paused file still shows PAUSED (by unknown), not a crash" \
  || bad "a reasonless paused file still shows PAUSED (by unknown), not a crash" "$out"

echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
