#!/bin/bash
# test-ship-window-wake.sh: the ship's device window check (tools/phone/verify/window-render.sh --hidden) on a dozing
# phone (11-02: the ship service waited all night for an awake phone). The user idle >= WR_WAKE_IDLE_S (600) s ->
# the check wakes the screen (as ship-guard.sh's boot check does), JUDGES, and puts it back to sleep; the user
# active (idle 60 s) -> never woken, NOT JUDGED (exit 2). A fake adb.sh/idle.sh (WR_TOOLS) stands in for the phone. The
# user opening/closing a window during the check: NOT JUDGED too (11-03).
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-wake-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }

mkdir -p "$T/tools"
# The phone: its power state in $T/wake, every adb call logged to $T/adb.log. PowOS "not installed" (empty pm path):
# a judged FAIL right after the start check - what tells a judged run (exit 1) from NOT JUDGED (exit 2).
cat > "$T/tools/adb.sh" <<EOF2
#!/bin/bash
echo "\$*" >> "$T/adb.log"
case "\$*" in
  get-state*) echo device ;;
  *KEYCODE_WAKEUP*) echo Awake > "$T/wake" ;;
  *KEYCODE_SLEEP*) echo Dozing > "$T/wake" ;;
  *mWakefulness=*) echo "mWakefulness=\$(cat "$T/wake")" ;;
  *isKeyguardShowing*) [ "\$(cat "$T/wake")" = Awake ] && echo isKeyguardShowing=false || echo isKeyguardShowing=true ;;
  */proc/interrupts*) echo 4242 ;;
esac
exit 0
EOF2
cat > "$T/tools/idle.sh" <<EOF2
#!/bin/bash
echo "idle=\$(cat "$T/idle") screen=\$(cat "$T/wake") act=0"
EOF2
printf '#!/bin/bash\necho null\n' > "$T/tools/cdp.sh"
chmod +x "$T/tools/"*.sh

run() {   # run IDLE_S: a dozing phone, the user idle IDLE_S s -> rc in $rc, the check's output in $out
  echo Dozing > "$T/wake"; echo "$1" > "$T/idle"; : > "$T/adb.log"
  out=$(WR_TOOLS=$T/tools WR_OUT=$T/out WR_TIMEOUT_S=30 bash "$src/tools/phone/verify/window-render.sh" --hidden 2>&1); rc=$?
}

run 900
if [ $rc = 1 ] && grep -q 'woke the Dozing screen' <<<"$out" && grep -q "PowOS isn't installed" <<<"$out"; then
  ok "dozing + user idle 900 s: woken and judged (rc 1 on the fixture's missing PowOS, not NOT JUDGED)"
else bad "dozing + user idle 900 s: woken and judged" "rc=$rc"$'\n'"$out"; fi
grep -q KEYCODE_WAKEUP "$T/adb.log" && grep -q KEYCODE_SLEEP "$T/adb.log" && [ "$(cat "$T/wake")" = Dozing ] \
  && ok "the screen it woke goes back to sleep" || bad "the screen it woke goes back to sleep" "$(cat "$T/adb.log")"
grep -qiE 'settings put|svc power|stayon' "$T/adb.log" && bad "no setting changed" "$(cat "$T/adb.log")" || ok "no setting changed"

run 60
if [ $rc = 2 ] && grep -q 'NOT JUDGED (the phone is Dozing)' <<<"$out" && ! grep -q KEYCODE_WAKEUP "$T/adb.log"; then
  ok "dozing + user idle 60 s: not woken, NOT JUDGED (waits)"
else bad "dozing + user idle 60 s: not woken, NOT JUDGED" "rc=$rc"$'\n'"$out"$'\n'"$(cat "$T/adb.log")"; fi

