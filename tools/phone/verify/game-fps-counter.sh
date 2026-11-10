#!/bin/bash
# lanes: phone
# game-fps-counter.sh [OUT]: (Mac side; queue it: queue.sh add --close games-show-no-fps-overlay-add-a-built-in-fps-cou
# tools/phone/verify/game-fps-counter.sh) a game's window task shows the built-in fps counter (GameFpsCounter, f5e7696c:
# an "N fps" label top left of PowosWindowActivity) while the fps meter's switch (store perf.meter "on") is on, and
# hides it when the switch goes off. In one free window:
#   1. perf.meter read (kept), then set on ({...it, on: true}) through home's bridge (store.set: ShellBridge sets
#      GameFpsCounter.on);
#   2. the game (APP, default 274190 Broforce) started the user's way - bf-return-phone.sh launch (powos-open-task; a
#      Broforce the user left frozen is used and frozen again, one running awake = not now, exit 3);
#   3. the game's window task in front (topResumedActivity PowosWindowActivity), then the label: uiautomator's dump
#      (its text "N fps" with N > 0, in the task's top-left quarter), read twice 3 s apart; a dump that fails (a busy
#      game window can keep uiautomator from idling) falls back to `dumpsys activity top` - a visible TextView in
#      PowosWindowActivity's views in the top-left quarter (its text unread, said so);
#   4. the switch off -> the label gone (no "fps" text / the TextView not visible) within 3 s.
# Always restores: perf.meter as it was, the game closed if this check started it (bf-return-phone.sh close), home.
# Exit: 0 PASS; 1 FAIL; 3 a real touch / the user's game awake / not now; 5 can't run (ENV).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; APP=${APP:-274190}
case $APP in *[!0-9]*|"") echo "ENV: APP is a Steam app id ($APP)"; exit 5 ;; esac
OUT=${1:-$HOME/.cache/powos-verify/game-fps-counter-$(date +%m%d-%H%M)}; mkdir -p "$OUT"; R=$OUT/log.txt
L=$HOME/.cache/powos-verify.lock
log() { echo "$(date +%T) $*" | tee -a "$R"; }
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
top() { sh_ "dumpsys activity activities | grep -m1 topResumedActivity"; }
ev() { "$T/cdp.sh" eval home "$1" 2>&1 | tr -d '\r' | tail -1; }
# cdp.ts prints an eval's value JSON-encoded, so the JSON.stringify'd meter arrives as a quoted string
# ("{\"on\":true,...}", the 11-10 "unreadable" SKIP): decoded once here to the object's JSON.
meter_get() {
  ev 'importShim("./bridge.ts").then(b=>b.powos.store.get("perf.meter")).then(v=>JSON.stringify(v??null))' |
    python3 -c 'import json,sys; s=sys.stdin.read().strip()
try: v=json.loads(s)
except ValueError: v=s
print(v if isinstance(v,str) else json.dumps(v))'
}
meter_set() { ev "importShim('./bridge.ts').then(b=>b.powos.store.set('perf.meter',$1)).then(()=>'ok')" | tr -d '"'; }
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-return-phone.sh $1\"'" 2>&1 | grep -v sysvipc | sed -l $'s/\r$//' | tee -a "$R"; }

# fps_label <l> <t> <r> <b>: the counter in the task (bounds l t r b) - "text=<N fps>" (uiautomator), "view=V" (dumpsys:
# a visible TextView there, text unread), or "none <why>".
fps_label() {
  local l=$1 t=$2 r=$3 b=$4 xml
  xml=$(sh_ "uiautomator dump /data/local/tmp/gfc.xml >/dev/null 2>&1 && cat /data/local/tmp/gfc.xml; rm -f /data/local/tmp/gfc.xml")
  if [ -n "$xml" ]; then
    printf '%s' "$xml" > "$OUT/ui-$(date +%H%M%S).xml"
    printf '%s' "$xml" | python3 -c '
import re, sys
l, t, r, b = map(int, sys.argv[1:5]); d = sys.stdin.read()
for m in re.finditer(r"<node [^>]*?text=\"((?:-- |\d+ )fps)\"[^>]*?bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", d):
    x0, y0 = int(m.group(2)), int(m.group(3))
    if l <= x0 < l + (r - l) // 2 and t <= y0 < t + (b - t) // 2:
        print("text=" + m.group(1)); break
    print("none the label %s is at %d,%d, not top left of the task" % (m.group(1), x0, y0)); break
else:
    print("none no \"N fps\" text in the dump")' "$l" "$t" "$r" "$b"
    return
  fi
  # uiautomator gave nothing: the views of the top activity (PowosWindowActivity), a TextView in the top-left quarter.
  sh_ "dumpsys activity top" | awk '/ACTIVITY .*PowosWindowActivity/{a=1} a' > "$OUT/top-$(date +%H%M%S).txt"
  python3 - "$OUT"/top-*.txt "$l" "$t" "$r" "$b" <<'PY'
import re, sys
f = sorted(sys.argv[1:-4])[-1]; l, t, r, b = map(int, sys.argv[-4:])
w, h = r - l, b - t
for line in open(f, errors="replace"):
    m = re.search(r"android\.widget\.TextView\{\S+ (\S)\S* \S+ (-?\d+),(-?\d+)-(-?\d+),(-?\d+)", line)
    if m and int(m.group(2)) < w // 2 and int(m.group(3)) < h // 2:
        print("view=" + m.group(1) if m.group(1) == "V" else "none the TextView top left is %s (not visible)" % m.group(1)); break
else:
    print("none uiautomator dump failed and PowosWindowActivity has no TextView top left")
PY
}

