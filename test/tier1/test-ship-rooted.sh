#!/bin/bash
# Hermetic test of ship.sh's "rooted" ship kind (friction f105, part 1 - the rooted part; the "apps" kind above it
# in ship.sh, f105 part 2, is separate and already covered by its own behaviour). The ship service used to ship
# only the shell and the APK; a commit that changes targets/android/rooted/* (or the other small files
# targets/android/rooted/rooted.sh deploy installs) must also run `rooted.sh deploy`, after the APK, mirroring
# exactly how the "apps" kind runs: `rooted_inputs()` diffed against the last tip rooted.sh was run for
# ($Q/rooted-live, like $Q/apps-live), under the same busy-phone/verify-lock rules, not retried on a tip that
# failed ($Q/failed-rooted, like $Q/failed-apps).
#   test/tier1/test-ship-rooted.sh        exit 0 = all pass
# Stubs adb, shell/dev/gate.sh, ship-apk.sh, user.sh (mail) and rooted.sh itself (records the call, "fails" when
# the committed file it just deployed is marked ROOTED_BROKEN - a file check, not an env var: the ship runner is
# one long-lived background process for the whole test, so it never re-reads a shell var the test script exports
# after the fact; it DOES freshly read whatever origin's tip has) in a temp HOME/origin, as
# tools/phone/ship-queue-test.sh does for the shell/APK/apps kinds. Every commit here avoids shell/ and apps/ so
# only the new rooted step is exercised. Nothing reaches the real phone, docker, launchd or ~/.cache.
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-rooted-test.XXXXXX")
export HOME=$T/home LOG=$T/log GIT_CONFIG_GLOBAL=$T/gitconfig SHIP_DIR=$T/home/.cache/powos-ship-queue
export SHIP_QUIET_S=3 SHIP_QUIET_SHELL_S=1 SHIP_POLL_S=1
unset POWOS_SHIP_SERVICE SHIP_AGENT
Q=$SHIP_DIR
stop_runner() { local p; p=$(cat "$Q/runner.lock/pid" 2>/dev/null) && kill "$p" 2>/dev/null; pkill -f "$T/" 2>/dev/null; }
trap 'stop_runner; rm -rf "$T"' EXIT
mkdir -p "$HOME/.cache" "$T/bin"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
printf '#!/bin/bash\nexit 0\n' > "$T/bin/adb"; chmod +x "$T/bin/adb"
export PATH="$T/bin:$PATH"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
(
  cd "$T/seed" && git checkout -q -b worktree-powos-multiplatform
  mkdir -p tools/phone shell/dev targets/android/app targets/android/rooted
  cp "$src/tools/phone/ship.sh" tools/phone/ship.sh
  printf '#!/bin/bash\necho "ok all pages"\n' > shell/dev/gate.sh
  printf '#!/bin/bash\nexit 0\n' > tools/phone/bindings-check.sh
  printf '#!/bin/bash\necho "MAIL $(cat "$1")" >> "$LOG"\n' > tools/phone/user.sh
  printf '#!/bin/bash\nexit 1\n' > tools/phone/ship-apk.sh   # not exercised here (no Kotlin commit); refuses if it were
  # The rooted deploy stub: records the tip + its exact args, "fails" when the committed powos-run.sh it just
  # deployed is marked ROOTED_BROKEN.
  cat > targets/android/rooted/rooted.sh <<'ROOTED'
#!/bin/bash
echo "ROOTED $(git rev-parse HEAD) $*" >> "$LOG"
grep -q ROOTED_BROKEN targets/android/rooted/powos-run.sh 2>/dev/null && exit 1
exit 0
ROOTED
  chmod +x shell/dev/gate.sh tools/phone/*.sh targets/android/rooted/rooted.sh
  echo "x" > NOTES.txt
  echo "guard" > targets/android/rooted/powos-run.sh
  printf '.claude/\n' > .gitignore   # the ship service's own checkout (.claude/worktrees/ship-runner) lives inside $T/B
  git add -A && git commit -qm base && git push -q origin worktree-powos-multiplatform 2>/dev/null
)
# A baseline "installed APK" commit: without it, pending_apk() forces an APK ship on EVERY request
# ("[ -z "$inst" ] || ..." in ship.sh - empty means no record yet, so everything is pending), which the
# ship-apk.sh stub above always fails, leaving every request stuck forever - unrelated to what this test checks,
# as ship-queue-test.sh's own seed records the same baseline for the same reason.
git -C "$T/seed" rev-parse HEAD > "$HOME/.cache/powos-installed-commit"
git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/B" 2>/dev/null
cd "$T/B"

fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails + 1)); }
land() { git pull -q --rebase 2>/dev/null; printf '%s\n' "$2" > "$1"; git add -A; git commit -qm "$3"; git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null; }
req() { SHIP_REQUESTER=B bash tools/phone/ship.sh request "$@" > "$T/req.out" 2>&1; }
drained() { for _ in $(seq "${1:-40}"); do ls "$Q"/*.req >/dev/null 2>&1 || return 0; sleep 1; done; return 1; }
tip() { git -C "$T/B" rev-parse origin/worktree-powos-multiplatform; }
wait_for() { for _ in $(seq "${2:-20}"); do eval "$1" && return 0; sleep 1; done; return 1; }   # wait for a shell test to pass

# 1. A commit that doesn't touch any of rooted.sh deploy's inputs never triggers a rooted deploy.
: > "$LOG"
land NOTES.txt "y" "unrelated change"; req --note "unrelated"
drained && ok "unrelated request served" || { bad "unrelated request left"; cat "$Q/runner.log"; }
wait_for 'true' 2   # let the (empty) rooted step's debounce window pass too
grep -q '^ROOTED' "$LOG" && bad "rooted deploy ran for an unrelated commit" || ok "no rooted deploy for an unrelated commit"

# 2. A commit touching targets/android/rooted/* runs rooted.sh deploy exactly once, with a note, against this
#    tip, and records it as the last tip rooted-deployed ($Q/rooted-live).
: > "$LOG"
land targets/android/rooted/powos-run.sh "guard v2" "rooted change"; req --note "rooted fix"; tr1=$(tip)
drained && ok "rooted request served" || { bad "rooted request left"; cat "$Q/runner.log"; }
wait_for "grep -q '^ROOTED $tr1' \"\$LOG\""
[ "$(grep -c '^ROOTED' "$LOG")" = 1 ] && ok "rooted deploy ran exactly once" || { bad "rooted deploy count: $(grep -c '^ROOTED' "$LOG")"; cat "$LOG"; }
grep -qF "ROOTED $tr1 deploy --note rooted fix" "$LOG" && ok "deploy, with the request's note, passed through" || { bad "rooted deploy args"; cat "$LOG"; }
[ "$(cat "$Q/rooted-live" 2>/dev/null)" = "$tr1" ] && ok "the deployed tip is recorded" || bad "rooted-live not recorded"

# 3. Shipping a follow-up with nothing rooted-relevant in it never re-runs the deploy.
: > "$LOG"
land NOTES.txt "z" "another unrelated change"; req --note "unrelated2"
drained && ok "follow-up request served" || bad "follow-up request left"
wait_for 'true' 2
grep -q '^ROOTED' "$LOG" && bad "rooted deploy re-ran with nothing rooted-relevant new" || ok "not re-run with nothing new"

# 4. A failed rooted deploy is mailed once and NOT retried on the same tip; a fix on origin ships it, once.
: > "$LOG"
land targets/android/rooted/powos-run.sh "guard v3 ROOTED_BROKEN" "broken rooted change"; req --note "broken"; tb=$(tip)
wait_for "[ \"\$(cat \"\$Q/failed-rooted\" 2>/dev/null)\" = \"\$tb\" ]" 20
[ "$(cat "$Q/failed-rooted" 2>/dev/null)" = "$tb" ] && ok "failed rooted deploy recorded against this tip" || { bad "not marked failed"; cat "$LOG"; }
wait_for "grep -q '^MAIL.*rooted.*FAILED' \"\$LOG\"" 10   # failed-rooted is written just before mail()
[ "$(grep -c '^MAIL.*rooted.*FAILED' "$LOG")" = 1 ] && ok "mailed once" || { bad "mail count"; cat "$LOG"; }
wait_for "[ \"\$(grep -c '^ROOTED' \"\$LOG\")\" = 1 ]" 10
[ "$(grep -c '^ROOTED' "$LOG")" = 1 ] && ok "not retried on the same (failed) tip" || bad "retried: $(grep -c '^ROOTED' "$LOG") calls"
# request completion is decoupled from the rooted step (it closes via the ordinary shell "nothing differs" path
# regardless of rooted's outcome, same as the "apps" kind above it) - so the broken request is already done_req'd
# and the runner has nothing queued and exits; a fresh request is what gives it a reason to look at the new tip.
land targets/android/rooted/powos-run.sh "guard v4 fixed" "fix rooted change"; req --note "fix"
drained && wait_for "[ \"\$(grep -c '^ROOTED' \"\$LOG\")\" = 2 ]" 20 && ok "the fix ships (one more rooted deploy)" || { bad "fix not shipped"; cat "$LOG" "$Q/runner.log"; }

for _ in $(seq 15); do [ -n "$(cat "$Q/runner.lock/pid" 2>/dev/null)" ] || break; sleep 1; done
echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
