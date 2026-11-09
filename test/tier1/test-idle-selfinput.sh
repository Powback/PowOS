#!/bin/bash
# test-idle-selfinput.sh: only a person's input counts as "touched" (11-07 20:20-22:04: the queue woke the dozing phone
# every 30 min, the panels' resume moved the touch IRQs, wl_touched read that as the user and stopped ww-glue within 4 s
# - rc 3 "touched" 10 times at night). idle.sh's real touch watcher runs locally against fake sources: /proc/interrupts,
# getevent (a stub fed from a file) and /sys/class/input (one real panel, one uinput-made nav device).
#   - a counter change inside the tools' own window (powos-selfinput, written by SELF_INPUT before a wake/sleep key) is
#     taken in, not a touch; the same change outside it is a touch;
#   - events from the uinput nav device (injected input) never count; the real panel's events do;
#   - a running watcher of an older version is restarted by --ensure, its lasttouch kept;
#   - every wake/sleep key the tools send carries the self-input mark.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/idle-selfinput-test.XXXXXX")
wp=; trap '[ -n "$wp" ] && kill $wp 2>/dev/null; pkill -f "$T/evsrc" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }
mkdir -p "$T/tools" "$T/bin" "$T/dlt" "$T/proc" "$T/sysin"
map="-e s#/data/local/tmp#$T/dlt#g -e s#/proc/#$T/proc/#g -e s#/sys/class/input#$T/sysin#g"
cp "$src/tools/phone/idle.sh" "$T/tools/idle.sh"
cat > "$T/tools/adb.sh" <<EOF2
#!/bin/bash
case "\$1" in --transport-state|--vpn-state) exit 0 ;; esac
[ "\$1" = shell ] || exit 0
cmd=\$(shift; printf %s "\$*" | sed $map)
case "\$cmd" in
  "cat > "*) f=\${cmd#cat > }; sed $map > "\$f" ;;
  *) PATH="$T/bin:\$PATH" sh -c "\$cmd" ;;
esac
EOF2
printf '#!/bin/sh\n[ "$1" = -c ] && exec sh -c "$2"\n' > "$T/bin/su"
echo '  mOverrideState=Optional.empty' > "$T/ovr"
printf '#!/bin/sh\necho "  lastUserActivityTime=1 (45000 ms ago)"\necho "  mWakefulness=Awake"\ncat %s/ovr\n' "$T" > "$T/bin/dumpsys"
printf '#!/bin/sh\necho "nohup $*" >> %s/restart.log\n' "$T" > "$T/bin/nohup"
: > "$T/evsrc"
printf '#!/bin/sh\nexec tail -n0 -F %s/evsrc 2>/dev/null\n' "$T" > "$T/bin/getevent"
chmod +x "$T/tools/"*.sh "$T/bin/"*
# input devices: event8 = the touch panel (platform), event16 = uinput_nav (virtual: injected input)
mkdir -p "$T/dev/platform/spi0/input/input8/event8/device" "$T/dev/devices/virtual/input/input17/event16/device"
echo touchpanel > "$T/dev/platform/spi0/input/input8/event8/device/name"
echo uinput_nav > "$T/dev/devices/virtual/input/input17/event16/device/name"
ln -s "$T/dev/platform/spi0/input/input8/event8" "$T/sysin/event8"
ln -s "$T/dev/devices/virtual/input/input17/event16" "$T/sysin/event16"
irq() { printf '327: %s 0 0 0 0 0 0 0 msmgpio 25 Edge touch-00\n328: 4325 0 0 0 0 0 0 0 msmgpio 174 Edge touch-01\n' "$1" > "$T/proc/interrupts"; }
irq 1000; printf '600.0 1200.0\n' > "$T/proc/uptime"
bash "$T/tools/idle.sh" >/dev/null 2>&1   # pushes the watcher (nohup is faked: not started)
[ -s "$T/dlt/powos-touchmon.sh" ] || { echo "FAIL the watcher wasn't written"; exit 1; }
touch "$T/dlt/powos-touchmon.ask"
PATH="$T/bin:$PATH" sh "$T/dlt/powos-touchmon.sh" & wp=$!
sleep 3   # first look: lasttouch = start
lt() { cat "$T/dlt/powos-lasttouch" 2>/dev/null; }
settle() { echo 1 > "$T/dlt/powos-lasttouch"; sleep 5; }   # 1 = long ago; two looks pass

