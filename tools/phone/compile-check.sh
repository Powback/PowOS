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
if [ "${rc:-1}" != 0 ]; then echo "compile-check: FAILED (gradle exit ${rc:-?})" >&2; exit 1; fi
# The complexity lint land.sh's pre-push hook runs (tools/git-hooks/pre-push: lint-complexity.sh --only <changed .kt>,
# limit cognitive 10): it only ran at push, so a change that compiled here was refused there 4+ times on 2026-10-24
# (f245). Same invocation, on the Kotlin files changed against origin's tip (committed + uncommitted).
kt=""
while IFS= read -r f; do
    case "$f" in targets/android/app/*.kt) kt+="${kt:+,}${f#targets/android/app/}" ;; esac
done < <(git -C "$root" diff --name-only --diff-filter=AM "$(git -C "$root" merge-base HEAD origin/worktree-powos-multiplatform 2>/dev/null || echo HEAD)" 2>/dev/null)
if [ -n "$kt" ] && [ "${GATE_LINT:-1}" != 0 ]; then
    . "$root/tools/lib/need-docker.sh"; need_docker
    lint=$("$root/targets/android/lint-complexity.sh" --only "$kt" 2>&1); lrc=$?
    if [ $lrc = 1 ]; then echo "$lint"; echo "compile-check: FAILED - compiles, but the complexity lint (the push gate) refuses it" >&2; exit 1; fi
fi
echo "compile-check: OK"; exit 0
