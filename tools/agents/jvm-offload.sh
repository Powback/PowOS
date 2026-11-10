#!/usr/bin/env bash
# tools/agents/jvm-offload.sh [gradle task...] — run the Android app's JVM unit tests (default
# :app:testDebugUnitTest) as the apk job of tools/jobs/compose.yml (tools/jobs/job.sh): the same image apk-job.sh
# builds (targets/android/app + shell + PowTerm's java, working state), on the Docker context POW_JOB_CONTEXT names
# (default pow58: .58; not answering within 5 s -> the hub, said so), the job's Gradle home volume, its cpus cap.
#
# WHY: the Mac at load 40-60 times the ship's JVM step out (rc=124); .58 runs it natively on amd64.
# Exit: gradle's rc; 2 = staging or the image build failed.
#
#   tools/agents/jvm-offload.sh                      # from any directory of a PowOS checkout
#   tools/agents/jvm-offload.sh :app:testDebugUnitTest :owl:test

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP=$(git rev-parse --show-toplevel)
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
[ $# -gt 0 ] || set -- :app:testDebugUnitTest
cd "$TOP"
. "$HERE/../jobs/job.sh"
t0=$(date +%s)
job_init jvm
src=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-jobs-src.XXXXXX")
trap 'job_cleanup; rm -rf "$src"' EXIT
trap 'exit 130' INT TERM HUP
# PowTerm's terminal glue is compiled into the app from android-app-dev's repo (app/build.gradle.kts, POWTERM_SRC).
job_stage "$src" targets/android/app shell -- targets/android/app/app/bundled-apps targets/android/app/app/shell-build.txt &&
  mkdir -p "$src/_powterm" && (cd "$AAD/projects/powterm/app/src/main/java" && COPYFILE_DISABLE=1 tar -cf - .) | tar -xf - -C "$src/_powterm" ||
  { echo "jvm-offload.sh: staging the source failed" >&2; exit 2; }
job_build apk "$src" || exit 2
set +e
job_run apk -- bash -c 'echo "sdk.dir=$ANDROID_SDK_ROOT" > local.properties
  printf "versionCode=%s\nversionName=%s\n" "$VERSION_CODE" "$VERSION_NAME" > app/version.properties
  exec ./gradlew --no-daemon -q "$@"' _ "$@"
rc=$?
echo "jvm-offload.sh: exit $rc on $JOB_CTX in $(( $(date +%s) - t0 )) s" >&2
exit $rc
