#!/usr/bin/env bash
# tools/agents/offload.sh <cmd> [args...] — run <cmd> from this checkout on another host (default .58), in a
# copy of the current tree, and return its exit code.
#
# WHY: the Mac runs at load 40-60 and ship-step tests time out there (rc=124) while passing alone; .58 (Ryzen
# 32T) sits idle. Arch-neutral test work (tier1) runs there instead.
#
#   tools/agents/offload.sh tools/agents/tier1.sh test-sandbox.py
#   OFFLOAD_HOST=user@host OFFLOAD_CPUS=0-15 tools/agents/offload.sh make test
#
# How: the checkout's HEAD (+ origin/worktree-powos-multiplatform, for merge-base checks) is pushed into one
# shared bare repo on the host (~/offload/shared.git); each worktree NAME gets its own git worktree of it
# (~/offload/<name>), HEAD/index are reset to the pushed commit and the working tree's tracked + untracked
# files are rsynced over it (gitignored files - node_modules, build outputs - stay behind), so `git status/diff/
# ls-files` match the Mac. The command runs there under `nice -n 10` pinned to OFFLOAD_CPUS (default 0-23 of 32: .58 is shared with another project).
#
# Exit codes: the command's own; 255 = ssh failed; 97 = setup (push/rsync) failed.
# Killing this script (e.g. by a ship step's `timeout`) kills the remote process group too.

set -euo pipefail

HOST=${OFFLOAD_HOST:-powos@192.168.50.58}
CPUS=${OFFLOAD_CPUS:-0-23}
BASE_REF=refs/remotes/origin/worktree-powos-multiplatform

[ $# -gt 0 ] || { echo "usage: offload.sh <cmd> [args...]" >&2; exit 2; }

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) ||
  { echo "offload.sh: cd into a git checkout first" >&2; exit 2; }
NAME=$(basename "$TOPLEVEL" | tr -c 'A-Za-z0-9._\n-' _)
RDIR="offload/$NAME"   # relative to the remote $HOME
SHA=$(git -C "$TOPLEVEL" rev-parse HEAD)
# The command runs in the same subdirectory of the checkout as the caller.
SUB=$(git rev-parse --show-prefix)

CM=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-offload-%C" -o ControlPersist=60
    -o ConnectTimeout=5 -o BatchMode=yes)
rssh() { ssh "${CM[@]}" "$HOST" "$@"; }
q() { printf '%q ' "$@"; }

rssh "mkdir -p offload && { [ -d offload/shared.git ] || git init -q --bare offload/shared.git; }" ||
  { echo "offload.sh: $HOST unreachable" >&2; exit 255; }

REFS=("$SHA:refs/offload/$NAME")
git -C "$TOPLEVEL" rev-parse -q --verify "$BASE_REF" >/dev/null && REFS+=("+$BASE_REF:$BASE_REF")
GIT_SSH_COMMAND="ssh $(q "${CM[@]}")" git -C "$TOPLEVEL" push -q -f "$HOST:offload/shared.git" "${REFS[@]}" ||
  { echo "offload.sh: git push to $HOST failed" >&2; exit 97; }

# Remote tree := pushed HEAD, minus stale untracked files (git clean keeps ignored ones, i.e. its caches), minus
# the files deleted in the local working tree; then rsync every tracked + untracked-not-ignored local file.
# (A plain rsync --filter=':- .gitignore' would skip tracked files that match .gitignore, e.g. .claude/agents/.)
git -C "$TOPLEVEL" ls-files -dz | rssh "{ [ -e $RDIR/.git ] || git -C offload/shared.git worktree add -q -f --no-checkout --detach ../$NAME $SHA; } && cd $RDIR && git reset -q $SHA && git clean -fdq && xargs -0 rm -f --" ||
  { echo "offload.sh: remote worktree setup failed" >&2; exit 97; }

RSYNC=rsync; [ -x /opt/homebrew/bin/rsync ] && RSYNC=/opt/homebrew/bin/rsync   # launchd PATHs lack brew's
git -C "$TOPLEVEL" ls-files -coz --exclude-standard |
  "$RSYNC" -a --ignore-missing-args --from0 --files-from=- -e "ssh $(q "${CM[@]}")" "$TOPLEVEL/" "$HOST:$RDIR/" ||
  { echo "offload.sh: rsync to $HOST failed" >&2; exit 97; }

# Remote side: own process group (setsid) whose pgid lands in ~/offload/<name>.pid so a local kill can take it down.
REMOTE="cd $RDIR && git reset -q $SHA && cd ./$(q "$SUB") && { setsid taskset -c $CPUS nice -n 10 $(q "$@") </dev/null & p=\$!; echo \$p > \$HOME/$RDIR.pid; wait \$p; }"

kill_remote() {
  trap - TERM INT HUP
  rssh "kill -TERM -- -\$(cat $RDIR.pid) 2>/dev/null" || true
  exit 143
}
trap kill_remote TERM INT HUP

echo "offload.sh: running on $HOST:~/$RDIR (cpus $CPUS, nice 10): $*" >&2
t0=$(date +%s)
# In the background + `wait`, so a TERM from a caller's `timeout` runs the trap at once (bash defers traps
# until a foreground child exits).
rssh "$REMOTE" & sp=$!
set +e
wait $sp; rc=$?
set -e
echo "offload.sh: rc=$rc in $(($(date +%s) - t0))s on $HOST" >&2
exit $rc
