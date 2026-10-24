#!/bin/bash
# Hermetic test of ship-apk.sh's "behind origin" handling (friction f36): "ship-apk: REFUSED - HEAD is behind
# origin/worktree-powos-multiplatform" refused every service ship whose own checkout had lagged origin by the
# time the build started - the service's whole job is to ship origin's TIP, never its own stale snapshot. Only
# a commit that ISN'T on origin at all should ever be refused.
#   test/tier1/test-ship-catchup.sh        exit 0 = all pass
# Stubs shell/dev/gate.sh (always ok) and targets/android/build-app.sh (always fails, deliberately, right after
# it runs) so the real ship-apk.sh logic is exercised up to and including the build attempt, without needing a
# real shell tree, a real APK or a phone. Nothing reaches docker, adb or ~/.cache outside $T.
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-catchup-test.XXXXXX"); trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig
mkdir -p "$HOME/.cache"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

seed_repo() {   # a bare origin with one base commit on worktree-powos-multiplatform, and a clone at $T/A
  rm -rf "$T/origin.git" "$T/seed" "$T/A" "$T/B"
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  (
    cd "$T/seed" && git checkout -q -b worktree-powos-multiplatform
    mkdir -p tools/phone shell/dev targets/android
    cp "$src/tools/phone/ship-apk.sh" tools/phone/ship-apk.sh
    printf '#!/bin/bash\necho "ok all pages"\n' > shell/dev/gate.sh
    printf '#!/bin/bash\necho "BUILD ATTEMPTED" >&2\nexit 5\n' > targets/android/build-app.sh
    chmod +x shell/dev/gate.sh targets/android/build-app.sh tools/phone/ship-apk.sh
    git add -A && git commit -qm base && git push -q origin worktree-powos-multiplatform 2>/dev/null
  )
  git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/A" 2>/dev/null
}

advance_origin() {   # another agent's commit lands on origin after $T/A's checkout was made
  git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/B" 2>/dev/null
  (cd "$T/B" && echo "newer" > shell/dev/marker.txt && git add -A && git commit -qm newer &&
    git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null)
  rm -rf "$T/B"
}

run_ship() {   # run_ship <extra env...> -- <extra args...>
  (cd "$T/A" && SHIP_APK_CURRENT=1 "$@" bash tools/phone/ship-apk.sh --silent --now) > "$T/out" 2>&1
}

# 1. Service mode, checkout behind origin (but its own commit IS on origin): catches up and builds origin's tip,
#    never refuses for being behind.
seed_repo; advance_origin
old_head=$(cd "$T/A" && git rev-parse HEAD)
new_tip=$(cd "$T/origin.git" && git rev-parse worktree-powos-multiplatform)
run_ship env POWOS_SHIP_SERVICE=1; rc=$?
[ "$old_head" != "$new_tip" ] || { bad "setup: A wasn't actually behind origin"; exit 1; }
grep -q "REFUSED - HEAD is behind" "$T/out" && bad "service ship still refuses for being behind" ||
  ok "service ship doesn't refuse for being behind"
grep -q "catching up to its tip" "$T/out" && ok "service ship logs the catch-up" || { bad "no catch-up message"; cat "$T/out"; }
[ "$(cd "$T/A" && git rev-parse HEAD)" = "$new_tip" ] && ok "checkout caught up to origin's tip" || bad "checkout didn't catch up"
[ "$rc" = 5 ] && grep -q "BUILD ATTEMPTED" "$T/out" && ok "reached the build (at the caught-up tip)" ||
  { bad "didn't reach the build (rc $rc)"; cat "$T/out"; }

# 2. --direct (a human, not the service): still refuses and asks them to pull/rebase - a deliberate ship from an
#    old snapshot should never happen silently.
seed_repo; advance_origin
(cd "$T/A" && SHIP_APK_CURRENT=1 bash tools/phone/ship-apk.sh --silent --now --direct) > "$T/out" 2>&1; rc=$?
[ "$rc" = 3 ] && grep -q "REFUSED - HEAD is behind" "$T/out" && ok "a direct ship still refuses for being behind" ||
  { bad "direct ship didn't refuse (rc $rc)"; cat "$T/out"; }
grep -q "BUILD ATTEMPTED" "$T/out" && bad "direct ship built anyway" || ok "direct ship never reached the build"

# 3. HEAD's own commit isn't on origin at all (force-pushed away): refused in BOTH modes - this is the one real
#    refusal case.
seed_repo
(cd "$T/A" && git commit -q --allow-empty -m "local only")   # never pushed
run_ship env POWOS_SHIP_SERVICE=1; rc=$?
[ "$rc" = 3 ] && grep -q "REFUSED - HEAD isn't on origin" "$T/out" && ok "a commit missing from origin is refused" ||
  { bad "missing-from-origin case (rc $rc)"; cat "$T/out"; }

echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
