#!/usr/bin/env bash
# shell/dev/owl-jar.sh <repo> [--build]: make <repo>/targets/android/app/owl/build/cli/owl.jar the OWL CLI built from
# <repo>'s own targets/android/app/owl/src, and print its path.
#
# WHY (friction f402): owl.jar is gitignored build output, so every new agent worktree lacked it and the widget sweep
# (dev/preview.sh) failed until an agent copied it by hand - the offline Gradle build can't make it in a fresh
# worktree (AGP isn't in the gradle cache). So the jar is kept once per source version in the shared, never-pruned
# build-inputs cache (tools/agents/build-inputs-cache.sh, logical path owl/<src-hash>/owl.jar), keyed by a hash of
# the sources' CONTENT and RELATIVE paths (the old preview.sh hash included the absolute checkout path, so no two
# worktrees ever agreed on it). Lookup order:
#   1. <repo>'s own jar, if its owl.jar.src records this hash;
#   2. the cache;
#   3. a seed checkout ($OWL_JAR_FROM, default ~/pw/powos-multiplatform) whose sources hash the same and whose jar was
#      built from them (its owl.jar.src holds this hash, or the old absolute-path hash of its own sources) - copied
#      into the cache, then used;
#   4. --build only: gradle in the Android builder image with the shared gradle cache volume, then cached.
# tools/agents/worktree.sh new runs this without --build, so a fresh worktree already has the jar.
# Exit 0: a jar built from these sources is in place. 3: only a jar built from OTHER sources is there (--build
# couldn't build - the gradle cache busy). 2: no jar. Copies, never hardlinks, into a checkout: gradle rewrites
# owl.jar in place, which would change a hardlinked cache blob under every other user. Never deletes cache entries.
set -euo pipefail
repo=$(cd "${1:?usage: owl-jar.sh <repo> [--build]}" && pwd)
build=0; [ "${2:-}" = --build ] && build=1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bic=${OWL_JAR_CACHE_TOOL:-$here/../../tools/agents/build-inputs-cache.sh}
jar=$repo/targets/android/app/owl/build/cli/owl.jar

# owl_hash <repo>: content + relative path of every .kt under owl/src (identical sources -> identical hash anywhere).
owl_hash() { ( cd "$1/targets/android/app/owl/src" 2>/dev/null && find . -name '*.kt' -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16 ); }
# The pre-f402 preview.sh hash (absolute paths) - what an existing checkout's owl.jar.src may still hold.
legacy_hash() { find "$1/targets/android/app/owl/src" -name '*.kt' -print0 2>/dev/null | sort -z | xargs -0 shasum | shasum | cut -c1-16; }
h=$(owl_hash "$repo" || true)
[ -n "$h" ] || { echo "owl-jar: no targets/android/app/owl/src in $repo" >&2; exit 2; }
key=owl/$h/owl.jar

install_from() {  # install_from <file>: copy it in as this repo's jar for hash $h
  mkdir -p "$(dirname "$jar")"; cp "$1" "$jar.tmp.$$" && mv "$jar.tmp.$$" "$jar"; echo "$h" > "$jar.src"
}
cache_put() {     # cache_put <file>: a private copy goes into the cache (its blob is a hardlink of that copy)
  [ -x "$bic" ] || return 0
  t=$(mktemp "${TMPDIR:-/tmp}/owl-jar.XXXXXX"); cp "$1" "$t"; "$bic" put "$t" "$key" >/dev/null 2>&1 || true; rm -f "$t"
}
cache_get() {
  [ -x "$bic" ] || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/owl-jar.XXXXXX"); rm -f "$t"
  if "$bic" get "$key" "$t" >/dev/null 2>&1; then install_from "$t"; rm -f "$t"; return 0; fi
  rm -f "$t"; return 1
}

if [ -f "$jar" ] && [ "$(cat "$jar.src" 2>/dev/null)" = "$h" ]; then cache_put "$jar"; echo "$jar"; exit 0; fi
if cache_get; then echo "$jar"; exit 0; fi
seed=${OWL_JAR_FROM:-${POWOS_RUN_ROOT:-$HOME/pw}/powos-multiplatform}
sj=$seed/targets/android/app/owl/build/cli/owl.jar
if [ "$(cd "$seed" 2>/dev/null && pwd)" != "$repo" ] && [ -f "$sj" ] && [ "$(owl_hash "$seed")" = "$h" ]; then
  ss=$(cat "$sj.src" 2>/dev/null || true)
  if [ "$ss" = "$h" ] || [ "$ss" = "$(legacy_hash "$seed")" ]; then
    cache_put "$sj"; install_from "$sj"; echo "$jar"; exit 0
  fi
fi
if [ $build = 1 ]; then
  echo "     owl.jar: building (targets/android/app/owl)" >&2
  if docker run --rm -v "${PREVIEW_GRADLE_VOLUME:-powos-android-gradle}:/root/.gradle" -v "$repo:$repo" -w "$repo/targets/android/app" \
    --entrypoint bash "${PREVIEW_JVM_IMAGE:-android-app-dev-android-builder:latest}" \
    -c './gradlew -q --offline --configure-on-demand :owl:owlJar' >/dev/null 2>&1 && [ -f "$jar" ]; then
    echo "$h" > "$jar.src"; cache_put "$jar"; echo "$jar"; exit 0
  fi
fi
[ -f "$jar" ] && { echo "$jar"; exit 3; }
exit 2
