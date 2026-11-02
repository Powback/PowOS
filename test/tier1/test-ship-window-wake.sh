#!/bin/bash
# test-ship-window-wake.sh: the ship's device window check (tools/phone/verify/window-render.sh --hidden) on a dozing
# phone (11-02: the ship service waited all night for an awake phone). The user idle >= WR_WAKE_IDLE_S (600) s ->
# the check wakes the screen (as ship-guard.sh's boot check does), JUDGES, and puts it back to sleep; the user
# active (idle 60 s) -> never woken, NOT JUDGED (exit 2). A fake adb.sh/idle.sh (WR_TOOLS) stands in for the phone.
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

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
