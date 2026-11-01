#!/usr/bin/env bash
# test-worktree-gc-owljar.sh - tools/agents/worktree.sh: `new` puts in the OWL CLI jar (friction f402) and `gc`
# never removes a worktree its agent is still using (friction f400).
#
# f402: owl.jar is gitignored build output; every fresh worktree lacked it, so the widget sweep (shell/dev/preview.sh)
#   failed until an agent copied it by hand. Now shell/dev/owl-jar.sh keys it by a hash of the sources' content and
#   RELATIVE paths in the shared build-inputs cache, seeding it from powos-multiplatform's jar when the sources match.
# f400: gc judged "idle" by the HEAD commit's age only, so a clean, merged worktree whose agent had just checked out
#   an older commit (a "before" render) was removed mid-run ("idle 50m"). Now a fresh git admin file, a changed file
#   or a process cwd inside the worktree each keep it.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
pass=0 fail=0
ok() { echo "  PASS $1"; pass=$((pass + 1)); }
no() { echo "  FAIL $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

T=$(mktemp -d); trap 'kill $SLEEPER 2>/dev/null; rm -rf "$T"' EXIT; SLEEPER=
export HOME=$T/home POWOS_WT_ROOT=$T/pw POWOS_RUN_ROOT=$T/pw POWOS_BUILD_INPUTS_CACHE=$T/cache
mkdir -p "$HOME" "$T/pw"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
old=$(( $(date +%s) - 7200 ))
export GIT_AUTHOR_DATE="@$old" GIT_COMMITTER_DATE="@$old"
git init -q --bare "$T/origin.git"
P=$T/pw/powos-multiplatform
git init -q -b worktree-powos-multiplatform "$P"
mkdir -p "$P/tools/agents" "$P/shell/dev" "$P/targets/android/app/owl/src/main/kotlin"
cp "$REPO/tools/agents/worktree.sh" "$REPO/tools/agents/build-inputs-cache.sh" "$P/tools/agents/"
cp "$REPO/shell/dev/owl-jar.sh" "$P/shell/dev/"
echo 'fun main() {}' > "$P/targets/android/app/owl/src/main/kotlin/Main.kt"
echo 'build/' > "$P/targets/android/app/owl/.gitignore"; echo 'out/' > "$P/.gitignore"
git -C "$P" add -A; git -C "$P" commit -qm one
echo '// two' >> "$P/targets/android/app/owl/src/main/kotlin/Main.kt"; git -C "$P" commit -qam two
git -C "$P" remote add origin "$T/origin.git"; git -C "$P" push -q origin worktree-powos-multiplatform
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
wt() { ( cd "$P" && bash tools/agents/worktree.sh "$@" ); }

echo "f402: owl.jar in a new worktree"
J=targets/android/app/owl/build/cli/owl.jar
mkdir -p "$P/$(dirname $J)"; echo "jar-v2" > "$P/$J"
# The main tree's jar.src as preview.sh used to write it (absolute-path hash).
find "$P/targets/android/app/owl/src" -name '*.kt' -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16 > "$P/$J.src"
wt new a1 >/dev/null 2>&1
check "new worktree has owl.jar" '[ "$(cat "$T/pw/a1/$J" 2>/dev/null)" = jar-v2 ]'
check "seeded into the shared cache" '[ -n "$(find "$T/cache/owl" -name owl.jar 2>/dev/null)" ]'
blob=$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$(find "$T/cache/owl" -name owl.jar | head -1)")
check "a copy, not a hardlink (gradle rewrites it in place)" '[ -f "$blob" ] && [ ! "$T/pw/a1/$J" -ef "$blob" ]'
rm -f "$P/$J" "$P/$J.src"
wt new a2 >/dev/null 2>&1
check "from the cache once the main tree's jar is gone" '[ "$(cat "$T/pw/a2/$J" 2>/dev/null)" = jar-v2 ]'
echo '// changed' >> "$T/pw/a2/targets/android/app/owl/src/main/kotlin/Main.kt"
"$T/pw/a2/shell/dev/owl-jar.sh" "$T/pw/a2" >/dev/null 2>&1; rc=$?
check "changed sources: the old jar is reported stale (rc 3), not passed off as current" '[ $rc = 3 ]'
git -C "$T/pw/a2" checkout -q -- .
"$T/pw/a2/shell/dev/owl-jar.sh" "$T/pw/a2" >/dev/null 2>&1; rc=$?
check "same sources again: current (rc 0)" '[ $rc = 0 ]'

echo "f400: gc keeps worktrees in use"
age_out() {  # make every file of worktree $1 and its git admin dir 2 h old
  local d=$T/pw/$1 gd; gd=$(git -C "$d" rev-parse --path-format=absolute --git-dir)
  find "$d" "$gd" -exec touch -h -d "@$old" {} + 2>/dev/null
}
for n in idle fresh detached rendered cwd; do wt new "$n" >/dev/null 2>&1; done
for n in a1 a2 idle detached rendered cwd; do age_out "$n"; done
git -C "$T/pw/detached" checkout -q --detach HEAD~1          # the "before" render case (ai-overlay-polish)
mkdir -p "$T/pw/rendered/out"; echo png > "$T/pw/rendered/out/before.png"   # gitignored output
age_out cwd; ( cd "$T/pw/cwd" && exec sleep 60 ) & SLEEPER=$!
sleep 0.5
wt gc >/dev/null 2>&1
check "idle, merged, clean worktree removed" '[ ! -e "$T/pw/idle" ]'
check "freshly created worktree (old HEAD commit) kept" '[ -e "$T/pw/fresh/.git" ]'
check "worktree with a just-checked-out older commit kept" '[ -e "$T/pw/detached/.git" ]'
check "worktree with a just-written gitignored file kept" '[ -e "$T/pw/rendered/.git" ]'
check "worktree a process runs in kept" '[ -e "$T/pw/cwd/.git" ]'
check "base checkout never touched" '[ -e "$P/.git" ]'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
