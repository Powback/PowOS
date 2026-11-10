#!/bin/bash
# test-queue-wake.sh: the verify queue wakes an idle, dozing phone for its jobs (11-07, the user: "yeah do whatever")
# at minimum brightness and puts the user's brightness, brightness mode and screen-off timeout back EXACTLY - after the
# batch (wl_sleep: screen off again) and at once on a real input (wl_touched + wl_restore: no sleep). Never woken:
# the user active (< WAKE_IDLE_S), the battery under 20 % and not charging, nothing runnable (GO_ONLY). Fake adb/idle.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/queue-wake-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }
mkdir -p "$T/tools"
# The phone: settings in $T/set/<name>, power state in $T/wake, battery in $T/batt ("<level> <powered>").
cat > "$T/tools/adb.sh" <<EOF2
#!/bin/bash
[ "\$1" = shell ] && shift
echo "\$*" >> "$T/adb.log"
cmd="\$*"
if [ "\$cmd" = 'dumpsys battery' ]; then read -r l p < "$T/batt"; echo "  AC powered: \$p"; echo "  USB powered: false"; echo "  level: \$l"; exit 0; fi
settings() { case \$1 in get) cat "$T/set/\$3" ;; put) echo "\$4" > "$T/set/\$3" ;; esac; }
input() { case \$2 in KEYCODE_WAKEUP) echo Awake > "$T/wake" ;; KEYCODE_SLEEP) echo Dozing > "$T/wake" ;; esac; }
wm() { :; }; sleep() { :; }
eval "\$cmd"
EOF2
cat > "$T/tools/idle.sh" <<EOF2
#!/bin/bash
echo "idle=\$(cat "$T/idle") screen=\$(cat "$T/wake") act=0"
EOF2
chmod +x "$T/tools/"*.sh
reset() {   # reset IDLE BATT POWERED: a dozing phone with the user's own settings
  mkdir -p "$T/set"; echo 87 > "$T/set/screen_brightness"; echo 1 > "$T/set/screen_brightness_mode"; echo 60000 > "$T/set/screen_off_timeout"
  echo Dozing > "$T/wake"; echo "$1" > "$T/idle"; echo "$2 $3" > "$T/batt"; : > "$T/adb.log"; rm -f "$T/woke"; }
lib() { HOME=$T WL_WOKE=$T/woke bash -c '. "$1"; shift; "$@"' _ "$src/tools/phone/verify/window-lock.sh" "$@" 2>&1; }
user_set() { echo "$(cat "$T/set/screen_brightness") $(cat "$T/set/screen_brightness_mode") $(cat "$T/set/screen_off_timeout")"; }

# 1. idle 900 s, battery fine: woken at min brightness, kept on; after the batch restored exactly + back to sleep.
reset 900 80 false
out=$(lib wl_wake "$T/tools")
[ "$(cat "$T/wake")" = Awake ] && [ "$(user_set)" = "1 0 1800000" ] && grep -q 'woke the phone' <<<"$out" \
  && ok "idle 900 s: woken at minimum brightness, manual mode, 30 min timeout" || bad "idle 900 s: woken at min brightness" "$out"$'\n'"$(user_set)"$'\n'"$(cat "$T/adb.log")"
grep -q '^b=87$' "$T/woke" && grep -q '^m=1$' "$T/woke" && grep -q '^t=60000$' "$T/woke" && ok "the user's settings saved" || bad "the user's settings saved" "$(cat "$T/woke" 2>&1)"
lib wl_wake "$T/tools" >/dev/null; echo Dozing > "$T/wake"; lib wl_wake "$T/tools" >/dev/null   # woken again mid-batch
grep -q '^b=87$' "$T/woke" && ok "a second wake keeps the first save (never saves the queue's own min brightness)" || bad "second wake keeps the save" "$(cat "$T/woke")"
echo 1200 > "$T/idle"; out=$(lib wl_sleep "$T/tools")
[ "$(user_set)" = "87 1 60000" ] && [ "$(cat "$T/wake")" = Dozing ] && [ ! -e "$T/woke" ] \
  && ok "after the batch: brightness 87, auto mode, 60 s timeout restored exactly; screen off" || bad "batch end restore + sleep" "$out"$'\n'"$(user_set) $(cat "$T/wake")"

# 2. abort: the user touches the woken phone -> wl_touched; settings back at once, the screen NOT put to sleep.
reset 900 80 false; lib wl_wake "$T/tools" >/dev/null
sed -i.bak "s/^at=.*/at=$(( $(date +%s) - 100 ))/" "$T/woke"   # woken 100 s ago
echo 3 > "$T/idle"
HOME=$T WL_WOKE=$T/woke bash -c '. "$1"; wl_touched "$2"' _ "$src/tools/phone/verify/window-lock.sh" "$T/tools" && ok "a real input after the wake is seen (wl_touched)" || bad "wl_touched sees the input" "$(cat "$T/woke")"
lib wl_restore "$T/tools" >/dev/null; lib wl_sleep "$T/tools" >/dev/null
[ "$(user_set)" = "87 1 60000" ] && [ "$(cat "$T/wake")" = Awake ] && ! grep -q KEYCODE_SLEEP "$T/adb.log" \
  && ok "abort on input: settings restored exactly, screen left on for the user" || bad "abort restore" "$(user_set) $(cat "$T/wake")"$'\n'"$(cat "$T/adb.log")"
