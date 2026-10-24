#!/bin/bash
# Test: tools/emu/emu.sh's boot-readiness gating - booted() and home_ready() - against a FAKE adb/cdp.sh, not a
# live emulator (f129: nothing covered this; a fix there could only be "proven" with a live, booted AVD, which is
# slow and not what tier-1 is for). Sources emu.sh for real (its own functions, unmodified) via the
# `bash -c 'source "$0" "$1"' /abs/path/to/emu.sh <subcmd>` trick: $0 becomes emu.sh's own path (so its
# `here=$(dirname "$0")`/$ROOT compute correctly, unlike a plain `source` where $0 stays the caller's), $1 is a
# harmless subcommand ("status": no real device needed, never touches booted/home_ready itself) so the script's
# own case-dispatch at the bottom doesn't `exit` the test.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(cd "$HERE/../.." && pwd -P)
EMU_SH="$REPO/tools/emu/emu.sh"
FAIL=0

# A fake `adb`: ANDROID_SDK_ROOT/platform-tools/adb, so emu.sh's own $ADB resolves to it at source time.
FAKE_SDK=$(mktemp -d); mkdir -p "$FAKE_SDK/platform-tools"
cat > "$FAKE_SDK/platform-tools/adb" <<'EOF'
#!/bin/bash
args="$*"
case "$args" in
  *"getprop sys.boot_completed"*) echo "${FAKE_BOOT:-1}" ;;
  *"cmd package path android"*) [ "${FAKE_PKG_OK:-1}" = 1 ] && { echo "package:/system/framework/framework-res.apk"; exit 0; } || exit 1 ;;
  *"get-state"*) exit 1 ;;   # "not running" - status's own `running` check, harmless either way
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_SDK/platform-tools/adb"

# A fake cdp.sh (home_ready's only external dependency besides `a`/adb): argv is `eval home <JS expr>` (3 args -
# the expr is $3, NOT $4 - a first draft of this test got that wrong and every home_ready call silently answered
# "" instead of "true"/a rect, the loop ran its full 60 tries and "failed" in 120s instead of ~2s).
FAKE_ROOT=$(mktemp -d); mkdir -p "$FAKE_ROOT/tools/phone"
cat > "$FAKE_ROOT/tools/phone/cdp.sh" <<'EOF'
#!/bin/bash
expr="$3"
case "$expr" in
  *__powosAlive*) echo "${FAKE_ALIVE:-true}" ;;
  *getBoundingClientRect*) echo "${FAKE_BAR:-[[100,50]]}" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$FAKE_ROOT/tools/phone/cdp.sh"
cleanup() { rm -rf "$FAKE_SDK" "$FAKE_ROOT"; }
trap cleanup EXIT

run() {  # run <env assignments...> -- <shell to eval after sourcing>
  local envs=() rest
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env "${envs[@]}" ANDROID_SDK_ROOT="$FAKE_SDK" bash -c '
    set -uo pipefail
    source "$0" "$1" >/dev/null 2>&1
    ROOT="$2"
    eval "$3"
  ' "$EMU_SH" status "$FAKE_ROOT" "$*"
}

check() { local name=$1 got=$2 want=$3
  if [ "$got" = "$want" ]; then echo "✓ $name"; else echo "✗ $name: got $got, want $want"; FAIL=1; fi; }

# booted(): boot_completed=1 AND the package service answers -> true
check "booted: boot_completed=1, pm answers" \
  "$(run FAKE_BOOT=1 FAKE_PKG_OK=1 -- 'booted && echo yes || echo no')" "yes"

# booted(): boot_completed never flipped to 1 -> false (never calls the pm check - short-circuit `&&`)
check "booted: boot_completed=0" \
  "$(run FAKE_BOOT=0 FAKE_PKG_OK=1 -- 'booted && echo yes || echo no')" "no"

# booted(): boot_completed=1 but the package service doesn't answer yet (wedged/still starting) -> false
check "booted: boot_completed=1, pm not ready" \
  "$(run FAKE_BOOT=1 FAKE_PKG_OK=0 -- 'booted && echo yes || echo no')" "no"

# home_ready(): page alive + a real, stable bar rect on both reads -> true, fast (no 120s timeout wait)
out=$(run FAKE_ALIVE=true FAKE_BAR='[[100,50]]' -- 't0=$(date +%s); home_ready; rc=$?; t1=$(date +%s); echo "$rc $((t1 - t0))"')
rc=${out%% *}; el=${out#* }
check "home_ready: alive + stable bar -> rc=0" "$rc" "0"
[ "${el:-99}" -le 10 ] && echo "✓ home_ready: returned fast (${el}s, not the 120s timeout)" || { echo "✗ home_ready: took ${el}s - should return in a few seconds"; FAIL=1; }

# home_ready(): the page never reports alive -> stays false. Given the full loop is 60 tries * 2s = up to 120s,
# this only proves it doesn't false-positive early (not the whole timeout - that needs a live device, per f129's
# own repro note). Backgrounded + killed after 3s (no `timeout`(1) dependency, and no bash "Alarm clock" job
# notice on the signalled foreground pipeline): still running at 3s = still waiting, correctly.
env FAKE_ALIVE=never FAKE_BAR='[[100,50]]' ANDROID_SDK_ROOT="$FAKE_SDK" bash -c '
    set -uo pipefail; source "$0" "$1" >/dev/null 2>&1; ROOT="$2"; home_ready; echo "rc=$?" > /tmp/powos-test-hr-$$.rc
  ' "$EMU_SH" status "$FAKE_ROOT" & hrp=$!
sleep 3
if kill -0 "$hrp" 2>/dev/null; then
  echo "✓ home_ready: still waiting (not a false positive) 3s into a never-alive page"
  kill "$hrp" 2>/dev/null; wait "$hrp" 2>/dev/null
else
  echo "✗ home_ready: returned (not still waiting) with a never-alive page"; FAIL=1
fi
rm -f /tmp/powos-test-hr-*.rc

[ "$FAIL" = 0 ] && echo "All emu boot-check tests passed!" || { echo "emu boot-check tests FAILED"; exit 1; }
