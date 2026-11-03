#!/usr/bin/env bash
# The engine's host-side native tests (Linux: eventfd, memfd): built from the real sources with cc, or in the gcc:14
# image from the Mac. Usage: targets/android/app/engine/src/test/native/run.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jni="$here/../../main/jni/andromarchy_core"
build='set -e; out=$(mktemp -d); for t in "$T"/*_test.c; do n=$(basename "$t" .c);
  cc -O1 -Wall -pthread -I"$J/libdisplay_consumer" -I"$J/common" "$t" "$J/libdisplay_consumer/display_consumer.c" "$J/common/socket_utils.c" -o "$out/$n";
  timeout 30 "$out/$n"; done'
if [ "$(uname -s)" = Linux ] && command -v cc >/dev/null; then
  T="$here" J="$jni" bash -c "$build"
else
  docker run --rm -v "$here:/t:ro" -v "$jni:/j:ro" -e T=/t -e J=/j gcc:14 bash -c "$build"
fi
