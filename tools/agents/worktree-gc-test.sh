#!/bin/bash
# tools/agents/worktree-gc-test.sh: worktree.sh gc (f3) against a throwaway repo under $(mktemp -d) - never
# touches the real ~/pw or any real .claude/worktrees. ~5s.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WT_SCRIPT=$HERE/worktree.sh
T=$(mktemp -d)
trap 'cd /; rm -rf "$T"' EXIT
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 ($2)"; fails=1; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/main" >/dev/null
cd "$T/main"
git checkout -q -b worktree-powos-multiplatform
# C1: an "old" point on the base branch (backdated 40 min) - what an abandoned worktree would still sit at.
old="@$(( $(date +%s) - 2400 )) +0000"
echo one > f; git add f
GIT_COMMITTER_DATE="$old" git commit -q --date="$old" -m one
C1=$(git rev-parse HEAD)
# C2: origin's tip since moves on (recent) - a worktree tracking the tip at creation time sits here instead.
recent="@$(( $(date +%s) - 60 )) +0000"
echo two >> f; git add f
GIT_COMMITTER_DATE="$recent" git commit -q --date="$recent" -m two
git push -q origin worktree-powos-multiplatform

export POWOS_WT_ROOT=$T/pw POWOS_RUN_ROOT=$T/run
mkdir -p "$POWOS_WT_ROOT"

# at_old <name>: a worktree at C1 (old, fully merged into origin's tip - C1 is its ancestor) - the "should be
# gc'd" shape. Extra args become more commits/files for the ahead/dirty variants.
at_old() { git worktree add -q -b "agent/$1" "$POWOS_WT_ROOT/$1" "$C1" >/dev/null; }
at_tip() { git worktree add -q --track -b "agent/$1" "$POWOS_WT_ROOT/$1" origin/worktree-powos-multiplatform >/dev/null; }

at_old old-merged                                              # clean, ahead=0, 40 min old -> gc'd
at_tip recent-merged                                           # clean, ahead=0, ~1 min old -> too fresh, kept
at_old dirty-old; echo dirty >> "$POWOS_WT_ROOT/dirty-old/f"    # dirty -> kept
at_old ahead-old
echo unique >> "$POWOS_WT_ROOT/ahead-old/f"; git -C "$POWOS_WT_ROOT/ahead-old" commit -q -am unique  # ahead=1 -> kept
at_old runner-marked; echo "test runner" > "$POWOS_WT_ROOT/runner-marked/.powos-runner-checkout"    # marker -> kept
at_old powos-multiplatform                                     # excluded by name -> kept
git worktree add -q --detach "$T/main/.claude/worktrees/legacy-old" "$C1"   # the legacy $WT location -> gc'd too

dry=$(bash "$WT_SCRIPT" gc --dry-run)
ok "dry-run: flags old-merged" 'echo "$dry" | grep -q "would remove old-merged"'
ok 'dry-run: flags legacy-old (old .claude/worktrees location too)' 'echo "$dry" | grep -q "would remove legacy-old"'
ok "dry-run: never flags recent-merged (too fresh)" '! echo "$dry" | grep -q "recent-merged"'
ok "dry-run: never flags dirty-old" '! echo "$dry" | grep -q "dirty-old"'
ok "dry-run: never flags ahead-old" '! echo "$dry" | grep -q "ahead-old"'
ok "dry-run: never flags runner-marked" '! echo "$dry" | grep -q "runner-marked"'
ok "dry-run: never flags powos-multiplatform (excluded by name)" '! echo "$dry" | grep -q "would remove powos-multiplatform"'
ok "dry-run: touches nothing" '[ -d "$POWOS_WT_ROOT/old-merged" ] && [ -d "$T/main/.claude/worktrees/legacy-old" ]'

bash "$WT_SCRIPT" gc >/dev/null

ok "gc: removed old-merged" '[ ! -e "$POWOS_WT_ROOT/old-merged" ]'
ok "gc: removed its branch too" '! git branch --list agent/old-merged | grep -q agent/old-merged'
ok "gc: removed legacy-old (the old .claude/worktrees location)" '[ ! -e "$T/main/.claude/worktrees/legacy-old" ]'
ok "gc: kept recent-merged" '[ -d "$POWOS_WT_ROOT/recent-merged" ]'
ok "gc: kept dirty-old" '[ -d "$POWOS_WT_ROOT/dirty-old" ]'
ok "gc: kept ahead-old" '[ -d "$POWOS_WT_ROOT/ahead-old" ]'
ok "gc: kept runner-marked (never touches a runner checkout)" '[ -d "$POWOS_WT_ROOT/runner-marked" ]'
ok "gc: kept the powos-multiplatform-named one" '[ -d "$POWOS_WT_ROOT/powos-multiplatform" ]'

[ $fails = 0 ] && echo "worktree-gc-test: pass" || echo "worktree-gc-test: FAIL"
exit $fails
