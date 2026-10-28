#!/usr/bin/env bash
# One Mac-wide build slot: at most one heavy compile/build docker run on this Mac at a time, so their CPU
# doesn't pile up on each other. Root cause of a friction cluster (f30, f62, f66-69, f70): compile-check.sh,
# build-pkgs.sh, warm-builder.sh and the shell gate's page-boot run all spin CPU-heavy docker containers with
# no shared cap, so several at once push 1-min load past 20+; the gate's fixed READY_MS then times out
# ("not ready") and concurrent compile-check runs hit Gradle's own journal-cache lock timeout. This replaces
# both failure modes with queueing: a caller waits for the slot instead of racing for one and timing out.
#   build-slot.sh <label> -- <command...>
# Runs <command...> once the slot is free, holding it for the command's duration, and releases it after
# (success or failure) - exit code is the command's. A slot is a mkdir lock under $HOME/.cache (atomic,
# portable - the same pattern as shell/dev/gate.sh's own slots and targets/android/tools/warm-builder.sh's
# build_lock) holding its pid and label; a dead holder's slot is reclaimed. No fixed wait limit: it blocks
# until the slot is free, and prints who holds it once, not on every poll.
#
# Two lanes (f316), so a ~1 min quick check never queues behind a 10+ min package build:
#   heavy: ONE at a time (CPU/RAM). Lock dir powos-build-slot (the pre-lanes path, so a lock held by an older
#          version of this script still excludes new heavy jobs and is reclaimed the same way).
#   quick: BUILD_SLOT_QUICK_N (default 2) at a time. Lock dirs powos-build-slot-quick.<i>. Never looks at heavy.
# The lane comes from the label's first word (the lane table below); unknown names are heavy (the safe side).
# Override with BUILD_SLOT_LANE=quick|heavy. A quick job holding an OLD-version lock only delays heavy jobs.
set -uo pipefail
[ $# -ge 1 ] || { echo "build-slot.sh: usage: build-slot.sh <label> -- <command...>" >&2; exit 2; }
label=$1; shift
[ "${1:-}" = -- ] || { echo "build-slot.sh: expected -- after the label" >&2; exit 2; }
shift
[ $# -ge 1 ] || { echo "build-slot.sh: no command given after --" >&2; exit 2; }

# lane table: first word of the label -> lane
case "${BUILD_SLOT_LANE:-${label%% *}}" in
  quick|compile-check|lint|lints|gate|bindings-check|tsc|typecheck) lane=quick ;;
  *) lane=heavy ;;   # build-pkgs, warm-builder, apk, ship-apk, anything unknown
esac
base="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$base"
if [ "$lane" = quick ]; then
  n=${BUILD_SLOT_QUICK_N:-2}; case "$n" in ''|*[!0-9]*|0) n=2 ;; esac
  i=0; locks=""; while [ "$i" -lt "$n" ]; do locks="$locks $base/powos-build-slot-quick.$i"; i=$((i+1)); done
else
  locks="$base/powos-build-slot"
fi
t0=$(date +%s)
said=""
lock=""
while :; do
  for l in $locks; do
    if mkdir "$l" 2>/dev/null; then
      echo $$ > "$l/pid"; echo "$label" > "$l/label"
      lock=$l; break
    fi
    # A dead holder's slot (its process no longer running) is reclaimed instead of waited on forever.
    p=$(cat "$l/pid" 2>/dev/null) || p=""
    if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then rm -rf "$l" 2>/dev/null; continue 2; fi
  done
  [ -z "$lock" ] || break
  if [ -z "$said" ]; then
    echo "build-slot: waiting for $lane slot (held by $(for l in $locks; do cat "$l/label" 2>/dev/null; done | paste -sd, -))" >&2
    said=1
  fi
  sleep "${BUILD_SLOT_POLL_S:-2}"
done
[ -z "$said" ] || echo "build-slot: got the $lane slot after $(($(date +%s) - t0))s" >&2
trap 'rm -rf "$lock"' EXIT
"$@"