reset 900 80 false; lib wl_wake "$T/tools" >/dev/null; sed -i.bak "s/^at=.*/at=$(( $(date +%s) - 100 ))/" "$T/woke"; echo 1000 > "$T/idle"
HOME=$T WL_WOKE=$T/woke bash -c '. "$1"; wl_touched "$2"' _ "$src/tools/phone/verify/window-lock.sh" "$T/tools" && bad "no input since the wake: not touched" || ok "no input since the wake: not touched"
echo 3 > "$T/idle"; out=$(lib wl_sleep "$T/tools")
[ "$(user_set)" = "87 1 60000" ] && [ "$(cat "$T/wake")" = Awake ] && ok "batch end after a touch: restored, no sleep" || bad "batch end after touch" "$out"

# 3. never woken: the user active, low battery not charging, nothing runnable. Low battery charging: woken.
reset 300 80 false; lib wl_wake "$T/tools" >/dev/null
[ "$(cat "$T/wake")" = Dozing ] && ! grep -q 'settings put' "$T/adb.log" && ok "idle 300 s (< 10 min): not woken, nothing changed" || bad "idle 300 not woken" "$(cat "$T/adb.log")"
reset 900 15 false; out=$(lib wl_wake "$T/tools")
[ "$(cat "$T/wake")" = Dozing ] && ! grep -q 'settings put' "$T/adb.log" && grep -q 'battery 15%' <<<"$out" && ok "battery 15 %, not charging: not woken" || bad "low battery not woken" "$out"
reset 900 15 true; lib wl_wake "$T/tools" >/dev/null
[ "$(cat "$T/wake")" = Awake ] && ok "battery 15 % but charging: woken" || bad "low battery charging woken" "$(cat "$T/adb.log")"
reset 900 80 false; HOME=$T WL_WOKE=$T/woke GO_ONLY=1 bash -c '. "$1"; wl_wake "$2"' _ "$src/tools/phone/verify/window-lock.sh" "$T/tools" >/dev/null
[ "$(cat "$T/wake")" = Dozing ] && ok "nothing runnable (GO_ONLY): not woken" || bad "GO_ONLY not woken"
grep -qE 'input (tap|text)|keyevent KEYCODE_[0-9]' "$T/adb.log" && bad "never types a PIN" "$(cat "$T/adb.log")" || ok "never types a PIN"

# 4. the runner: input on a woken phone stops the check (rc 3 touched), the window logs/records the wake.
q=$src/tools/phone/verify/queue.sh
grep -q 'wl_touched "$phone" && { why=touched; wl_restore' "$q" && grep -q '"$why" = touched ] && {.*rc=3' "$q" && grep -q 'woke the phone for ${k:-0} jobs' "$q" \
  && ok "queue.sh: heartbeat stops on input while woken (rc 3), window end logs 'woke the phone for N jobs'" || bad "queue.sh wiring"
printf 'W 100 200\nJ 110 190 pass j1\nK 200 4\n' > "$T/util.log"
u=$(python3 -I "$src/tools/phone/verify/queue-util.py" "$T/util.log")
grep -q 'woke the phone 1 times for 4 jobs' <<<"$u" && ok "util line: woke the phone 1 times for 4 jobs" || bad "util line" "$u"
# 5. wl_hold (11-10): a window that finds the screen on holds it at a 30 min timeout, brightness untouched, and the
# window's end puts the user's timeout back - else it dozed mid-window on the user's 30 s.
reset 200 80 false; echo Awake > "$T/wake"; lib wl_hold "$T/tools" >/dev/null
[ "$(user_set)" = "87 1 1800000" ] && grep -q '^held=1$' "$T/woke" && grep -q '^t=60000$' "$T/woke" \
  && ok "wl_hold: timeout held at 30 min, brightness untouched, the user's saved" || bad "wl_hold" "$(user_set)"$'\n'"$(cat "$T/woke" 2>&1)"
echo 1200 > "$T/idle"; lib wl_sleep "$T/tools" >/dev/null
[ "$(user_set)" = "87 1 60000" ] && [ ! -e "$T/woke" ] && ok "wl_hold: the window's end restores the timeout" || bad "wl_hold restore" "$(user_set)"
grep -q 'wl_hold "$phone"' "$src/tools/phone/verify/queue.sh" && ok "queue.sh holds the screen once the window is taken" || bad "queue.sh wl_hold wiring"
# 6. untouched since the queue's last window opened: woken without a fresh WAKE_IDLE_S; touched since: not.
reset 300 80 false; echo $(( $(date +%s) - 250 )) > "$T/lastwin"; WL_LASTWIN=$T/lastwin lib wl_wake "$T/tools" >/dev/null
[ "$(cat "$T/wake")" = Awake ] && grep -q powos-queuewake "$T/adb.log" && ok "idle 300 s, no touch since the last window opened 250 s ago: woken (marked as the queue's wake)" || bad "lastwin wake" "$(cat "$T/adb.log")"
reset 300 80 false; echo $(( $(date +%s) - 400 )) > "$T/lastwin"; WL_LASTWIN=$T/lastwin lib wl_wake "$T/tools" >/dev/null
[ "$(cat "$T/wake")" = Dozing ] && ok "idle 300 s, touched since the last window opened 400 s ago: not woken" || bad "lastwin touched not woken"
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
