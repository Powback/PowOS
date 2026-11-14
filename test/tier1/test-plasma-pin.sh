#!/usr/bin/env bash
# test-plasma-pin.sh - targets/android/tools/plasma-pin-inside.sh (plasma-pin.sh's in-rootfs step) and its caller.
# 11-14: the main checkout's out/powos-rootfs.tar.gz was an old full build (Plasma 6.8.1), not the 6.7.5 build base:
# the pin came out empty, repo-add failed on its own glob, and build-rootfs.sh ran on anyway ("plasma-pin.sh && cp"
# under set -e) into an unrelated-looking pacman error. Here: a rootfs at the wrong Plasma is refused by name, the
# right one pins every package at kwin's version except ours, and build-rootfs.sh stops when plasma-pin.sh fails.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSIDE=$ROOT/targets/android/tools/plasma-pin-inside.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
pkg() { mkdir -p "$1/$2-$3"; printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n' "$2" "$3" > "$1/$2-$3/desc"; }

pkg "$T/new" kscreenlocker 6.8.1-1; pkg "$T/new" libplasma 6.8.1-1; pkg "$T/new" kwin 6.7.5-3.31; pkg "$T/new" bash 5.3-1
if err=$(VER=6.7.5 OURS="kwin" PLASMA_PIN_DB=$T/new PLASMA_PIN_LIST=1 bash "$INSIDE" "$T" 2>&1); then
  echo "FAIL: a Plasma 6.8.1 rootfs was pinned: $err"; fail=1
elif ! grep -q "kscreenlocker 6.8.1" <<<"$err"; then
  echo "FAIL: refusal doesn't name the rootfs's Plasma: $err"; fail=1
else echo "PASS: rootfs at another Plasma refused"; fi

pkg "$T/base" kscreenlocker 6.7.5-1; pkg "$T/base" libplasma 6.7.5-1; pkg "$T/base" plasma-workspace 1:6.7.5-3
pkg "$T/base" kwin 6.7.5-3.1; pkg "$T/base" bash 5.3-1; pkg "$T/base" libplasma-extra 6.7.50-1
got=$(VER=6.7.5 OURS="kwin breeze" PLASMA_PIN_DB=$T/base PLASMA_PIN_LIST=1 bash "$INSIDE" "$T" | sort | tr '\n' ' ')
if [ "$got" = "kscreenlocker libplasma plasma-workspace " ]; then echo "PASS: build base pins Plasma 6.7.5 minus ours"
else echo "FAIL: pin was '$got'"; fail=1; fi

if grep -nE 'plasma-pin\.sh"? *&&' "$ROOT/targets/android/build-rootfs.sh"; then
  echo "FAIL: build-rootfs.sh runs plasma-pin.sh as the left side of && (set -e won't stop on its failure)"; fail=1
else echo "PASS: build-rootfs.sh stops when plasma-pin.sh fails"; fi
exit $fail
