#!/bin/bash
# Hermetic test of ship.sh's "pkgs" step (11-10: kwin 3.76's PKGBUILD shipped as code, no package was ever built or
# published, the phone stayed on 3.74). A commit changing targets/android/pkgs/<name>/ builds + publishes exactly those
# packages (SHIP_PKGS_BUILD stub: logs PKGS, writes out/pkgs/<name>-...pkg.tar.xz, fails on PKGS_BROKEN), copies the
# build into the ship checkout's out/pkgs, and only THEN runs the rooted deploy (which installs from there).
# Built from test-ship-rooted.sh's harness; its header follows.
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
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-pkgs-test.XXXXXX")
export HOME=$T/home LOG=$T/log GIT_CONFIG_GLOBAL=$T/gitconfig SHIP_DIR=$T/home/.cache/powos-ship-queue
export SHIP_QUIET_S=3 SHIP_QUIET_SHELL_S=1 SHIP_POLL_S=1
export SHIP_GATE_FIRST=1   # these tests cover the gate-then-push mode; deploy-first is the default
# The phone's VPN link (ship.sh phone_offline): $HOME/phone-offline = adb.sh --vpn-state's rc 69 (handshake stale).
export SHIP_PHONE_STATE=$T/bin/phone-state SHIP_OFFLINE_POLL_S=1
unset POWOS_SHIP_SERVICE SHIP_AGENT
Q=$SHIP_DIR
stop_runner() { local p; p=$(cat "$Q/runner.lock/pid" 2>/dev/null) && kill "$p" 2>/dev/null; pkill -f "$T/" 2>/dev/null; }
trap 'stop_runner; rm -rf "$T"' EXIT
mkdir -p "$HOME/.cache" "$T/bin"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
printf '#!/bin/bash\nexit 0\n' > "$T/bin/adb"; chmod +x "$T/bin/adb"
printf '#!/bin/bash\n[ -e "$HOME/phone-offline" ] && { echo vpn=offline; exit 69; }; echo vpn=up\n' > "$T/bin/phone-state"; chmod +x "$T/bin/phone-state"
cat > "$T/bin/pkgs-build" <<'PKGS'
#!/bin/bash
echo "PKGS $(git rev-parse HEAD) $*" >> "$LOG"
for n in "$@"; do grep -q PKGS_BROKEN "targets/android/pkgs/$n/PKGBUILD" && { echo "makepkg failed: $n"; exit 1; }
  r=$(sed -n 's/^pkgrel=//p' "targets/android/pkgs/$n/PKGBUILD")
  mkdir -p targets/android/out/pkgs; : > "targets/android/out/pkgs/$n-1.0-$r-aarch64.pkg.tar.xz"; done