. "$here/window-lock.sh"
window_lock game-fps-counter.sh 120
METER0=; STARTED=0; closed=0
finish() {
  [ $closed = 1 ] && return; closed=1
  [ -n "$METER0" ] && { log "perf.meter back to $METER0: $(meter_set "$METER0")"; }
  [ $STARTED = 1 ] && ph close >/dev/null
  sh_ "rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-return-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/powos-bf-return-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-bf-xframes.py /data/powos/root/tmp/bf-return.env /data/local/tmp/gfc.xml" >/dev/null
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  echo "restored; artefacts $OUT"
}
trap 'finish; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
trap 'log "stopped from outside"; exit 3' HUP TERM INT
fail() { log "FAIL: $*"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { log "PASS: $*"; }
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { log "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { log "the screen is $s - not woken (rule); nothing done"; exit 3; }

# 1. The switch on (what it was is put back).
METER0=$(meter_get)
case $METER0 in null|\{*) ;; *) METER0=; echo "ENV: perf.meter unreadable over CDP ($(meter_get | cut -c1-120))"; exit 5 ;; esac
log "perf.meter at start: $METER0"
[ "$(meter_set "Object.assign({},$METER0,{on:true})")" = ok ] || fail "store.set perf.meter {on:true} failed"

# 2. The game, the user's way.
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "ENV: can't push $ot"; exit 5; }
for f in bf-return-phone.sh bf-lib.sh bf-stop.sh bf-xframes.py; do
  "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "ENV: can't push $f"; exit 5; }; done
sh_ "install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-return-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*" >/dev/null
STARTED=1
ph launch >/dev/null
grep -q '^SKIP\|^user input' "$R" && { log "not now: $(grep -m1 '^SKIP\|^user input' "$R")"; exit 3; }
grep -q '^FAIL launch' "$R" && fail "the game didn't launch: $(grep -m1 '^FAIL launch' "$R")"
chk launch
sleep 5   # past the window going full screen, the counter's first two ticks
tp=$(top)
case $tp in *PowosWindowActivity*) ;; *) fail "the game isn't in its own window task in front ($tp): the counter lives in PowosWindowActivity" ;; esac
TID=$(echo "$tp" | grep -oE ' t[0-9]+' | tr -dc '0-9')
read -r l t r b <<<"$(sh_ "am stack list | grep -E \"taskId=$TID[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ')"
if [ -z "${b:-}" ] || [ "${r:-0}" -le "${l:-0}" ]; then  # a full-screen task reports no bounds: the display's
  read -r r b <<<"$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)"; l=0; t=0
fi
log "game task $TID in front, bounds $l $t $r $b"

# 3. The label, twice.
got1=$(fps_label "$l" "$t" "$r" "$b"); chk read1; log "counter: $got1"
"$T/shot.sh" "$OUT/on.png" >/dev/null 2>&1
sleep 3
got2=$(fps_label "$l" "$t" "$r" "$b"); chk read2; log "counter 3 s later: $got2"
case $got2 in
  text=--*) fail "the counter shows no frames (\"$got2\" - the game's window presents nothing to its task?)" ;;
  text=0\ fps) fail "the counter reads 0 fps (the game stalled?)" ;;
  text=*) pass "the game's window task shows the fps counter: ${got1#text=} then ${got2#text=}" ;;
  view=V) pass "a visible label top left of the game's window task (uiautomator couldn't dump it: text unread)" ;;
  *) fail "no fps counter in the game's window task with the meter on: ${got2#none }" ;;
esac

# 4. The switch off -> the label goes.
[ "$(meter_set "Object.assign({},$METER0,{on:false})")" = ok ] || fail "store.set perf.meter {on:false} failed"
sleep 3; chk off
off=$(fps_label "$l" "$t" "$r" "$b"); log "meter off: $off"
case $off in
  text=*) fail "the counter stays with the meter off (\"${off#text=}\")" ;;
  view=V) fail "the label stays visible with the meter off" ;;
esac
pass "the counter follows the fps meter's switch (gone when off)"
echo "all passed; artefacts: $OUT"
