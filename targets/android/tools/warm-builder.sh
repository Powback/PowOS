#!/bin/bash
# The PowOS app's warm Gradle builder (unit units/mac/gradle-warm-mac.json): one long-lived container,
# powos-gradle-warm, from android-app-dev's builder image, whose Gradle daemon stays up between builds - no JVM, Gradle
# or Kotlin daemon start, no configuration and no re-compiling of what didn't change for each APK. build-app.sh uses
# it when it's up and answers, and android-app-dev's own cold `make build` otherwise (the other projects there keep
# that path; this one has its own container, Gradle home and build dirs).
#   warm-builder.sh start      up (if not), then a no-op `gradle --version` through the daemon
#   warm-builder.sh build DIR  build the Gradle project at DIR (a /Projects/... path) and publish it as build-gradle.sh
#                              does: android-app-dev/output/<name>.apk + .ver + .pkg (name: $PROJECT, default powos)
#                              PUBLISH=0: build only (a timing run), nothing written to output/
#   warm-builder.sh healthy    exit 0 when it's up and answers within 10 s
#   warm-builder.sh stop       remove it (its Gradle home volume stays: `docker volume rm powos-gradle-warm` drops it)
# Limits: 8 GB memory, 6 CPUs (docker); the daemon exits after 3 h without a build (org.gradle.daemon.idletimeout),
# and the container after 6 h without one (its own idle loop) - the next build-app.sh starts it again.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
NAME=powos-gradle-warm
IMAGE=android-app-dev-android-builder:latest
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
IDLE_H=${WARM_IDLE_HOURS:-6}

healthy() { docker exec "$NAME" true >/dev/null 2>&1; }

start() {
  # Stopped (its idle end, a Colima restart): started again as it was - its build dirs and the SDK parts Gradle
  # installed (CMake) are in it.
  healthy || { docker start "$NAME" >/dev/null 2>&1 && healthy; } || true
  if ! healthy; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # The idle loop: /tmp/last-build is touched by each build; IDLE_H hours without one, the container ends itself.
    docker run -d --name "$NAME" --memory 8g --cpus 6 --label powos.unit=gradle-warm-mac \
      -v powos-gradle-warm:/root/.gradle -v android-gradle-cache:/seed:ro -v "${WARM_KEYSTORES:-android-keystores}":/app/keystores:ro \
      -v "$HOME/Projects:/Projects" -v "$AAD/output:/app/output" -v "$AAD/scripts:/app/scripts:ro" \
      -e ANDROID_SDK_ROOT=/opt/android-sdk --entrypoint bash "$IMAGE" -c '
        touch /tmp/last-build
        while [ $(( $(date +%s) - $(stat -c %Y /tmp/last-build) )) -lt '"$((IDLE_H * 3600))"' ]; do sleep 300; done' >/dev/null
    docker exec "$NAME" bash -c '
      # A new Gradle home: seeded once from the cold builder'"'"'s (downloaded dependencies and Gradle distributions), so
      # the first warm build downloads nothing.
      [ -d ~/.gradle/caches/modules-2 ] || { mkdir -p ~/.gradle/caches; cp -a /seed/caches/modules-2 ~/.gradle/caches/ 2>/dev/null || true; cp -a /seed/wrapper ~/.gradle/ 2>/dev/null || true; }
      command -v rsync >/dev/null || { apt-get update -qq && apt-get install -y -qq rsync; } >/dev/null 2>&1
      mkdir -p ~/.gradle/init.d ~/.android
      printf "%s\n" "org.gradle.daemon.idletimeout=10800000" "org.gradle.caching=true" "org.gradle.configuration-cache=true" > ~/.gradle/gradle.properties
      printf "%s\n" "gradle.allprojects { layout.buildDirectory.set(File(\"/tmp/gradle-build/\${rootProject.name}/\${project.name}\")) }" > ~/.gradle/init.d/redirect-builddir.gradle.kts
      cp /app/keystores/debug.keystore ~/.android/debug.keystore'
  fi
}

