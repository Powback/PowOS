#!/usr/bin/env bash
# tools/agents/jvm-offload.sh [gradle task...] — run the Android app's JVM unit tests (default
# :app:testDebugUnitTest) on .58 through tools/agents/offload.sh, in android-app-dev's builder image there.
#
# WHY: the Mac at load 40-60 times the ship's JVM step out (rc=124); .58 runs it natively on amd64.
# Exit: gradle's rc; 255 = host unreachable (the caller then runs its local step as before).
#
#   tools/agents/jvm-offload.sh                      # from any directory of a PowOS checkout
#   OFFLOAD_HOST=user@host tools/agents/jvm-offload.sh :app:testDebugUnitTest :owl:test

set -euo pipefail
HOST=${OFFLOAD_HOST:-powos@192.168.50.58}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP=$(git rev-parse --show-toplevel)
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
[ $# -gt 0 ] || set -- :app:testDebugUnitTest
ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null ||
  { echo "jvm-offload.sh: $HOST unreachable" >&2; exit 255; }

# PowTerm's terminal glue is compiled into the app from android-app-dev's repo (app/build.gradle.kts, POWTERM_SRC).
ssh "$HOST" mkdir -p offload/_powterm-java
rsync -a --delete "$AAD/projects/powterm/app/src/main/java/" "$HOST:offload/_powterm-java/"

# HACK: android-app-dev's Dockerfile is arm64-only (it adds amd64 as a foreign arch and pins the native apt
# sources to arm64), so .58 builds a copy with that block stripped and FROM fully qualified (podman's
# short-name policy). Real fix: make that Dockerfile arch-aware in android-app-dev, then build it as-is here.
TAG="android-app-dev-android-builder:$(git -C "$AAD" hash-object Dockerfile | cut -c1-12)"
if ! ssh "$HOST" podman image exists "$TAG"; then
  echo "jvm-offload.sh: building $TAG on $HOST (one-time) ..." >&2
  python3 - "$AAD/Dockerfile" <<'EOF' | ssh "$HOST" "mkdir -p offload/builder-ctx && taskset -c 0-23 nice -n 10 podman build -q -t $TAG -f - offload/builder-ctx" >&2
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'# Add amd64 arch.*?\n\n', '', s, count=1, flags=re.S).replace(':amd64', '')
print(s.replace('FROM eclipse-temurin', 'FROM docker.io/library/eclipse-temurin'), end='')
EOF
fi

cd "$TOP/targets/android/app"
exec env OFFLOAD_HOST="$HOST" "$HERE/offload.sh" bash -c '
  T=$(git rev-parse --show-toplevel)
  exec docker run --rm --security-opt label=disable -v "$T:$T" -w "$PWD" \
    -v "$HOME/offload/_powterm-java:/powterm-java:ro" -e POWTERM_SRC=/powterm-java \
    -v offload-gradle:/root/.gradle --entrypoint bash "$0" -c "./gradlew --no-daemon -q $*"' "$TAG" "$@"
