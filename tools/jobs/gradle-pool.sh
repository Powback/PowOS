#!/usr/bin/env bash
# tools/jobs/gradle-pool.sh - the Android app's Gradle tasks (the compile check, the JVM unit tests) on WARM Gradle
# daemons on the job machine (POW_JOB_CONTEXT, default .58): the gradle-pool service of tools/jobs/compose.yml, one
# long-lived container shared by every worktree.
#
#   gradle-pool.sh run TASK...   sync this checkout's working state into the pool (its own /work/<checkout>), run
#                                ./gradlew TASK... there through a warm daemon, print gradle's output + "gradle-exit=N"
#   gradle-pool.sh status        the pool's container, its daemons and the builds running
#   gradle-pool.sh stop          remove the container (its volumes stay: the Gradle home and the per-worktree builds)
#
# WHY (11-25): Kotlin compile checks were 17% of agent tool time, queued one at a time on the Mac warm builder's
# lock (targets/android/tools/warm-builder.sh, up to 20 min); jvm-offload.sh built an image and started a cold
# --no-daemon Gradle per run. Here: no image build per run (the pool's image is the apk job's SDK, built once), each
# worktree keeps its incremental state, POOL_SLOTS (3) builds run at once - Gradle starts another daemon when the
# idle ones are busy - and a worktree's own runs queue on its own lock only. The warm builder stays for ship APKs.
# Waits are printed as "gradle-pool: slot wait N s" (tools/agents/efficiency.py counts them as queue wait).
#
# Exit: gradle's; 3 = the pool is unavailable (the job machine doesn't answer, or the pool didn't start) - the caller
# falls back (compile-check.sh: the warm builder; jvm-offload.sh: its one-shot apk job).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/job.sh"
NAME=powos-gradle-pool
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
SLOTS=${POOL_SLOTS:-3}

pool_ctx() {
  [ "${POW_JOB_CONTEXT:-}" != hub ] || { echo "gradle-pool: POW_JOB_CONTEXT=hub - no pool there (the warm builder is the hub's)" >&2; return 3; }
  JOB_NO_FALLBACK=1 JOB_WAIT_S=0 job_context 2>/dev/null
  [ -z "$JOB_ON_HUB" ] || { echo "gradle-pool: ${POW_JOB_CONTEXT:-pow58} does not answer" >&2; return 3; }
}
pexec() { job_docker exec "$@"; }
healthy() { job_bounded 20 docker --context "$JOB_CTX" exec "$NAME" test -f /root/.pool-ready >/dev/null 2>&1; }

# ensure: the pool up and set up, at most one starter at a time (a mkdir lock on this Mac).
ensure() {
  healthy && return 0
  local l=${XDG_CACHE_HOME:-$HOME/.cache}/powos-gradle-pool.start ctx
  mkdir -p "$(dirname "$l")"
  for _ in $(seq 600); do mkdir "$l" 2>/dev/null && break
    kill -0 "$(cat "$l/pid" 2>/dev/null)" 2>/dev/null || { sleep 1; kill -0 "$(cat "$l/pid" 2>/dev/null)" 2>/dev/null || rm -rf "$l"; }
    healthy && return 0; sleep 1; done
  echo $$ > "$l/pid"
  healthy && { rm -rf "$l"; return 0; }
  echo "gradle-pool: starting the pool on $JOB_CTX (once; later runs reuse it)" >&2
  # The image: the apk job's Dockerfile over an empty source (its SDK layers are already cached on the machine).
  ctx=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gradle-pool-ctx.XXXXXX"); touch "$ctx/.pool"
  # job.sh globals: the image tag and compose project job_build uses (and job_down/cleanup after it).
  # shellcheck disable=SC2034
  JOB_TAG=gradle-pool JOB_PROJECT=powos-gradle-pool
  if ! job_build apk "$ctx"; then rm -rf "$ctx" "$l"; return 3; fi
  rm -rf "$ctx"
  job_dc up -d --no-build gradle-pool >/dev/null 2>&1 || { job_dc up -d --no-build gradle-pool >&2; rm -rf "$l"; return 3; }
  # Once per Gradle home: seeded from the apk job's (dependencies + wrapper distributions: the first build downloads
  # nothing); daemons idle out after the container's own idle window; rsync for the per-worktree sync.
  pexec "$NAME" bash -c '
    set -e
    command -v rsync >/dev/null || { apt-get update -qq && apt-get install -y -qq rsync util-linux; } >/dev/null 2>&1
    if [ ! -d ~/.gradle/caches/modules-2 ] && [ -d /seed/caches/modules-2 ]; then
      mkdir -p ~/.gradle/caches; cp -a /seed/caches/modules-2 ~/.gradle/caches/ 2>/dev/null || true
      cp -a /seed/wrapper ~/.gradle/ 2>/dev/null || true
    fi
    printf "%s\n" "org.gradle.daemon.idletimeout=7200000" "org.gradle.caching=true" > ~/.gradle/gradle.properties
    touch /root/.pool-ready' >&2 || { rm -rf "$l"; return 3; }
  rm -rf "$l"
  healthy || return 3
}

