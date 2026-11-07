#!/bin/bash
# test-queue-lock-release.sh: the verify lock (~/.cache/powos-verify.lock) never outlives the window that took it.
# 11-07 12:28-14:3x: queue.sh's window set its own EXIT trap after window_lock, which REPLACED window_lock's lock
# release (bash keeps one EXIT trap) - the lock stayed, the runner waited on its own lock with the phone idle and 14
# jobs queued. Covers: wl_release in an overriding trap, a stale lock (dead owner pid / this process's own leaked
# window) removed, a live owner's or a pid-less (injected check's) lock waited for, and a failed settings restore
# keeping the user's saved brightness/timeout (wl_sleep). Fake idle.sh/adb.sh, no phone.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd); wl=$src/tools/phone/verify/window-lock.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/queue-lock-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }
mkdir -p "$T/tools" "$T/.cache"
printf '#!/bin/bash\necho "idle=300 screen=Awake act=0"\n' > "$T/tools/idle.sh"
printf '#!/bin/bash\n[ -e "%s/adb-fails" ] && exit 1; exit 0\n' "$T" > "$T/tools/adb.sh"
chmod +x "$T/tools/"*.sh
L=$T/.cache/powos-verify.lock
run() { HOME=$T WL_PHONE=$T/tools WL_WOKE=$T/woke bash -c 'sleep() { :; }; . "$1"; shift; eval "$*"' _ "$wl" "$@" 2>&1; }

# 1. a caller's own EXIT trap with wl_release (queue.sh's window): the lock goes when the window ends.
rm -rf "$L"; out=$(run 'window_lock verify-queue 120 60 >/dev/null; trap "echo window-end; wl_release" EXIT; [ -d "$HOME/.cache/powos-verify.lock" ] && echo held')
grep -q held <<<"$out" && grep -q window-end <<<"$out" && [ ! -d "$L" ] && ok "window held the lock; the overriding trap's wl_release removed it" || bad "overriding trap releases" "$out"
# ... and without it (the 12:28 bug) the lock stays - the next window_lock recovers it (own pid gone).
rm -rf "$L"; run 'window_lock verify-queue 120 60 >/dev/null; trap "echo window-end" EXIT' >/dev/null
[ -d "$L" ] && ok "(the bug reproduced: an overriding trap without wl_release leaves the lock)" || bad "bug repro: lock should be left"
out=$(run 'window_lock verify-queue 120 60; echo got=$?')
grep -q 'removing a stale verify lock' <<<"$out" && grep -q 'got=0' <<<"$out" && ok "dead owner pid: stale lock removed, the window comes" || bad "dead pid stale lock" "$out"

# 2. this process's own leaked window (same name, same pid - the runner asking again): removed.
rm -rf "$L"; out=$(run 'mkdir -p "$HOME/.cache/powos-verify.lock"; echo "verify-queue 11:58:46 (pid $$)" > "$HOME/.cache/powos-verify.lock/who"; window_lock verify-queue 120 60 >/dev/null; echo got=$?')
grep -q 'got=0' <<<"$out" && ok "own leaked lock (same name + pid): removed, the window comes" || bad "own leaked lock" "$out"

# 3. a live owner (another running check) and a pid-less injected check's lock: waited for, never removed.
sleep 300 & live=$!
rm -rf "$L"; mkdir -p "$L"; echo "verify-queue 12:00:00 (pid $live)" > "$L/who"
out=$(run '( window_lock other 120 1 >/dev/null ); echo got=$?')
[ -d "$L" ] && grep -q 'got=3' <<<"$out" && ok "live owner's lock: waited for (exit 3 at max), not removed" || bad "live owner kept" "$out"
kill $live 2>/dev/null
rm -rf "$L"; mkdir -p "$L"; echo "powos-verify journey (A B C) 12:00:00" > "$L/who"
out=$(run '( window_lock other 120 1 >/dev/null ); echo got=$?')
[ -d "$L" ] && grep -q 'got=3' <<<"$out" && ok "pid-less (injected check) lock: never removed" || bad "pid-less kept" "$out"
rm -rf "$L"

# 4. wl_sleep: a restore that fails keeps the saved settings (the next try restores them); one that works removes them.
printf 'b=87\nm=1\nt=60000\nat=%s\n' "$(date +%s)" > "$T/woke"; touch "$T/adb-fails"
out=$(run 'wl_sleep "$WL_PHONE"')
[ -s "$T/woke" ] && grep -q '^t=60000$' "$T/woke" && ok "failed restore: the user's settings kept for the next try" || bad "failed restore keeps save" "$out"
rm -f "$T/adb-fails"; out=$(run 'wl_sleep "$WL_PHONE"')
[ ! -e "$T/woke" ] && grep -q 'restored the phone' <<<"$out" && ok "next try restores and drops the save" || bad "retry restores" "$out"

# 5. queue.sh's window trap releases the lock.
grep -q "trap 'warm_stop; util_rec W \"\$wopen\" \"\$(date +%s)\"; wl_done; wl_release' EXIT" "$src/tools/phone/verify/queue.sh" \
  && ok "queue.sh: the window's EXIT trap ends with wl_release" || bad "queue.sh window trap has wl_release"
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
