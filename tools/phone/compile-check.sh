#!/bin/bash
# Compiles the PowOS app's Kotlin in THIS worktree, without building or publishing an APK: run it before you push a
# Kotlin change to origin - a committed but uncompiled change on the tip fails every agent's next ship.
#   tools/phone/compile-check.sh        exit 0 = compiles; otherwise the compiler's errors (e: ...) and exit 1
# A throwaway android-builder container on this worktree only: it never touches android-app-dev's shared
# projects/powos link or output/powos.apk (that's build-app.sh's, via ship-apk), so it's safe while a ship runs.
# The gradle cache is the shared volume (its own locks make concurrent use safe).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
case "$root" in "$HOME"/Projects/*) ;; *) echo "compile-check: the worktree must be under ~/Projects (mounted into the builder)" >&2; exit 2 ;; esac
app=/Projects${root#$HOME/Projects}/targets/android/app
out=$(docker run --rm -v "$HOME/Projects:/Projects" -v android-app-dev_gradle-cache:/root/.gradle \
  -e ANDROID_SDK_ROOT=/opt/android-sdk -w "$app" --entrypoint bash android-app-dev-android-builder:latest -c '
    echo sdk.dir=/opt/android-sdk > local.properties
    [ -f app/version.properties ] || printf "versionCode=1\nversionName=check\n" > app/version.properties
    ./gradlew :app:compileDebugKotlin --no-daemon -q 2>&1; echo "gradle-exit=$?"' 2>&1)
# Anywhere in a line: the SDK's progress bars end without a newline.
rc=$(echo "$out" | grep -o 'gradle-exit=[0-9]*' | tail -1 | cut -d= -f2)
echo "$out" | grep -E "^e: |error:" | head -40
# Not a compile error (a gradle lock held by a concurrent build, a dependency fetch): say what gradle said.
echo "$out" | grep -q "^e: " || echo "$out" | grep -A10 "What went wrong" | head -14
if [ "${rc:-1}" = 0 ]; then echo "compile-check: OK"; exit 0; fi
echo "compile-check: FAILED (gradle exit ${rc:-?})" >&2
exit 1