PKGS
chmod +x "$T/bin/pkgs-build"; export SHIP_PKGS_BUILD=$T/bin/pkgs-build
export PATH="$T/bin:$PATH"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
(
  cd "$T/seed" && git checkout -q -b main
  mkdir -p tools/phone shell/dev targets/android/app targets/android/rooted targets/android/tools targets/android/pkgs/kwin/test
  cp "$src/tools/phone/ship.sh" tools/phone/ship.sh
  cp "$src/targets/android/tools/newest-pkgs.sh" targets/android/tools/newest-pkgs.sh
  printf 'pkgname=kwin\npkgrel=3.74\n' > targets/android/pkgs/kwin/PKGBUILD
  echo t > targets/android/pkgs/kwin/test/t.sh
  printf 'out/\n' > targets/android/.gitignore
  printf '#!/bin/bash\necho "ok all pages"\n' > shell/dev/gate.sh
  printf '#!/bin/bash\nexit 0\n' > tools/phone/bindings-check.sh
  printf '#!/bin/bash\necho "MAIL $(cat "$1")" >> "$LOG"\n' > tools/phone/user.sh
  printf '#!/bin/bash\nexit 1\n' > tools/phone/ship-apk.sh   # not exercised here (no Kotlin commit); refuses if it were
  # The rooted deploy stub: records the tip + its exact args, "fails" when the committed powos-run.sh it just
  # deployed is marked ROOTED_BROKEN.
  cat > targets/android/rooted/rooted.sh <<'ROOTED'
#!/bin/bash
echo "ROOTED $(git rev-parse HEAD) $*" >> "$LOG"
# $HOME/deploy-offline: the phone drops off the VPN during the deploy - adb.sh's rc 69 (11-06 15:02).
[ -e "$HOME/deploy-offline" ] && { echo "adb.sh: phone offline: its WireGuard handshake is 1913s old (> 180s) - not running adb" >&2; exit 69; }
grep -q ROOTED_BROKEN targets/android/rooted/powos-run.sh 2>/dev/null && exit 1
exit 0
ROOTED
  # units_gate's checks (6cdd4f82: the real ones read this repo's units/) run before every rooted deploy: they pass
  # here, as in tools/phone/ship-queue-test.sh - the rooted deploy itself is what's tested.
  mkdir -p test/tier1; for t in test-units-registry.py test-powos-dispatch.py; do echo 'print("ok")' > "test/tier1/$t"; done
  chmod +x shell/dev/gate.sh tools/phone/*.sh targets/android/rooted/rooted.sh
  echo "x" > NOTES.txt
  echo "guard" > targets/android/rooted/powos-run.sh
  printf '.claude/\n' > .gitignore   # the ship service's own checkout (.claude/worktrees/ship-runner) lives inside $T/B
  git add -A && git commit -qm base && git push -q origin main 2>/dev/null
)
# A baseline "installed APK" commit: without it, pending_apk() forces an APK ship on EVERY request
# ("[ -z "$inst" ] || ..." in ship.sh - empty means no record yet, so everything is pending), which the
# ship-apk.sh stub above always fails, leaving every request stuck forever - unrelated to what this test checks,
# as ship-queue-test.sh's own seed records the same baseline for the same reason.
git -C "$T/seed" rev-parse HEAD > "$HOME/.cache/powos-installed-commit"
git clone -q -b main "$T/origin.git" "$T/B" 2>/dev/null
cd "$T/B"

fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails + 1)); }
land() { git pull -q --rebase 2>/dev/null; printf '%s\n' "$2" > "$1"; git add -A; git commit -qm "$3"; git push -q origin HEAD:main 2>/dev/null; }
req() { SHIP_REQUESTER=B bash tools/phone/ship.sh request "$@" > "$T/req.out" 2>&1; }
drained() { for _ in $(seq "${1:-40}"); do ls "$Q"/*.req >/dev/null 2>&1 || return 0; sleep 1; done; return 1; }
tip() { git -C "$T/B" rev-parse origin/main; }
wait_for() { for _ in $(seq "${2:-20}"); do eval "$1" && return 0; sleep 1; done; return 1; }
SRP=$HOME/pw/ship-runner/targets/android/out/pkgs

# 1. A commit outside targets/android/pkgs (or only a package's test/) builds nothing.
: > "$LOG"
land NOTES.txt "y" "unrelated change"; land targets/android/pkgs/kwin/test/t.sh "t2" "kwin test only"; req --note "unrelated"
drained && ok "unrelated request served" || { bad "unrelated request left"; cat "$Q/runner.log"; }
wait_for 'false' 5
grep -q '^PKGS' "$LOG" && bad "a package was built for an unrelated / test-only commit" || ok "no packages build for unrelated / test-only commits"

# 2. A PKGBUILD bump builds that package once, publishes it into the ship checkout's out/pkgs, records pkgs-live,
#    and the rooted deploy runs AFTER the build.
: > "$LOG"
land targets/android/pkgs/kwin/PKGBUILD "$(printf 'pkgname=kwin\npkgrel=3.76')" "kwin 3.76"; req --note "kwin 3.76"; tk=$(tip)
wait_for "grep -q '^ROOTED $tk' \"\$LOG\"" 40
[ "$(grep -c '^PKGS' "$LOG")" = 1 ] && grep -qx "PKGS $tk kwin" "$LOG" && ok "kwin built once, on the tip" || { bad "packages build: $(grep '^PKGS' "$LOG")"; tail -8 "$Q/runner.log"; }
pl=$(grep -n '^PKGS' "$LOG" | head -1 | cut -d: -f1); rl=$(grep -n '^ROOTED' "$LOG" | head -1 | cut -d: -f1)
[ -n "$pl" ] && [ -n "$rl" ] && [ "$pl" -lt "$rl" ] && ok "the rooted deploy ran after the build" || { bad "order: PKGS line ${pl:-none}, ROOTED line ${rl:-none}"; cat "$LOG"; }
[ -e "$SRP/kwin-1.0-3.76-aarch64.pkg.tar.xz" ] && ok "the build is in the ship checkout's out/pkgs" || { bad "not copied to $SRP"; ls "$SRP" 2>&1; }
wait_for "[ \"\$(cat \"\$Q/pkgs-live\" 2>/dev/null)\" = \"$tk\" ]" 5 && ok "pkgs-live recorded" || bad "pkgs-live: $(cat "$Q/pkgs-live" 2>/dev/null)"

# 3. A broken PKGBUILD: build failed, mailed once, not retried on that tip; the fix builds.
: > "$LOG"
land targets/android/pkgs/kwin/PKGBUILD "$(printf 'pkgname=kwin\npkgrel=3.77\nPKGS_BROKEN')" "broken kwin"; req --note "broken"; tb=$(tip)
wait_for "[ \"\$(cat \"\$Q/failed-pkgs\" 2>/dev/null)\" = \"$tb\" ]" 60 && ok "failed build recorded against the tip" || { bad "not marked failed (failed-pkgs: $(cat "$Q/failed-pkgs" 2>/dev/null), tb $tb)"; cat "$LOG"; tail -12 "$Q/runner.log"; }
wait_for "grep -q '^MAIL.*pkgs:kwin.*FAILED' \"\$LOG\"" 10
wait_for 'false' 4
[ "$(grep -c '^MAIL.*pkgs.*FAILED' "$LOG")" = 1 ] && [ "$(grep -c '^PKGS' "$LOG")" = 1 ] && ok "mailed once, not retried" || { bad "mails/builds: $(grep -c '^MAIL' "$LOG")/$(grep -c '^PKGS' "$LOG")"; cat "$LOG"; }
land targets/android/pkgs/kwin/PKGBUILD "$(printf 'pkgname=kwin\npkgrel=3.78')" "fixed kwin"; req --note "fix"; tf=$(tip)
wait_for "grep -qx 'PKGS $tf kwin' \"\$LOG\"" 30 && wait_for "[ -e \"$SRP/kwin-1.0-3.78-aarch64.pkg.tar.xz\" ]" 5 && ok "the fix builds" || { bad "fix not built"; cat "$LOG"; tail -8 "$Q/runner.log"; }

# 4. The real build path never wraps build-pkgs.sh in build-slot.sh: build-pkgs.sh takes the heavy slot itself, so an
#    outer holder waits on its own inner request forever (11-10: a hand-run kwin build sat 50 min that way).
grep -nE 'build-slot\.sh[^#]*build-pkgs\.sh' "$src/tools/phone/ship.sh" | grep -v '^[0-9]*: *#' && bad "ship.sh wraps build-pkgs.sh in build-slot.sh (deadlock)" ||
  ok "build-pkgs.sh is not wrapped in build-slot.sh"
grep -q 'build-slot' "$src/targets/android/build-pkgs.sh" && ok "build-pkgs.sh takes the slot itself" || bad "build-pkgs.sh no longer takes the build slot - ship.sh's packages build runs unslotted"
for _ in $(seq 15); do [ -n "$(cat "$Q/runner.lock/pid" 2>/dev/null)" ] || break; sleep 1; done
echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
