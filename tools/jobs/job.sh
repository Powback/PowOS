#!/usr/bin/env bash
# tools/jobs/job.sh - PowOS's heavy arch-neutral jobs (tools/jobs/compose.yml: tier1, gate, apk) as Compose services,
# run on another Docker engine through a plain Docker context. Sourced by the launchers (tools/agents/tier1.sh,
# shell/dev/gate.sh, targets/android/build-app.sh); `job.sh context` prints the machine a job would run on.
#
# WHY: the Mac's Colima VM runs at load 30-60 on 14 vCPUs while .58 (Ryzen, 32 threads) idles at load 2; the gate's
# scenes and the ship's tests timed out on the Mac only. Native Docker only: a context + Compose, nothing installed
# on the far side - each job's image bakes the source (build:), so it runs on any engine that can build it.
#
# Machine: POW_JOB_CONTEXT (read here only; default pow58) - a Docker context name. It must answer within 5 s, else
# the job runs on the hub (this shell's current context) and says so. Set it to the hub's context (colima) to force
# the hub. A fleet scheduler will set it later; this file stays the one place that reads it.
#
# Images are tagged powos-jobs-<svc>:<checkout>; a rebuild removes the previous tag's image when nothing else uses it
# (its own image only - shared base layers, the build cache and every other image stay: nothing is pruned).
# Builds use the engine's own builder (DOCKER_BUILDKIT=0): .58's buildx builder is a docker-container one, which would
# send every finished image back through this machine to load it (GBs for the APK builder).
JOBS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JOBS_COMPOSE=$JOBS_DIR/compose.yml
JOB_CTX="" JOB_PROJECT="" JOB_TAG=""

# job_context: sets JOB_CTX (once per process tree: exported as JOB_CTX_RESOLVED) and says which machine runs.
job_context() {
  [ -z "$JOB_CTX" ] || return 0
  if [ -n "${JOB_CTX_RESOLVED:-}" ]; then JOB_CTX=$JOB_CTX_RESOLVED; return 0; fi
  local want=${POW_JOB_CONTEXT:-pow58} hub
  hub=$(docker context show 2>/dev/null || echo default)
  if [ "$want" = "$hub" ] || perl -e 'alarm 5; exec @ARGV' docker --context "$want" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    JOB_CTX=$want
  else
    echo "job: $want did not answer within 5 s - running on the hub ($hub)" >&2
    JOB_CTX=$hub
  fi
  export JOB_CTX_RESOLVED=$JOB_CTX
  echo "job: runs on $JOB_CTX" >&2
}

# job_init SVC: the run's compose project (unique per run, so parallel runs never share containers) and image tag.
job_init() {
  job_context
  local top; top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  JOB_TAG=$(basename "$top" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.\n-' _ | tr -d '\n' | cut -c1-60)
  JOB_PROJECT=pj-$1-$JOB_TAG-$$
  JOB_PROJECT=$(printf %s "$JOB_PROJECT" | tr 'A-Z.' 'a-z_')
}

job_dc() {
  DOCKER_BUILDKIT=0 POW_JOB_TAG=$JOB_TAG POW_JOB_SRC=${JOB_SRC:-/nonexistent} \
    docker --context "$JOB_CTX" compose -f "$JOBS_COMPOSE" -p "$JOB_PROJECT" "$@"
}
job_docker() { docker --context "$JOB_CTX" "$@"; }

# job_stage DIR [PATHSPEC...] [-- EXTRA...]: DIR = this checkout's source as it is on disk - tracked, modified and
# untracked files not gitignored (the working state, not HEAD), under PATHSPECs (none: all), plus EXTRA paths
# (gitignored inputs a job needs). Never node_modules.
job_stage() {
  local dest=$1 top p specs=() extras=(); shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do specs+=("$1"); shift; done
  [ $# -eq 0 ] || { shift; extras=("$@"); }
  top=$(git rev-parse --show-toplevel) || return 2
  rm -rf "$dest" && mkdir -p "$dest"
  (cd "$top" && git ls-files -z -co --exclude-standard -- ${specs[@]+"${specs[@]}"} |
    perl -0ne 'chomp; print "$_\0" if (-e $_ || -l $_) && !m{(^|/)node_modules(/|$)} && !m{(^|/)\.DS_Store$}' |
    COPYFILE_DISABLE=1 tar --null -T - -cf -) | tar -xf - -C "$dest" || return 2
  for p in ${extras[@]+"${extras[@]}"}; do
    [ -e "$top/$p" ] || continue
    (cd "$top" && COPYFILE_DISABLE=1 tar -cf - "$p") | tar -xf - -C "$dest" || return 2
  done
}

# job_build SVC SRCDIR: builds SVC's image from SRCDIR (its Dockerfile: tools/jobs/SVC.Dockerfile, copied in as
# .jobs/Dockerfile) on JOB_CTX. Prints the build log only when it fails.
job_build() {
  local svc=$1 old new log rc=0
  JOB_SRC=$2
  mkdir -p "$JOB_SRC/.jobs" && cp "$JOBS_DIR/$svc.Dockerfile" "$JOB_SRC/.jobs/Dockerfile"
  old=$(job_docker image inspect -f '{{.Id}}' "powos-jobs-$svc:$JOB_TAG" 2>/dev/null) || old=""
  log=$(mktemp)
  job_dc build ${JOB_NO_CACHE:+--no-cache} "$svc" > "$log" 2>&1 || rc=$?
  [ $rc = 0 ] || { tail -40 "$log" >&2; rm -f "$log"; echo "job: building $svc on $JOB_CTX failed" >&2; return $rc; }
  rm -f "$log"
  new=$(job_docker image inspect -f '{{.Id}}' "powos-jobs-$svc:$JOB_TAG" 2>/dev/null) || new=""
  # The previous image of this tag: its own top layers only (in use by another run: kept).
  [ -z "$old" ] || [ "$old" = "$new" ] || job_docker rmi "$old" >/dev/null 2>&1 || true
}

# job_run SVC [compose-run args...] [-- CMD...]: one run of SVC's built image (--rm); its output here, its status ours.
job_run() {
  local svc=$1 opts=(); shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  # stdin from /dev/null: `compose run -T` still reads the caller's stdin, which ate the rest of gate-rerun.sh's
  # `while read ... <<< names` list (only the first failed scene was rerun, and the gate said pass with 2 FAILs).
  job_dc run --rm --no-deps -T ${opts[@]+"${opts[@]}"} "$svc" "$@" < /dev/null 2>&1 |
    grep --line-buffered -v -E '^ *(Container|Network|Volume) .*(Creat|Start|Remov|Stop)|level=warning msg="volume'
  return "${PIPESTATUS[0]}"
}

# job_cleanup: every container of this run's project goes (an interrupted run must not leave a gradle/chrome container).
job_cleanup() {
  [ -n "$JOB_PROJECT" ] && [ -n "$JOB_CTX" ] || return 0
  local ids
  ids=$(perl -e 'alarm 30; exec @ARGV' docker --context "$JOB_CTX" ps -aq --filter "label=com.docker.compose.project=$JOB_PROJECT" 2>/dev/null) || ids=""
  # shellcheck disable=SC2086
  [ -z "$ids" ] || perl -e 'alarm 60; exec @ARGV' docker --context "$JOB_CTX" rm -f $ids >/dev/null 2>&1 || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    context) job_context; echo "$JOB_CTX" ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
fi
