#!/bin/bash
# Hermetic test of the ship service (tools/phone/ship.sh) and the one-shipper guards in ship-apk.sh / shell/push.sh:
# a fake origin (bare repo), an agent's clone B, this tree's ship.sh + ship-apk.sh + push.sh, stubs for the gate,
# docker, adb (a folder as the phone's app data), user.sh (mail) and an APK ship that only records itself. Temp HOME:
# nothing reaches the real phone, docker, launchd or ~/.cache.
#   tools/phone/ship-queue-test.sh        exit 0 = all pass
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-queue-test.XXXXXX")
export HOME=$T/home PHONE=$T/phone LOG=$T/log GIT_CONFIG_GLOBAL=$T/gitconfig SHIP_DIR=$T/home/.cache/powos-ship-queue
export SHIP_QUIET_S=3 SHIP_QUIET_SHELL_S=1 SHIP_POLL_S=1
unset POWOS_SHIP_SERVICE SHIP_AGENT
Q=$SHIP_DIR
stop_runner() { local p; p=$(cat "$Q/runner.lock/pid" 2>/dev/null) && kill "$p" 2>/dev/null; pkill -f "$T/" 2>/dev/null; }
trap 'stop_runner; rm -rf "$T"' EXIT
mkdir -p "$HOME/.cache" "$PHONE/files/shell" "$PHONE/tmp" "$T/bin"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
cat > "$T/bin/adb" <<'EOF'
#!/bin/bash
case "$1" in
  connect|-s) exit 0 ;;
  push) shift; [ "$1" = -q ] && shift; cp "$1" "${2/\/data\/local\/tmp/$PHONE/tmp}"; exit ;;
  shell|exec-out) shift; c="$*" ;;
  *) exit 0 ;;
