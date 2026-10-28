#!/bin/bash
# test-self-loop.sh - `powos self apply/rollback` (snapshot + restore under a fake ROOT) and the unknown-baked-sha
# matcher (self_find_matching_commit) against a real throwaway git repo. No network, no writes outside a temp dir.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [[ "$2" == 0 ]]; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi; }

. "$REPO/lib/self-phone.sh"
# --- snapshot/rollback in a fake root
S=$T/src R=$T/root
mkdir -p $S/bin $S/lib/sub $R/usr/bin $R/usr/lib/powos $R/usr/share/powos
echo new > $S/bin/tool; echo new > $S/lib/sub/a.sh; echo fresh > $S/lib/added.sh
echo old > $R/usr/bin/tool; echo old > $R/usr/share/powos/revision
self_phone_snapshot $S $R; ok "snapshot" $?
self_phone_apply $S abc123 $R; ok "apply" $?
[[ "$(cat $R/usr/bin/tool)" == new && -f $R/usr/lib/powos/added.sh ]]; ok "applied files present" $?
self_phone_rollback $R; ok "rollback" $?
[[ "$(cat $R/usr/bin/tool)" == old && "$(cat $R/usr/share/powos/revision)" == old ]]; ok "old files restored" $?
[[ ! -e $R/usr/lib/powos/added.sh && ! -e $R/usr/lib/powos/sub/a.sh ]]; ok "added files removed" $?
self_phone_rollback $R 2>/dev/null; [[ $? -ne 0 ]]; ok "second rollback refused (no point)" $?

# --- matcher: origin with 2 commits, working tree equals the first
O=$T/origin; mkdir -p $O/bin $O/lib; git -C $O init -q -b main
git -C $O config user.email t@t; git -C $O config user.name t
echo one > $O/bin/x; echo one > $O/lib/y; git -C $O add -A; git -C $O commit -qm c1; c1=$(git -C $O rev-parse HEAD)
echo two > $O/bin/x; git -C $O commit -qam c2
W=$T/work; mkdir -p $W/bin $W/lib; echo one > $W/bin/x; echo one > $W/lib/y; echo extra > $W/README
git -C $W init -q -b main; git -C $W remote add origin $O; git -C $W fetch -q origin main
SELF_BRANCH=main
eval "$(sed -n '/^self_find_matching_commit()/,/^}/p' "$REPO/lib/self.sh")"
[[ "$(self_find_matching_commit $W)" == "$c1" ]]; ok "matcher finds the exact commit" $?
echo edited > $W/bin/x
[[ -z "$(self_find_matching_commit $W)" ]]; ok "edited bin/ matches nothing" $?
echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
