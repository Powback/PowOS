#!/usr/bin/env bash
# tools/jobs/docker-sibling.sh - `docker` inside the tier1 job (tools/jobs/tier1.Dockerfile installs it as
# /usr/local/bin/docker, ahead of the real CLI in /usr/bin). The job reaches its machine's own engine through the
# socket compose.yml gives it (DOCKER_HOST=unix:///run/engine.sock: .58's rootless podman, or the hub's dockerd), so
# a container a test starts is a SIBLING of the job: a bind mount `-v /src/...:/x` would name a path on the machine,
# not in the job (the source is baked into the job's image; no such path exists there).
#
# HACK: so `docker run` with bind mounts is emulated - create the container, copy each bind source into it at its
# target (docker cp: a tar over the API), start it attached, wait, copy rw targets back to their sources, remove it if
# --rm. Named volumes and every other command pass straight through. The tests that need an engine (complexity's
# detekt/clippy, loopback-unix, publish-repo) run unchanged this way. Real fix: a fleet job runner that gives a job a
# workspace on the machine's disk (a path both the job and its siblings mount at the same place), then plain -v works
# and this file goes. Registry: docs/REMOTE-POWOS.md section 4.
set -uo pipefail
REAL=${DOCKER_REAL:-/usr/bin/docker}
[ "${1:-}" = run ] || exec "$REAL" "$@"
shift
# docker run's options that take a value (the next argument); anything else starting with - is a flag.
takes_value() {
  case $1 in
    -e|--env|--env-file|-w|--workdir|--entrypoint|--platform|--cpus|--memory|-m|--memory-swap|-u|--user|--security-opt|\
    --name|-l|--label|--network|--net|-p|--publish|--shm-size|--cpu-shares|--cpuset-cpus|--stop-timeout|--mount|--tmpfs|\
    --add-host|-h|--hostname|--ulimit|--device|--cap-add|--cap-drop|--pull|--gpus|--log-driver|--log-opt|--volumes-from|\
    --ipc|--pid|--group-add|--cidfile|--restart|--stop-signal|--pids-limit|--userns|--uts|--init-path) return 0 ;;
  esac
  return 1
}
opts=() binds=() rm=0 detach=0 interactive=0
while [ $# -gt 0 ]; do
  spec=""
  case $1 in
    -v|--volume) spec=$2; shift 2 ;;
    -v=*|--volume=*) spec=${1#*=}; shift ;;
    --rm) rm=1; shift; continue ;;
    -d|--detach) detach=1; shift; continue ;;
    -i|--interactive) interactive=1; opts+=("$1"); shift; continue ;;
    -it|-ti) interactive=1; opts+=(-i -t); shift; continue ;;
    --) shift; break ;;
    -*=*) opts+=("$1"); shift; continue ;;
    -*) if takes_value "$1"; then opts+=("$1" "$2"); shift 2; else opts+=("$1"); shift; fi; continue ;;
    *) break ;;
  esac
  case $spec in
    /*) binds+=("$spec") ;;
    *) opts+=(-v "$spec") ;;
  esac
done
# No bind mount: the run as asked.
if [ ${#binds[@]} = 0 ]; then
  exec "$REAL" run ${opts[@]+"${opts[@]}"} $([ $rm = 1 ] && echo --rm) $([ $detach = 1 ] && echo -d) "$@"
fi
cid=$("$REAL" create ${opts[@]+"${opts[@]}"} "$@") || exit 125
trap '"$REAL" rm -f "$cid" >/dev/null 2>&1; exit 130' INT TERM HUP
# Each bind's source into the container at its target: a tar of SRC renamed to TARGET, unpacked at /.
for b in "${binds[@]}"; do
  IFS=: read -r src dst _ <<< "$b"
  [ -e "$src" ] || mkdir -p "$src"
  d=${dst#/}
  if [ -d "$src" ]; then tar -C "$src" -cf - --transform "s,^\.,$d,S" .
  else tar -C "$(dirname "$src")" -cf - --transform "s,^$(basename "$src")\$,$d,S" "$(basename "$src")"; fi |
    "$REAL" cp - "$cid:/" || { echo "docker-sibling: copying $src into the container failed" >&2; "$REAL" rm -f "$cid" >/dev/null 2>&1; exit 125; }
done
if [ $detach = 1 ]; then "$REAL" start "$cid" >/dev/null && echo "$cid"; exit; fi
"$REAL" start -a $([ $interactive = 1 ] && echo -i) "$cid"
rc=$("$REAL" wait "$cid" 2>/dev/null) || rc=125
# rw targets back to their sources.
for b in "${binds[@]}"; do
  IFS=: read -r src dst mode <<< "$b"
  case ",$mode," in *,ro,*) continue ;; esac
  if [ -d "$src" ]; then "$REAL" cp "$cid:$dst/." "$src/"; else "$REAL" cp "$cid:$dst" "$src"; fi ||
    echo "docker-sibling: copying $dst back to $src failed" >&2
done
[ $rm = 0 ] || "$REAL" rm -f "$cid" >/dev/null 2>&1
exit "${rc:-125}"
