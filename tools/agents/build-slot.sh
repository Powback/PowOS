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
    # No pid yet = a holder between its mkdir and its pid write (microseconds, longer under load): live, not dead.
    # Reclaiming it let a third quick job steal a held slot (test-build-slot "third waits"). Only a pid-less lock
    # older than a minute (holder killed in that gap) is reclaimed.
    if [ -z "$p" ]; then
      [ -n "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ] || continue
      echo "build-slot: reclaimed $l (no pid for over a minute)" >&2
      rm -rf "$l" 2>/dev/null; continue 2
    fi
    # Said on stderr: a reclaim of a live holder's slot is the one way a lane admits one job too many.
    if ! kill -0 "$p" 2>/dev/null; then echo "build-slot: reclaimed $l (holder pid $p not running)" >&2; rm -rf "$l" 2>/dev/null; continue 2; fi
  done
  [ -z "$lock" ] || break
  if [ -z "$said" ]; then
    echo "build-slot: waiting for $lane slot (held by $(for l in $locks; do cat "$l/label" 2>/dev/null; done | paste -sd, -))" >&2
    said=1
  fi
  sleep "${BUILD_SLOT_POLL_S:-2}"
done
[ -z "$said" ] || echo "build-slot: got the $lane slot after $(($(date +%s) - t0))s" >&2
# Releasing the slot, and not leaving a container behind (2026-11-09: `angry_beaver`, a `./gradlew
# testDebugUnitTest` on the shared gradle-cache volume, ran 33+ min after its caller was gone, holding Gradle's
# journal lock so every other JVM test/ship failed). Callers wrap this in `perl -e 'alarm N; exec @ARGV'` or get
# stopped; SIGALRM/SIGTERM then killed this shell without running an EXIT trap (bash skips EXIT on an untrapped
# fatal signal) - the slot stayed locked until the pid-reuse check reclaimed it - and killing the docker CLI never
# stops its container. So: a `docker run` gets a container name (the caller's own --name, else a generated one),
# the command runs in the background with `wait` so a signal is handled at once, and every way out (normal exit,
# HUP/INT/TERM/ALRM) kills the CLI, `docker rm -f`s the container and removes the lock. SIGKILL can't be trapped;
# its lock is reclaimed by the dead-holder check above, its container is not.
cname=""; own_name=""
if [ "${1##*/}" = docker ] && [ "${2:-}" = run ]; then
  prev=""
  for a in "${@:3}"; do
    case $a in --name=*) cname=${a#--name=}; own_name=1; break ;; esac
    [ "$prev" = --name ] && { cname=$a; own_name=1; break; }
    prev=$a
  done
  if [ -z "$cname" ]; then
    tag=$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-40)
    cname="build-slot-$$-$tag"
    set -- "$1" run --name "$cname" "${@:3}"
  fi
fi
child=""
cleanup() {   # <on-signal>: kill the CLI, remove the container (a caller-named one only on a signal), free the slot
  [ -z "$child" ] || kill -TERM "$child" 2>/dev/null
  if [ -n "$cname" ] && { [ -n "$1" ] || [ -z "$own_name" ]; }; then docker rm -f "$cname" >/dev/null 2>&1; fi
  rm -rf "$lock"
}
on_signal() { trap - EXIT HUP INT TERM ALRM; cleanup 1; exit $((128 + $1)); }
trap 'cleanup ""' EXIT
trap 'on_signal 1' HUP; trap 'on_signal 2' INT; trap 'on_signal 15' TERM; trap 'on_signal 14' ALRM
# `0<&0`: an async command in a non-interactive shell otherwise gets /dev/null as stdin (docker run -i, pipes).
"$@" 0<&0 &
child=$!
wait "$child"; rc=$?
child=""
exit "$rc"
