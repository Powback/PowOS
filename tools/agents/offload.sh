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
# Concurrency (f466): two offloads from the SAME worktree at once (a ship step runs jvm-offload.sh and
# TIER1_HOST=58 tier1.sh side by side) used to share one ref + one remote dir: one push died on "cannot lock ref",
# and the rsyncs/runs clobbered each other. Each run now claims a SLOT, held by a remote `flock` for its whole
# life: slot 1 is ~/offload/<name> (ref refs/offload/<name>), slot N>1 is ~/offload/<name>@N (refs/offload/<name>@N).
# Slots persist so each keeps its gitignored caches (gradle build/, node_modules: 30-160 MB a slot); extra slots
# idle for OFFLOAD_SLOT_TTL_DAYS (default 3) are swept on the next run. OFFLOAD_SLOTS (default 8) caps them.
#
# Exit codes: the command's own; 255 = ssh failed; 97 = setup (slot/push/rsync) failed, with a one-line reason.
# Killing this script (e.g. by a ship step's `timeout`) kills the remote process group too.

set -euo pipefail

HOST=${OFFLOAD_HOST:-powos@192.168.50.58}
CPUS=${OFFLOAD_CPUS:-0-23}
BASE_REF=refs/remotes/origin/worktree-powos-multiplatform

[ $# -gt 0 ] || { echo "usage: offload.sh <cmd> [args...]" >&2; exit 2; }

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) ||
  { echo "offload.sh: cd into a git checkout first" >&2; exit 2; }
BASE_NAME=$(basename "$TOPLEVEL" | tr -c 'A-Za-z0-9._\n-' _)
SLOTS=${OFFLOAD_SLOTS:-8}
TTL_DAYS=${OFFLOAD_SLOT_TTL_DAYS:-3}
SHA=$(git -C "$TOPLEVEL" rev-parse HEAD)
# The command runs in the same subdirectory of the checkout as the caller.
SUB=$(git rev-parse --show-prefix)

CM=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-offload-%C" -o ControlPersist=60
    -o ConnectTimeout=5 -o BatchMode=yes)
rssh() { ssh "${CM[@]}" "$HOST" "$@"; }
q() { printf '%q ' "$@"; }

rssh "mkdir -p offload && { [ -d offload/shared.git ] || git init -q --bare offload/shared.git; }" ||
  { echo "offload.sh: $HOST unreachable" >&2; exit 255; }

# Claim a slot: one ssh, kept open in the background for this script's lifetime, takes the first free
# `flock -n offload/<slot>.lock` and then blocks on stdin, so the lock lives exactly as long as we do. Its stdin
# is a pipe from a loop that ends when this script exits or its pid is gone (even after a SIGKILL): EOF -> lock released.
# The same remote call sweeps extra slots (<name>@N) whose lock is free and older than TTL_DAYS.
CLAIM=$(mktemp "${TMPDIR:-/tmp}/offload-claim.XXXXXX")
# On exit: touch $CLAIM.done -> the stdin loop ends -> remote `cat` sees EOF -> lock released -> the holder ssh
# exits; wait for that (5 s cap) so the slot is free by the time we return.
cleanup() {
  touch "$CLAIM.done"
  if [ -n "${HOLD_PID:-}" ]; then
    for _ in $(seq 50); do kill -0 "$HOLD_PID" 2>/dev/null || break; sleep 0.1; done
    kill "$HOLD_PID" 2>/dev/null || true
  fi
  rm -f "$CLAIM" "$CLAIM.done"; return 0
}
trap cleanup EXIT
CLAIM_SH='n=$1; slots=$2; ttl=$3; cd offload || exit 1
for l in *@*.lock; do
  [ -e "$l" ] || continue; s=${l%.lock}
  [ -n "$(find "$l" -mtime +"$ttl" 2>/dev/null)" ] || continue
  exec 8>>"$l"; flock -n 8 || { exec 8>&-; continue; }
  git -C shared.git worktree remove -f "../$s" 2>/dev/null; rm -rf "$s" "$s.pid"
  git -C shared.git update-ref -d "refs/offload/$s" 2>/dev/null; rm -f "$l"; exec 8>&-
done
git -C shared.git worktree prune 2>/dev/null
i=1; while [ "$i" -le "$slots" ]; do
  s=$n; [ "$i" -gt 1 ] && s="$n@$i"
  exec 9>>"$s.lock"
  if flock -n 9; then touch "$s.lock"; echo "$s"; exec cat >/dev/null; fi
  exec 9>&-; i=$((i + 1))
done
echo "NONE"'
me=$$
rssh "bash -c $(q "$CLAIM_SH") _ $(q "$BASE_NAME" "$SLOTS" "$TTL_DAYS")" \
  < <(while kill -0 "$me" 2>/dev/null && [ ! -e "$CLAIM.done" ]; do sleep 0.2; done) > "$CLAIM" 2>/dev/null & HOLD_PID=$!
NAME=
for _ in $(seq 150); do
  NAME=$(head -n1 "$CLAIM" 2>/dev/null || true)
  [ -n "$NAME" ] && break
  kill -0 "$HOLD_PID" 2>/dev/null || { NAME=$(head -n1 "$CLAIM" 2>/dev/null || true); break; }
  sleep 0.1
done
case "$NAME" in
  "") echo "offload.sh: could not claim a slot on $HOST (no answer from flock in 15s)" >&2; exit 97 ;;
  NONE) echo "offload.sh: all $SLOTS slots of $BASE_NAME on $HOST are busy (OFFLOAD_SLOTS raises the cap)" >&2; exit 97 ;;
esac
RDIR="offload/$NAME"   # relative to the remote $HOME

REFS=("$SHA:refs/offload/$NAME")
git -C "$TOPLEVEL" rev-parse -q --verify "$BASE_REF" >/dev/null && REFS+=("+$BASE_REF:$BASE_REF")
# The base ref is shared by every worktree's push, so two pushes at once can still race on ITS lock; that race is
# transient (both write the same value), so retry.
pushed=false
for try in 1 2 3 4 5; do
  if GIT_SSH_COMMAND="ssh $(q "${CM[@]}")" git -C "$TOPLEVEL" push -q -f "$HOST:offload/shared.git" "${REFS[@]}"; then
    pushed=true; break
  fi
  sleep "$try"
done
$pushed || { echo "offload.sh: git push to $HOST failed (5 tries)" >&2; exit 97; }

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