esac
case "$c" in *powos-run.sh*) exit 0 ;; "run-as com.powos.app true") exit 0 ;; esac
c=${c//\/data\/local\/tmp/$PHONE/tmp}; c=${c/run-as com.powos.app /}
case "$c" in *"mv -f shell-staging"*) echo "PUSH" >> "$LOG" ;; *"find . -mindepth 1"*|*"rm -f files/shell/"*) echo "RESET" >> "$LOG" ;; esac
cd "$PHONE" && sh -c "$c"
EOF
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
all="$*"
vol() { local want=$1 prev=""; shift; for a in "$@"; do [ "$prev" = -v ] && [ "${a##*:}" = "$want" ] && echo "${a%:*}"; prev=$a; done; }
case "$all" in
  *SCHEMAS=*) ov=$(vol /ov "$@"); cp -R "$PHONE/files/shell" "$ov/"; cat "$PHONE/files/shell-commits.txt" > "$ov/commits.txt" 2>/dev/null; exit 0 ;;
  *POWOS_GATE_DONE=1*)
    sh=$(vol /shell "$@"); pc=""; prev=""; rest=(); seen=""
    for a in "$@"; do
      [ -n "$seen" ] && rest+=("$a")
      [ "$prev" = -e ] && case "$a" in POWOS_PUSH_COMMITS=*) pc=${a#POWOS_PUSH_COMMITS=} ;; esac
      [ "$a" = _ ] && seen=1; prev=$a
    done
    cd "$sh" && POWOS_GATE_DONE=1 POWOS_PUSH_COMMITS="$pc" exec bash push.sh "${rest[@]}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null; cd "$T/seed"; git checkout -q -b worktree-powos-multiplatform
mkdir -p tools/phone shell/dev shell/ui targets/android/app
cp "$src/tools/phone/ship.sh" "$src/tools/phone/ship-apk.sh" tools/phone/; cp "$src/shell/push.sh" shell/
mv tools/phone/ship-apk.sh tools/phone/ship-apk.real.sh
# The APK ship: records itself (tree, flags, service mark) and the installed commit, as the real one does.
# It holds the ship lock, as the real one does, and waits while $HOME/hold-apk exists (a build / an idle wait).
cat > tools/phone/ship-apk.sh <<'EOF'
#!/bin/bash
l=$HOME/.cache/powos-ship.lock; mkdir "$l" && echo "apk pid $$ x" > "$l/who"
trap 'rm -rf "$l"; [ "$(cat "$SHIP_DIR/installing" 2>/dev/null)" = $$ ] && rm -f "$SHIP_DIR/installing"' EXIT
echo "APKSTART $(git rev-parse HEAD)" >> "$LOG"
while [ -e "$HOME/hold-apk" ]; do sleep 0.3; done
until mkdir "$l/phone" 2>/dev/null; do sleep 0.3; done
# the installing mark + the pause flag, as the real one; APK_INSTALL_S: how long the install takes
echo $$ > "$SHIP_DIR/installing"; [ -e "$SHIP_DIR/paused" ] && exit 7
sleep "${APK_INSTALL_S:-0}"
echo "APK $(git rev-parse HEAD) svc=${POWOS_SHIP_SERVICE:-} $*" >> "$LOG"; git rev-parse HEAD > "$HOME/.cache/powos-installed-commit"
rm -rf "$l"
EOF
cat > shell/dev/gate.sh <<'EOF'
#!/bin/bash
echo "GATE $*" >> "$LOG"
for f in "$@"; do case "$f" in --*) ;; *) grep -q BROKEN "$f" 2>/dev/null && { echo "FAIL home: $f broken"; exit 1; } ;; esac; done
echo "ok all pages"
EOF
printf '#!/bin/bash\n[ "${1:-}" = --remote-cmd ] && echo true; exit 0\n' > tools/phone/bindings-check.sh
printf '#!/bin/bash\necho "MAIL $(cat "$1")" >> "$LOG"\n' > tools/phone/user.sh
printf '.claude/\n' > .gitignore
echo 'export const a = 0' > shell/ui/a.tsx; echo 'export const b = 0' > shell/ui/b.tsx; echo 'export const old = 0' > shell/ui/old.tsx
echo 'class Main' > targets/android/app/Main.kt
chmod +x tools/phone/*.sh shell/dev/gate.sh shell/push.sh
git add -A; git commit -qm base; git push -q origin worktree-powos-multiplatform 2>/dev/null
git rev-parse HEAD > "$HOME/.cache/powos-installed-commit"   # the phone runs base's APK
git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/B" 2>/dev/null
cd "$T/B"
fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails+1)); }
land() { git pull -q --rebase 2>/dev/null; printf '%s\n' "$2" > "$1"; git add -A; git commit -qm "$3"; git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null; }
req() { SHIP_REQUESTER=B bash tools/phone/ship.sh request "$@" > "$T/req.out" 2>&1; }
# drained [s]: every request served within s seconds.
drained() { for _ in $(seq "${1:-40}"); do ls "$Q"/*.req >/dev/null 2>&1 || return 0; sleep 1; done; return 1; }
tip() { git -C "$T/B" rev-parse origin/worktree-powos-multiplatform; }

# 1. Two shell pushes 1 s apart, two requests: ONE push of both files, both notes in one notification, tip recorded.
: > "$LOG"
land shell/ui/a.tsx 'export const a = 1' "a1"; req --note "A is new"
sleep 1; land shell/ui/b.tsx 'export const b = 1' "b1"; req --note "B is new"; t1=$(tip)
grep -q "nothing else to do" "$T/req.out" && ok "request returns at once" || { bad "request"; cat "$T/req.out"; }
drained && ok "both requests served" || { bad "requests left"; cat "$Q/runner.log"; }
[ "$(grep -c '^PUSH' "$LOG")" = 1 ] && ok "one push for two requests" || { bad "pushes: $(grep -c '^PUSH' "$LOG")"; cat "$LOG" "$Q/runner.log"; }
grep -q 'a = 1' "$PHONE/files/shell/ui/a.tsx" && grep -q 'b = 1' "$PHONE/files/shell/ui/b.tsx" && ok "phone has both files" || bad "files on the phone"
grep -q '"note":"A is new; B is new"' "$PHONE/files/shell-push.json" && ok "notes combined" || { bad "note"; cat "$PHONE/files/shell-push.json"; }
[ "$(cat "$Q/live" 2>/dev/null)" = "$t1" ] && ok "live = origin's tip" || bad "live record"
grep -q '^APK' "$LOG" && bad "an APK for shell-only" || ok "no APK for shell-only"

# 2. Kotlin changed + a shell file: the shell file goes at once, then one APK ship from the tip, as the service.
: > "$LOG"
land targets/android/app/Main.kt 'class Main2' "kt"; land shell/ui/a.tsx 'export const a = 2' "a2"; req --silent; t2=$(tip)
drained && ok "APK request served" || bad "APK request left"
grep -q "^APK $t2 svc=1 --silent" "$LOG" && ok "ship-apk from the tip, by the service" || { bad "APK call"; cat "$LOG"; }
[ "$(grep -m1 -E '^(PUSH|APK )' "$LOG")" = PUSH ] && ok "shell pushed before the APK" || { bad "no shell push first"; cat "$LOG"; }
[ "$(cat "$HOME/.cache/powos-installed-commit")" = "$t2" ] && [ "$(cat "$Q/live")" = "$t2" ] && ok "installed + live recorded" || bad "installed record"

# 2b. While an APK builds / waits for idle, a later shell fix is pushed at once and its request is done; the Kotlin
#     request waits for the install.
: > "$LOG"; touch "$HOME/hold-apk"
land targets/android/app/Main.kt 'class Main3' "kt3"; req --note "K"; tk=$(tip)
for _ in $(seq 20); do grep -q '^APKSTART' "$LOG" && break; sleep 1; done
land shell/ui/b.tsx 'export const b = 2' "b2"; req --note "B quick"; t3=$(tip)
for _ in $(seq 15); do grep -q 'b = 2' "$PHONE/files/shell/ui/b.tsx" && break; sleep 1; done
grep -q 'b = 2' "$PHONE/files/shell/ui/b.tsx" && ! grep -q '^APK ' "$LOG" && ok "shell pushed beside the APK ship" || { bad "shell waited for the APK"; cat "$LOG" "$Q/runner.log"; }
grep -q '"note":"B quick"' "$PHONE/files/shell-push.json" && ok "its note alone" || { bad "note"; cat "$PHONE/files/shell-push.json"; }
[ "$(ls "$Q"/*.req 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && ok "both requests wait for the install (B sits on K)" || { bad "requests left: $(ls "$Q"/*.req 2>/dev/null)"; }
rm -f "$HOME/hold-apk"
drained && grep -q "^APK $tk svc=1 --note K\$" "$LOG" && ok "APK installed with K's note only, requests done" || { bad "APK not done"; cat "$LOG" "$Q/runner.log"; }

# 3. The verify lock holds a shell ship; a deleted file is reset on the phone.
: > "$LOG"; mkdir "$HOME/.cache/powos-verify.lock"; echo "verify-queue test" > "$HOME/.cache/powos-verify.lock/who"
cp shell/ui/old.tsx "$PHONE/files/shell/ui/old.tsx"   # an override of it is live
git rm -q shell/ui/old.tsx; land shell/ui/b.tsx 'export const b = 3' "b3 + rm old"; req --note "B again"
sleep $((SHIP_QUIET_S + 3))
grep -q '^PUSH' "$LOG" && bad "pushed while the verify lock was held" || ok "waits for the verify lock"
rm -rf "$HOME/.cache/powos-verify.lock"
drained && grep -q '^PUSH' "$LOG" && ok "ships once it's free" || bad "not shipped after the lock"
[ ! -e "$PHONE/files/shell/ui/old.tsx" ] && ok "deleted file reset on the phone" || bad "old.tsx still overridden"

# 4. A request from an unpushed commit is refused.
echo 'export const a = 9' > shell/ui/a.tsx; git commit -qam local
req --note x; rc=$?
[ $rc = 3 ] && grep -q "push it first" "$T/req.out" && ok "unpushed request refused" || { bad "unpushed request rc $rc"; cat "$T/req.out"; }
git reset -q --hard origin/worktree-powos-multiplatform

# 5. The guards: agents can't ship by hand; --direct from the tip works and is logged; --direct behind is refused.
out=$(cd shell && ./push.sh --vpn --note x ui/a.tsx 2>&1); rc=$?
[ $rc = 3 ] && echo "$out" | grep -q "agents don't ship" && ok "push.sh refused outside the service" || { bad "push.sh guard rc $rc"; echo "$out"; }
out=$(cd shell && ./push.sh --vpn --direct --note x ui/a.tsx 2>&1); rc=$?
[ $rc = 0 ] && grep -q 'push.sh --direct' "$Q/direct.log" && ok "push.sh --direct pushes, logged" || { bad "--direct rc $rc"; echo "$out"; }
out=$(cd shell && ./push.sh --errors 2>&1); rc=$?
[ $rc = 0 ] && ok "--errors needs no service" || { bad "--errors rc $rc"; echo "$out"; }
git checkout -q HEAD~1
out=$(cd shell && ./push.sh --vpn --direct --note x ui/a.tsx 2>&1); rc=$?
[ $rc = 3 ] && echo "$out" | grep -q "isn't origin" && ok "--direct behind the tip refused" || { bad "--direct behind rc $rc"; echo "$out"; }
git checkout -q worktree-powos-multiplatform
out=$(SHIP_APK_CURRENT=1 bash tools/phone/ship-apk.real.sh --note x 2>&1); rc=$?
[ $rc = 3 ] && echo "$out" | grep -q "agents don't ship" && ok "ship-apk refused outside the service" || { bad "ship-apk guard rc $rc"; echo "$out"; }
git checkout -q HEAD~1   # behind: logged, then refused before any build
out=$(SHIP_APK_CURRENT=1 bash tools/phone/ship-apk.real.sh --direct --note x 2>&1); rc=$?
[ $rc = 3 ] && grep -q 'ship-apk --direct' "$Q/direct.log" && ok "ship-apk --direct logged (then its tip check)" || { bad "ship-apk --direct rc $rc"; echo "$out"; }
git checkout -q worktree-powos-multiplatform

# 6. A ship that fails: mailed once, not retried on the same tip; a fix on origin ships.
: > "$LOG"
land shell/ui/a.tsx 'BROKEN' "broken"; req --note "broken"; tb=$(tip)
for _ in $(seq 30); do [ "$(cat "$Q/failed" 2>/dev/null)" = "$tb" ] && break; sleep 1; done
sleep 3
[ "$(cat "$Q/failed" 2>/dev/null)" = "$tb" ] && [ "$(grep -c '^MAIL.*FAILED' "$LOG")" = 1 ] && ! grep -q '^PUSH' "$LOG" && ok "failed ship: mailed once, nothing pushed" || { bad "failed ship"; cat "$LOG"; }
[ "$(grep -c '^GATE' "$LOG")" -le 3 ] && ok "not retried on the same tip" || bad "retried: $(grep -c '^GATE' "$LOG") gates"
land shell/ui/a.tsx 'export const a = 6' "fix"
drained && grep -q 'a = 6' "$PHONE/files/shell/ui/a.tsx" && ok "the fix ships, both requests done" || { bad "fix not shipped"; cat "$Q/runner.log"; }

# 7. pause / resume: a ship still building is stopped (lock freed, request kept); an install in flight finishes.
: > "$LOG"; touch "$HOME/hold-apk"
land targets/android/app/Main.kt 'class Main7' "kt7"; req --note "seven"; t7=$(tip)
for _ in $(seq 40); do grep -q '^APKSTART' "$LOG" && break; sleep 1; done
out=$(bash tools/phone/ship.sh pause --why "test")
echo "$out" | grep -q "was stopped" && ok "pause stops the building ship" || { bad "pause: $out"; tail -5 "$Q/runner.log"; }
for _ in $(seq 15); do [ -d "$HOME/.cache/powos-ship.lock" ] || [ -n "$(cat "$Q/runner.lock/pid" 2>/dev/null)" ] || break; sleep 1; done
[ ! -d "$HOME/.cache/powos-ship.lock" ] && ls "$Q"/*.req >/dev/null 2>&1 && ! grep -q "^APK $t7" "$LOG" && [ ! -s "$Q/failed-apk" ] &&
  ok "lock freed, request kept, nothing installed, not marked failed" || { bad "after pause"; cat "$LOG"; ls "$Q"; tail -5 "$Q/runner.log"; }
st=$(bash tools/phone/ship.sh status); grep -q '^PAUSED.*test' <<<"$st" && ok "status says PAUSED with reason" || { bad "status"; echo "$st"; }
rm -f "$HOME/hold-apk"; req --note "eight"; sleep $((SHIP_QUIET_S + 3))
[ "$(grep -c '^APKSTART' "$LOG")" = 1 ] && ok "no ship starts while paused" || { bad "shipped while paused"; cat "$LOG"; }
export APK_INSTALL_S=8
bash tools/phone/ship.sh resume >/dev/null
for _ in $(seq 40); do [ -s "$Q/installing" ] && break; sleep 1; done
out=$(bash tools/phone/ship.sh pause --why "test")
echo "$out" | grep -q "install is in flight" && ok "pause during an install lets it run" || bad "pause mid-install: $out"
drained 30 && grep -q "^APK $t7 svc=1" "$LOG" && ok "the install finished, its requests done" || { bad "install in flight"; cat "$LOG"; ls "$Q"; }
bash tools/phone/ship.sh resume >/dev/null; export APK_INSTALL_S=0

# 8. A stopped runner (launchctl bootout = TERM) takes its building APK ship with it: no ship-apk left to install.
: > "$LOG"; touch "$HOME/hold-apk"
land targets/android/app/Main.kt 'class Main8' "kt8"; req --note "nine"
for _ in $(seq 40); do grep -q '^APKSTART' "$LOG" && break; sleep 1; done
kill "$(cat "$Q/runner.lock/pid")"; sleep 3
! pgrep -f "$T/.*ship-apk.sh" >/dev/null && [ ! -d "$HOME/.cache/powos-ship.lock" ] && ls "$Q"/*.req >/dev/null 2>&1 &&
  ok "TERM stops the APK ship too (lock freed, request kept)" || { bad "TERM left: $(pgrep -fl "$T/.*ship-apk.sh")"; }
rm -f "$HOME/hold-apk"; bash tools/phone/ship.sh resume >/dev/null; drained 40 || bad "kt8 not shipped after the restart"

for _ in $(seq 15); do [ -n "$(cat "$Q/runner.lock/pid" 2>/dev/null)" ] || break; sleep 1; done
runner_left=$(cat "$Q/runner.lock/pid" 2>/dev/null)
[ -z "$runner_left" ] && ok "runner exits when nothing is requested" || bad "runner still up ($runner_left)"
[ $fails -eq 0 ] && echo "all pass" || { echo "$fails failed"; echo "--- runner.log"; cat "$Q/runner.log"; }
exit $fails
