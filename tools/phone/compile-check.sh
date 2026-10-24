#!/bin/bash
# Compiles the PowOS app's Kotlin in THIS worktree, without building or publishing an APK: run it before you push a
# Kotlin change to origin - a committed but uncompiled change on the tip fails every agent's next ship.
#   tools/phone/compile-check.sh        exit 0 = compiles; otherwise the compiler's errors (e: ...) and exit 1
# A throwaway android-builder container on this worktree only: it never touches android-app-dev's shared
# projects/powos link or output/powos.apk (that's build-app.sh's, via ship-apk), so it's safe while a ship runs.
# The gradle cache is the shared volume - but its own file locks only wait, they don't queue, so two
# concurrent --no-daemon runs can both time out waiting on the journal cache lock (f62/f66-69). Serialized
# through the Mac-wide build slot (tools/agents/build-slot.sh) instead, with the rest of the heavy builds.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# Worktrees moved from ~/Projects/PowOS/.claude/worktrees/<name> to $POWOS_RUN_ROOT (default ~/pw) under
# wt-move-rest (see tools/agents/worktree.sh); this guard/mount only knew ~/Projects, so every worktree
# created since the move got an instant "must be under ~/Projects" refusal instead of a real compile (f45).
RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}
case "$root" in
    "$HOME"/Projects/*) mnt="$HOME/Projects" ;;
    "$RUN_ROOT"/*)       mnt="$RUN_ROOT" ;;
    *) echo "compile-check: the worktree must be under ~/Projects or $RUN_ROOT (mounted into the builder)" >&2; exit 2 ;;
esac
app=/Projects${root#$mnt}/targets/android/app
out=$("$root/tools/agents/build-slot.sh" "compile-check $root" -- docker run --rm -v "$mnt:/Projects" -v android-app-dev_gradle-cache:/root/.gradle \
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
