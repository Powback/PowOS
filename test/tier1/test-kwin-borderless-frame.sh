#!/bin/bash
# test-kwin-borderless-frame.sh: kwin 0068's own-frame vs borderless decision (anland_task_policy.h drawsOwnFrame) -
# a game's borderless window (Wine WS_POPUP / Unity -popupwindow / SDL borderless: fixed size or opened at the output's
# size) gets PowOS's bar, Steam/GTK/Chrome (frame extents, resizable, or moving themselves) don't (the user, 11-08:
# Broforce "without a title bar, so there's no way to resize it or make it fullscreen").
# The header is rebuilt from the patches that write it (git apply --include, no KWin tarball), then
# targets/android/pkgs/kwin/test/task-policy-test.cpp is compiled and run. Also: PKGBUILD lists every patch on disk once,
# in order, with one SKIP each (a patch left out of _patches is never applied - the change would silently not ship).
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
pk=$src/targets/android/pkgs/kwin
T=$(mktemp -d "${TMPDIR:-/tmp}/kwin-frame-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }

# PKGBUILD's patch list = the patch files, in order; one SKIP per patch after the tarball's sum.
listed=$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${_patches[@]}"; echo "SUMS ${#sha256sums[@]}"' _ "$pk/PKGBUILD")
files=$(cd "$pk" && ls [0-9][0-9][0-9][0-9]-*.patch | sort)
if [ "$(echo "$listed" | grep -v '^SUMS')" = "$files" ]; then ok "PKGBUILD _patches = the patch files, in order"; else bad "PKGBUILD _patches differ from the patch files" "$(diff <(echo "$listed" | grep -v '^SUMS') <(echo "$files"))"; fi
n=$(echo "$files" | wc -l | tr -d ' ')
sums=$(echo "$listed" | sed -n 's/^SUMS //p')
[ "$sums" = $((n + 1)) ] && ok "one sha256sum per source ($sums)" || bad "sha256sums has $sums entries for $((n + 1)) sources"
grep -q '^0068-' <<<"$files" && ok "0068 is in the set" || bad "0068 (borderless is not a frame) missing"

# The policy header, from every patch that touches it, in order.
mkdir -p "$T/tree" && git -C "$T/tree" init -q
for p in $(cd "$pk" && grep -l 'anland_task_policy.h' $files); do
  git -C "$T/tree" apply --include='src/backends/anland/anland_task_policy.h' "$pk/$p" || bad "$p does not apply to anland_task_policy.h"
done
hdr=$T/tree/src/backends/anland/anland_task_policy.h
grep -q 'inline bool drawsOwnFrame' "$hdr" 2>/dev/null && ok "anland_task_policy.h has drawsOwnFrame" || bad "drawsOwnFrame missing from the patched header"

cxx=$(command -v c++ || command -v g++ || command -v clang++ || true)
if [ -z "$cxx" ]; then
  bad "no C++ compiler to build task-policy-test.cpp (tools/jobs/tier1.Dockerfile installs g++)"
else
  if out=$("$cxx" -std=c++17 -Wall -Wextra -Werror -I"$T/tree/src/backends/anland" -o "$T/t" "$pk/test/task-policy-test.cpp" 2>&1); then
    out=$("$T/t" 2>&1) && ok "task-policy-test: $out" || bad "task-policy-test failed" "$out"
  else
    bad "task-policy-test.cpp does not compile" "$out"
  fi
fi

[ $fails -eq 0 ] && echo "test-kwin-borderless-frame: all passed" || echo "test-kwin-borderless-frame: $fails failed"
[ $fails -eq 0 ]