# One build at a time: every build mirrors into the same /work and Gradle writes the same /tmp/gradle-build, so the
# emulator lane's build (tools/emu/emu.sh, PUBLISH=0) and a ship's would mix. A held lock is waited for (its holder
# dead: taken over), up to 20 min.
build_lock() {
  local l=$HOME/.cache/powos-warm-build.lock i
  mkdir -p "$HOME/.cache"
  for i in $(seq 1200); do
    if mkdir "$l" 2>/dev/null; then echo $$ > "$l/pid"; trap 'rm -rf "$HOME/.cache/powos-warm-build.lock"' EXIT; return 0; fi
    kill -0 "$(cat "$l/pid" 2>/dev/null)" 2>/dev/null || { sleep 1; kill -0 "$(cat "$l/pid" 2>/dev/null)" 2>/dev/null || rm -rf "$l"; continue; }
    [ "$i" = 1 ] && echo "warm-builder: another build runs (pid $(cat "$l/pid" 2>/dev/null)) - waiting" >&2
    sleep 1
  done
  echo "warm-builder: the build lock stayed held for 20 min" >&2; return 1
}

build() {
  local dir=$1 project=${PROJECT:-powos} publish=${PUBLISH:-1}
  build_lock
  start
  # The Mac-wide build slot (tools/agents/build-slot.sh): this container's gradle build is one of the heavy
  # CPU-bound builds that piled up concurrently with compile-check/build-pkgs/the gate and starved them
  # (f30, f62/f66-69). build_lock above already keeps warm-builder's OWN builds to one at a time; this also
  # keeps it from running alongside everyone else's.
  "$REPO/tools/agents/build-slot.sh" "warm-builder $dir" -- \
  docker exec -e PROJECT="$project" -e PUBLISH="$publish" "$NAME" bash -c '
    set -euo pipefail
    touch /tmp/last-build
    # One fixed place for every checkout: the app and the shell it packs, mirrored into /work with rsync (changed files
    # only, deletions too; the Gradle state under app/.gradle and the build dirs kept). Gradle keys its incremental
    # state and configuration cache by path, so builds from different worktrees (each agent ships from its own) reuse
    # them instead of starting over in a new directory each time.
    src="'"$dir"'"; repo=$(cd "$src/../../.." && pwd)
    mkdir -p /work/PowOS/targets/android/app /work/PowOS/shell
    rsync -a --delete --exclude=/.gradle --exclude=build/ --exclude=/local.properties --exclude=/app/version.properties "$repo/targets/android/app/" /work/PowOS/targets/android/app/
    rsync -a --delete --exclude=/node_modules --exclude=/dev "$repo/shell/" /work/PowOS/shell/
    cd /work/PowOS/targets/android/app
    echo "sdk.dir=$ANDROID_SDK_ROOT" > local.properties
    # As build-gradle.sh: the version from the time (PowApps compares by it), in the gitignored version.properties.
    code=$(( $(date +%s) / 60 )); printf "versionCode=%s\nversionName=%s\n" "$code" "$(date +%Y.%m.%d-%H%M)" > app/version.properties
    start=$(mktemp)
    ./gradlew assembleDebug --daemon --stacktrace -q
    root=$(cat settings.gradle.kts settings.gradle 2>/dev/null | sed -n "s/^ *rootProject\.name *= *\"\(.*\)\".*/\1/p" | head -1 || true)
    apk=$(find "/tmp/gradle-build/$root" -path "*/outputs/apk/debug/*.apk" -newer "$start" 2>/dev/null | head -1)
    [ -n "$apk" ] || apk=$(find "/tmp/gradle-build/$root" -path "*/outputs/apk/debug/*.apk" 2>/dev/null | head -1)
    [ -n "$apk" ] || { echo "warm-builder: no APK in /tmp/gradle-build/$root" >&2; exit 1; }
    [ "$PUBLISH" = 1 ] || { echo "warm-builder: built $apk (not published: PUBLISH=0)"; exit 0; }
    cp "$apk" "/app/output/$PROJECT.apk"
    echo "$code" > "/app/output/$PROJECT.ver"
    cd /app && bash scripts/pkg-sidecars.sh "output/$PROJECT.apk" >/dev/null || true
    echo "warm-builder: output/$PROJECT.apk (version code $code)"'
}

case "${1:-}" in
  start) start; docker exec "$NAME" bash -c 'cd /tmp && echo ok' ;;
  build) build "${2:?a /Projects/... Gradle project dir}" ;;
  healthy) healthy ;;
  stop) docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed $NAME" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
