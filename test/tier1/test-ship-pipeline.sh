#!/bin/bash
# test-ship-pipeline.sh - gate the ship service tests (f222 f225) in tier-1.
#
# Runs tools/phone/ship-queue-test.sh (queue, debounce, pause, guards) and
# tools/phone/ship-order-test.sh (install/push ordering) hermetically: both use
# a temp HOME with stubbed docker/adb, nothing reaches the phone or the real
# ship queue. Each runs as its own `bash <script>` process, so the wrappers'
# `set -uo pipefail` does not matter to run-all.sh, which omits pipefail (f227).
#
# Usage:  bash test/tier1/test-ship-pipeline.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

# The two tests share nothing (own mktemp dir, own HOME, kills only by their own
# temp path), so they run in parallel: wall time = the slower one.
# start_one <script>: background run, output + rc + seconds into $TMP/<script>.*
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
start_one() {
    ( s=$(date +%s); bash "$ROOT/tools/phone/$1" >"$TMP/$1.out" 2>&1; echo $? >"$TMP/$1.rc"
      echo $(( $(date +%s) - s )) >"$TMP/$1.secs" ) &
}
report_one() {
    local rc secs; rc=$(cat "$TMP/$1.rc"); secs=$(cat "$TMP/$1.secs")
    if [ "$rc" -eq 0 ]; then ok "$1 passes (${secs}s)"
    else bad "$1 failed rc $rc (${secs}s)"; grep -E 'FAIL|failed' "$TMP/$1.out" | head -20; fi
}

start_one ship-queue-test.sh
start_one ship-order-test.sh
wait
report_one ship-queue-test.sh
report_one ship-order-test.sh

echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
