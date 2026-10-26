#!/bin/bash
# Where an APK build's time goes: the PowOS app built twice with Gradle's --profile in android-app-dev's builder image
# (as build-app.sh's `make build` builds it: --no-daemon, the shared gradle-cache volume, build dirs in /tmp), inside
# the ship lock (~/.cache/powos-ship.lock, as tools/phone/ship-apk.sh takes it), and nothing published or installed:
# no APK is copied to android-app-dev/output.
#   run 1: a fresh container (its /tmp build dirs empty - what a build in a recreated builder pays)
#   run 2: the same container right after, nothing changed (the floor: startup + configuration + up-to-date checks)
# Prints each run's wall time and Gradle's own split (startup, settings, configuration, task execution) and its
# slowest tasks. Usage: targets/android/tools/profile-build.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
proj=/Projects${here#$HOME/Projects}/app
lock=$HOME/.cache/powos-ship.lock
until mkdir "$lock" 2>/dev/null; do
  echo "profile-build: waiting for $(cat "$lock/who" 2>/dev/null || echo another build)"; sleep 30
done
echo "profile-build (no install) pid $$ $(date +%H:%M:%S)" > "$lock/who"
trap 'rm -rf "$lock"' EXIT
uptime | sed 's/.*load/load/'
docker compose -f "$AAD/docker-compose.yml" run --rm --no-deps android-builder bash -c '
  set -e
  cd '"$proj"'
  mkdir -p ~/.android && cp /app/keystores/debug.keystore ~/.android/debug.keystore 2>/dev/null || true
  echo "sdk.dir=$ANDROID_SDK_ROOT" > local.properties
  [ -f app/version.properties ] || printf "versionCode=1\nversionName=profile\n" > app/version.properties
  mkdir -p ~/.gradle/init.d
  printf "%s\n" "gradle.allprojects { layout.buildDirectory.set(File(\"/tmp/gradle-build/\${rootProject.name}/\${project.name}\")) }" > ~/.gradle/init.d/redirect-builddir.gradle.kts
  for run in 1 2; do
    t0=$(date +%s)
    ./gradlew assembleDebug --no-daemon --profile -q > /tmp/build-$run.log 2>&1 || { tail -20 /tmp/build-$run.log; exit 1; }
    t1=$(date +%s)
    r=$(ls -t /tmp/gradle-build/*/*/reports/profile/*.html build/reports/profile/*.html 2>/dev/null | head -1)
    echo "== run $run: $((t1 - t0)) s wall"
    # The report: a summary table (startup, settings, loading, configuring, task execution) and per-task rows.
    sed -e "s/<[^>]*>/ /g" "$r" | tr -s " " | grep -E "^ ?(Total Build Time|Startup|Settings and buildSrc|Loading Projects|Configuring Projects|Artifact Transforms|Task Execution) " | head -8
    echo "-- slowest tasks"
    sed -e "s/<\/td>/|/g; s/<[^>]*>//g" "$r" | grep -E "^:[^|]*\|[0-9.]+s" | sort -t"|" -k2 -rn | head -8
  done'
