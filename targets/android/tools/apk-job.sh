#!/bin/bash
# targets/android/tools/apk-job.sh OUTDIR - the PowOS APK built by the apk job (tools/jobs/compose.yml) on the Docker
# context POW_JOB_CONTEXT names (default pow58), over this checkout's targets/android/app + shell (working state) and
# the gitignored inputs build-app.sh stages (app/bundled-apps, app/shell-build.txt) + PowTerm's java
# (android-app-dev/projects/powterm). The unsigned APK comes back with `docker compose cp` and is signed on the hub
# with the persistent debug key (the android-keystores volume, as android-app-dev's build-gradle.sh) - the key never
# leaves the hub. Writes OUTDIR/powos.apk + powos.ver + powos.pkg (pkg-sidecars.sh). OUTDIR must be under $HOME
# (the hub's VM mounts only that). build-app.sh calls it with android-app-dev/output; a scratch OUTDIR builds without
# publishing.
set -euo pipefail
OUT=$(cd "${1:?OUTDIR}" && pwd)
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
IMG=android-app-dev-android-builder:latest
cd "$ROOT"
. "$ROOT/tools/jobs/job.sh"
t0=$(date +%s)
job_init apk
src=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-jobs-src.XXXXXX")
trap 'job_cleanup; rm -rf "$src"' EXIT
trap 'exit 130' INT TERM HUP
job_stage "$src" targets/android/app shell -- targets/android/app/app/bundled-apps targets/android/app/app/shell-build.txt &&
  mkdir -p "$src/_powterm" && (cd "$AAD/projects/powterm/app/src/main/java" && COPYFILE_DISABLE=1 tar -cf - .) | tar -xf - -C "$src/_powterm" ||
  { echo "apk-job: staging the source failed" >&2; exit 1; }
job_build apk "$src" || exit 1
code=$(( $(date +%s) / 60 ))
export VERSION_CODE=$code VERSION_NAME=$(date +%Y.%m.%d-%H%M)
echo "apk-job: building on $JOB_CTX (version code $code)"
# `up`, not `run`: the service's container stays after it exits, so `compose cp` can take the APK out of it.
set +e
job_dc up --no-deps --no-log-prefix --abort-on-container-exit --exit-code-from apk apk < /dev/null 2>&1 |
  grep -v -E '^ *(Container|Network|Volume|Attaching|apk-1 exited)|level=warning msg="volume'
rc=${PIPESTATUS[0]}
set -e
[ "$rc" = 0 ] || { echo "apk-job: the build failed on $JOB_CTX (exit $rc)" >&2; exit 1; }
tb=$(date +%s)
rm -f "$OUT/.powos-unsigned.apk"
job_dc cp apk:/out/powos.apk "$OUT/.powos-unsigned.apk" >/dev/null ||
  { echo "apk-job: copying the APK back from $JOB_CTX failed" >&2; exit 1; }
job_dc rm -f apk >/dev/null 2>&1 || true
# On the hub (this shell's context), never on the job's machine: the key stays here.
docker run --rm -v android-keystores:/app/keystores:ro -v "$OUT:/app/output" -v "$AAD/scripts:/app/scripts:ro" -w /app \
  --entrypoint bash "$IMG" -c '
    set -e
    apksigner sign --ks /app/keystores/debug.keystore --ks-pass pass:android --key-pass pass:android \
      --ks-key-alias androiddebugkey --out output/powos.apk.tmp output/.powos-unsigned.apk
    mv output/powos.apk.tmp output/powos.apk && rm -f output/.powos-unsigned.apk output/powos.apk.tmp.idsig
    bash scripts/pkg-sidecars.sh output/powos.apk >/dev/null || true' || { echo "apk-job: signing on the hub failed" >&2; exit 1; }
echo "$code" > "$OUT/powos.ver"
echo "apk-job: $OUT/powos.apk (version code $code) - built on $JOB_CTX in $(( tb - t0 )) s, signed here in $(( $(date +%s) - tb )) s"