# The user's page's window list changed during the check (11-03 241478a42: they closed a window, '2:-2,2' -> '1:2'):
# the user's action - NOT JUDGED (exit 2, ship.sh window_gate waits and retries), never a FAIL. Unchanged: goes on.
awk '/^windows_same\(\) \{/,/^\}/' "$src/tools/phone/verify/window-render.sh" > "$T/wsame.sh"
wsame() {   # wsame WL0 WL1: window-render.sh's own windows_same, with log/hclean stubbed -> rc in $rc, output in $out
  out=$(OUT=$T/out bash -c 'log() { echo "$*"; }; hclean() { echo hclean; }; . "$1" || exit 9
    type windows_same >/dev/null || exit 9; windows_same "$2" "$3"; echo "went on"' _ "$T/wsame.sh" "$1" "$2" 2>&1); rc=$?
}
wsame '2:-2,2' '1:2'
if [ $rc = 2 ] && grep -q '^window-render: NOT JUDGED (the user changed their windows)' <<<"$out" && grep -q hclean <<<"$out" \
   && ! grep -q 'went on\|FAIL' <<<"$out"; then ok "the user closed a window during the check: NOT JUDGED (waits), not FAIL"
else bad "the user closed a window during the check: NOT JUDGED" "rc=$rc"$'\n'"$out"; fi
wsame '1:2' '1:2'
[ $rc = 0 ] && grep -q 'went on' <<<"$out" && ok "the window list unchanged: the check goes on" || bad "the window list unchanged: goes on" "rc=$rc"$'\n'"$out"
grep -q '^  windows_same "\$wl0" "\$wl1"$' "$src/tools/phone/verify/window-render.sh" \
  && ok "the hidden check compares the user's windows through windows_same" || bad "the hidden check calls windows_same"
# ship.sh window_gate: rc 2 waits (requests kept, no window-failed), only another rc marks WINDOWS BROKEN.
awk '/^  window_gate\(\) \{/,/^  \}/' "$src/tools/phone/ship.sh" | grep -A4 'if \[ \$wrc = 2 \]' | grep -q 'return 2' \
  && ok "ship.sh: a NOT JUDGED check (rc 2) waits, not WINDOWS BROKEN" || bad "ship.sh: rc 2 waits"

# Exercise the real reap/check functions with an isolated Git history; no runner/device operations.
(
  export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME/.cache" "$T/repo"; cd "$T/repo" || exit 1
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p shell/ui shell/dev shell/test targets/android/app/assets/widgets
  echo original > shell/ui/home.tsx; git add .; git commit -qm A; A=$(git rev-parse HEAD)
  echo widget > targets/android/app/assets/widgets/example.owl; git add .; git commit -qm B; B=$(git rev-parse HEAD)
  echo dev > shell/dev/check; echo test > shell/test/check; echo generated > shell/shell-build.txt
  echo tooling > shell/push.sh; git add .; git commit -qm nonpayload; Bmeta=$(git rev-parse HEAD)
  echo changed > shell/ui/home.tsx; git add .; git commit -qm C; C=$(git rev-parse HEAD)
  Q="$T/reap"; mkdir -p "$Q/apk" "$Q/done"
  # Source only production function definitions (not the runner's dispatch).
  eval "$(sed -n '/^  shell_diff() {/,/^  apk_inputs() /p' "$src/tools/phone/ship.sh")"
  eval "$(sed -n '/^  shell_check() {/,/^  own_apk() /p' "$src/tools/phone/ship.sh")"
  eval "$(sed -n '/^  reap_apk_installed() {/,/^  }/p' "$src/tools/phone/ship.sh")"
  served_shell() { echo "$A"; }
  mail() { echo "$*" >> "$Q/mail"; }
  units_publish() { :; }; render_watch() { :; }; e2e_round() { :; }
  done_req() { mv "$1" "$Q/done/"; }
  window_gate() { return "$verdict"; }
  expect() { "$@" || exit 1; }
  shell_contains "$Bmeta" "$A" || exit 1
  expect test -z "$(delta "$A" "$Bmeta")"
  if shell_contains "$C" "$A"; then exit 1; fi
  # Legacy inflated live B also converges without a false reapply. Two unjudged retries then PASS.
  echo "$B" > "$Q/live"; echo "$A" > "$Q/apk/shell-tip"
  printf 'sha=%s\n' "$A" > "$Q/a.req"; printf 'sha=%s\n' "$B" > "$Q/widget.req"
  for verdict in 2 2; do
    reap_apk_installed "$A"; rc=$?
    expect test "$rc" = 2; expect test -f "$Q/a.req"; expect test -f "$Q/widget.req"
    expect test ! -f "$Q/failed-apk"; expect test ! -f "$Q/mail"
  done
  verdict=0; reap_apk_installed "$A" || exit 1
  expect test "$(cat "$Q/live")" = "$A"
  expect test -f "$Q/done/a.req"; expect test -f "$Q/widget.req"
  expect test ! -f "$Q/failed-apk"; expect test ! -f "$Q/mail"
  inst=$A; pending_apk "$B" || exit 1
  # A real newer shell still fails/reapplies, and is NOT labelled a window failure.
  rm -f "$Q/apk/shell-want"
  echo "$C" > "$Q/live"; printf 'sha=%s\n' "$A" > "$Q/a.req"
  verdict=2; reap_apk_installed "$A"; expect test "$?" = 2
  verdict=0; reap_apk_installed "$A" > "$Q/failure.log"
  expect test "$(cat "$Q/failed-apk")" = "$A"; expect test -f "$Q/a.req"
  expect grep -q 'APK installed but SHELL BEHIND' "$Q/failure.log"
  if grep -q 'WINDOWS BROKEN' "$Q/failure.log"; then exit 1; fi
  expect grep -q 're-applying' "$Q/mail"
  # A real window failure remains a failure independently of payload equivalence.
  rm -f "$Q/apk/shell-want"
  echo "$A" > "$Q/live"; verdict=1; reap_apk_installed "$A" > "$Q/window.log"
  expect grep -q 'APK installed but WINDOWS BROKEN' "$Q/window.log"
  expect test -f "$Q/a.req"
) && ok "APK-only A->B: retries then PASS, payload equivalence, widget pending; real shell/window failures retained" ||
  bad "APK reap stamp/payload regression"

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