# stage_src DIR: this checkout's working state (job.sh's job_stage set: the app, shell, the sources its tests read, the
# gitignored inputs prep-app.sh stages, PowTerm's java) into DIR. run() streams it into the pool, where it is rsynced
# into /work/<checkout> keeping Gradle's own state (.gradle, build/) - unchanged files keep their mtimes, so Gradle's
# snapshots stay warm.
stage_src() {
  local src=$1 top
  top=$(git rev-parse --show-toplevel) || return 2
  ( cd "$top" && job_stage "$src" targets/android/app shell targets/android/pkgs/kwin targets/android/session targets/android/oplus-hook \
      -- targets/android/app/engine/powstream-native targets/android/app/app/bundled-apps targets/android/app/app/shell-build.txt ) &&
    mkdir -p "$src/_powterm" && { [ ! -d "$AAD/projects/powterm/app/src/main/java" ] ||
      (cd "$AAD/projects/powterm/app/src/main/java" && COPYFILE_DISABLE=1 tar -cf - .) | tar -xf - -C "$src/_powterm"; } ||
    { echo "gradle-pool: staging the source failed" >&2; return 2; }
}

run() {
  [ $# -gt 0 ] || { echo "gradle-pool: run TASK..." >&2; return 2; }
  pool_ctx || return 3
  ensure || { echo "gradle-pool: the pool did not start on $JOB_CTX" >&2; return 3; }
  local top tag t0 rc src
  top=$(git rev-parse --show-toplevel) || return 2
  tag=$(basename "$top" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.\n-' _ | tr -d '\n' | cut -c1-60)
  t0=$(date +%s)
  src=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gradle-pool-src.XXXXXX")
  stage_src "$src" || { rm -rf "$src"; return 3; }
  # In the pool, one script: this worktree's lock (its /work dir: a second run of it waits, never syncs under a running
  # build), the sync, then one of POOL_SLOTS slots for the build. Both waits printed.
  (cd "$src" && COPYFILE_DISABLE=1 tar --no-xattrs -czf - .) | pexec -i -e TAG="$tag" -e SLOTS="$SLOTS" -e RUN=$$ "$NAME" bash -c '
    touch /tmp/last-run
    exec 8>"/tmp/tree-$TAG.lock"; w0=$(date +%s); flock 8; tw=$(( $(date +%s) - w0 ))
    st="/stage/$TAG.$RUN"; rm -rf "$st"; mkdir -p "$st" "/work/$TAG"
    tar --warning=no-unknown-keyword -xzf - -C "$st" || { echo "gradle-pool: receiving the source failed" >&2; exit 3; }
    rsync -a --delete --exclude=/targets/android/app/.gradle --exclude=build/ --exclude=/targets/android/app/local.properties \
      --exclude=/targets/android/app/app/version.properties "$st/" "/work/$TAG/" || exit 3
    rm -rf "$st"
    w1=$(date +%s); got=""; until [ -n "$got" ]; do
      for i in $(seq 0 $((SLOTS - 1))); do exec 9>"/tmp/slot.$i.lock"; flock -n 9 && { got=$i; break; }; exec 9>&-; done
      [ -n "$got" ] || { [ -n "${said:-}" ] || echo "gradle-pool: all $SLOTS slots busy - waiting" >&2; said=1; sleep 1; }
    done
    echo "gradle-pool: slot wait $(( tw + $(date +%s) - w1 )) s" >&2
    cd "/work/$TAG/targets/android/app"
    echo "sdk.dir=$ANDROID_SDK_ROOT" > local.properties
    [ -f app/version.properties ] || printf "versionCode=1\nversionName=check\n" > app/version.properties
    POWTERM_SRC="/work/$TAG/_powterm" ./gradlew --daemon -q "$@" 2>&1; rc=$?
    touch /tmp/last-run
    echo "gradle-exit=$rc"; exit $rc' _ "$@"
  rc=${PIPESTATUS[1]}; rm -rf "$src"
  echo "gradle-pool: $* on $JOB_CTX: exit $rc in $(( $(date +%s) - t0 )) s" >&2
  return $rc
}

case "${1:-}" in
  run) shift; [ "${1:-}" != -- ] || shift; run "$@" ;;
  status) pool_ctx || exit 3
    pexec "$NAME" bash -c 'echo "pool up; daemons:"; ps -eo pid,etime,rss,args | grep -E "[G]radleDaemon|[K]otlinCompileDaemon" | cut -c1-140; ls /work' ;;
  stop) pool_ctx || exit 3; job_docker rm -f "$NAME" >/dev/null && echo "removed $NAME on $JOB_CTX" ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
