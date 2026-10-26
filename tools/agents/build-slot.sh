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
set -uo pipefail
[ $# -ge 1 ] || { echo "build-slot.sh: usage: build-slot.sh <label> -- <command...>" >&2; exit 2; }
label=$1; shift
[ "${1:-}" = -- ] || { echo "build-slot.sh: expected -- after the label" >&2; exit 2; }
shift
[ $# -ge 1 ] || { echo "build-slot.sh: no command given after --" >&2; exit 2; }

lock="${XDG_CACHE_HOME:-$HOME/.cache}/powos-build-slot"
mkdir -p "$(dirname "$lock")"
t0=$(date +%s)
said=""
while :; do
  if mkdir "$lock" 2>/dev/null; then
    echo $$ > "$lock/pid"; echo "$label" > "$lock/label"
    break
  fi
  # A dead holder's slot (its process no longer running) is reclaimed instead of waited on forever.
  p=$(cat "$lock/pid" 2>/dev/null) || p=""
  if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then rm -rf "$lock" 2>/dev/null; continue; fi
  if [ -z "$said" ]; then
    echo "build-slot: waiting for build slot (held by $(cat "$lock/label" 2>/dev/null || echo "?"))" >&2
    said=1
  fi
  sleep "${BUILD_SLOT_POLL_S:-2}"
done
[ -z "$said" ] || echo "build-slot: got the slot after $(($(date +%s) - t0))s" >&2
trap 'rm -rf "$lock"' EXIT
"$@"
