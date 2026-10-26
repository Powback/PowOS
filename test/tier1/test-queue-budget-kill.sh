#!/bin/bash
# test-queue-budget-kill.sh: f44 - the runner's budget-kill (endjob, queue.sh) must send SIGTERM
# first and give a check ~10 s to run its EXIT/TERM restore trap before SIGKILL. A check that
# changes a device setting and restores it on EXIT (linux-touch.sh's LEASH=off) needs that trap to
# actually run, or the setting is stuck until someone notices by hand.
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
# Pull just the two functions under test, not the whole runner (that needs a phone/board).
funcs=$(grep -E '^(killtree|endjob)\(\)' "$src/tools/phone/verify/queue.sh")
[ -n "$funcs" ] || { echo "FAIL f44: couldn't find killtree/endjob in queue.sh"; exit 1; }
eval "$funcs"

T=$(mktemp -d "${TMPDIR:-/tmp}/budget-kill-test.XXXXXX")
cleanup() { pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$T"; }
trap cleanup EXIT

fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "       $2"; }

# ===== Test 1: SIGTERM runs the trap, which gets to finish (grace is real wall time, not instant) =====
cat > "$T/restorer.sh" <<EOF
#!/bin/bash
trap 'sleep 1; echo restored > "$T/restored"; exit 0' TERM
sleep 300 & wait \$!
EOF
chmod +x "$T/restorer.sh"
"$T/restorer.sh" >/dev/null 2>&1 & pid=$!
sleep 0.3
endjob "$pid" >/dev/null 2>&1
wait "$pid" 2>/dev/null
if [ -f "$T/restored" ]; then ok "f44: SIGTERM lets the restore trap run to completion"
else bad "f44: SIGTERM lets the restore trap run to completion" "no $T/restored marker"; fi

# ===== Test 2: a check that ignores TERM still dies, but only after a real ~10s grace (not ~5s) =====
cat > "$T/stubborn.sh" <<'EOF'
#!/bin/bash
trap '' TERM
sleep 300 & wait $!
EOF
chmod +x "$T/stubborn.sh"
"$T/stubborn.sh" >/dev/null 2>&1 & pid=$!
sleep 0.3
t0=$(date +%s)
endjob "$pid" >/dev/null 2>&1
t1=$(date +%s)
el=$((t1 - t0))
alive=no; kill -0 "$pid" 2>/dev/null && alive=yes
if [ "$alive" = no ] && [ "$el" -ge 9 ]; then
  ok "f44: TERM-ignoring check is SIGKILLed only after ~10s grace (${el}s)"
else
  bad "f44: TERM-ignoring check is SIGKILLed only after ~10s grace (${el}s)" "alive=$alive el=${el}s"
fi

# ===== Test 3: ordering - TERM is sent before KILL, never KILL-first =====
cat > "$T/sigspy.sh" <<EOF
#!/bin/bash
trap 'echo TERM >> "$T/signals"; exit 0' TERM
sleep 300 & wait \$!
EOF
chmod +x "$T/sigspy.sh"
"$T/sigspy.sh" >/dev/null 2>&1 & pid=$!
sleep 0.3
endjob "$pid" >/dev/null 2>&1
wait "$pid" 2>/dev/null
first=$(head -1 "$T/signals" 2>/dev/null || echo none)
[ "$first" = TERM ] && ok "f44: TERM is sent before any KILL" || bad "f44: TERM is sent before any KILL" "first signal seen: $first"

echo
if [ $fails -eq 0 ]; then
  echo "All tests passed"
  exit 0
else
  echo "$fails tests failed"
  exit 1
fi