# 1. The tools' wake: mark + counter change (the panel's resume) -> not a touch.
settle; echo $(( $(date +%s) + 8 )) > "$T/dlt/powos-selfinput"; irq 1010; sleep 5
[ "$(lt)" = 1 ] && ok "a panel IRQ change inside the tools' own wake window: not a touch" || bad "self wake counted as a touch" "lasttouch=$(lt)"
# 2. Its own nav device's events (input swipe via uinput) -> not a touch, even outside the window.
echo 0 > "$T/dlt/powos-selfinput"; sleep 4; settle
echo "/dev/input/event16: 0003 0035 00000200" >> "$T/evsrc"; sleep 5
[ "$(lt)" = 1 ] && ok "events of the uinput nav device (injected input): not a touch" || bad "injected device counted" "lasttouch=$(lt)"
# 3. A real finger: a counter change with no mark -> a touch.
settle; irq 1020; sleep 5
[ "$(lt)" -gt 1 ] && ok "a panel IRQ change outside any self window: a touch" || bad "real touch missed" "lasttouch=$(lt)"
# 4. A real panel event (getevent on the platform panel) -> a touch.
settle; echo "/dev/input/event8: 0003 0035 00000200" >> "$T/evsrc"; sleep 5
[ "$(lt)" -gt 1 ] && ok "a real panel's getevent line: a touch" || bad "real panel event missed" "lasttouch=$(lt)"
# 5. A stale mark (long past) doesn't mask a real touch.
settle; echo $(( $(date +%s) - 60 )) > "$T/dlt/powos-selfinput"; irq 1030; sleep 5
[ "$(lt)" -gt 1 ] && ok "a mark 60 s old masks nothing" || bad "stale mark masked a touch" "lasttouch=$(lt)"
# 5b. A fold override set by a tool (cmd device_state state 0) + the other panel's power-up IRQs -> not a touch (11-07
#     01:44: game-present-rate stopped as "picked up" 10 s after its own fold); then reset (state reset) -> not either.
settle; echo "  mOverrideState=Optional[DeviceState{identifier=0, name='CLOSED'}]" > "$T/ovr"; sleep 1; irq 1040; sleep 5
[ "$(lt)" = 1 ] && ok "panel IRQs right after a fold override was set: not a touch" || bad "own fold counted as a touch" "lasttouch=$(lt)"
echo '  mOverrideState=Optional.empty' > "$T/ovr"; sleep 1; irq 1050; sleep 3
[ "$(lt)" = 1 ] && ok "panel IRQs right after the override was reset: not a touch" || bad "own fold reset counted as a touch" "lasttouch=$(lt)"
# 5c. The override unchanged for long: a finger counts again.
sleep 10; settle; irq 1060; sleep 5
[ "$(lt)" -gt 1 ] && ok "an unchanged override masks nothing" || bad "unchanged override masked a touch" "lasttouch=$(lt)"
kill $wp 2>/dev/null; wait $wp 2>/dev/null; wp=

# 6. --ensure restarts a live watcher of an older version, lasttouch kept.
mkdir -p "$T/proc/777"; printf "sh\0$T/dlt/powos-touchmon.sh\0" > "$T/proc/777/cmdline"
echo 777 > "$T/dlt/powos-touchmon.pid"; echo 1 > "$T/dlt/powos-touchmon.ver"; echo $(( $(date +%s) - 300 )) > "$T/dlt/powos-lasttouch"
: > "$T/restart.log"; out=$(bash "$T/tools/idle.sh" 2>&1)
i=$(sed -n 's/^idle=\([0-9]*\) .*/\1/p' <<<"$out")
grep -q powos-touchmon.sh "$T/restart.log" && [ -n "$i" ] && [ "$i" -ge 300 ] && [ "$i" -le 305 ] \
  && ok "old-version watcher: restarted, idle kept from its lasttouch ($i)" || bad "old-version watcher" "$out"$'\n'"$(cat "$T/restart.log")"
echo 3 > "$T/dlt/powos-touchmon.ver"; echo 777 > "$T/dlt/powos-touchmon.pid"; : > "$T/restart.log"; bash "$T/tools/idle.sh" >/dev/null 2>&1
[ ! -s "$T/restart.log" ] && ok "current-version watcher: left running" || bad "current watcher restarted" "$(cat "$T/restart.log")"

# 7. Every wake/sleep key the tools send carries the mark.
miss=$(grep -nE "keyevent (KEYCODE_(WAKEUP|SLEEP)|22[34])" "$src/tools/phone/verify/window-lock.sh" "$src/tools/phone/ship-guard.sh" "$src/tools/phone/verify/window-render.sh" | grep -v -e 'SELF_INPUT' -e 'powos-selfinput')
[ -z "$miss" ] && ok "every wake/sleep key in window-lock/ship-guard/window-render is marked as the tools' own" || bad "unmarked wake/sleep keys" "$miss"

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
