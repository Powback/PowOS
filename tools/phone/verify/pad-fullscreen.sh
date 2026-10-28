#!/bin/bash
# lanes: phone
# needs: kwin
# pad-fullscreen.sh [OUT]: board task "Touch keyboard + game controls overlay stay available over full-screen Linux
# apps". No game: Kate (opened through home's launch path) is put full screen with a KWin script, then
#   1. its PowosWindowActivity task is full screen (mode=fullscreen / covers the screen) and has the two buttons
#      (uiautomator: content-desc "Keyboard" and "Game controls" in package andro.marchy);
#   2. a tap on "Game controls" turns the overlay on: the saved flag (gamepad_shown) is true and the screen changed;
#      a second tap turns it off again (flag false);
#   3. a tap on "Keyboard" shows Android's IME (dumpsys input_method mInputShown=true); a second tap hides it.
# Restores: pad off, IME hidden, Kate closed if this started it, home. Exit: 0 passed; 1 FAIL; 3 not now; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/pad-fullscreen-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
KATE_MINE=0
restore() {
  [ "$(padflag)" = true ] && tap_desc "Game controls" >/dev/null 2>&1
  us "[ $KATE_MINE = 1 ] && pkill -x kate; true"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  echo restored
}
. "$here/window-lock.sh"
window_lock pad-fullscreen.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
padflag() { sh_ "grep -o 'gamepad_shown\" value=\"[a-z]*' /data/data/andro.marchy/shared_prefs/andromarchy_settings.xml" | grep -o '[a-z]*$' | head -1; }
# center "x y" of the node with this content-desc, from a uiautomator dump
node() {
  sh_ "uiautomator dump /sdcard/pf.xml >/dev/null 2>&1; cat /sdcard/pf.xml" | python3 -c '
import re,sys
x=sys.stdin.read()
for m in re.finditer(r"<node[^>]*>",x):
    n=m.group(0)
    if "content-desc=\"%s\""%sys.argv[1] in n and "andro.marchy" in n:
        b=re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"",n).groups(); b=list(map(int,b))
        print((b[0]+b[2])//2,(b[1]+b[3])//2); break' "$1"
}
tap_desc() { local p; p=$(node "$1"); [ -n "$p" ] || return 1; sh_ "input tap $p"; sleep 1.5; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(us 'pgrep -xc kate' | tail -1)" = 0 ] && KATE_MINE=1
before=$(sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | sort)
us 'P=$(pgrep -x plasmashell | head -1); while IFS= read -r -d "" kv; do export "$kv"; done < /proc/$P/environ; setsid -f kate >/dev/null 2>&1'
for i in $(seq 1 30); do sleep 1; new=$(comm -13 <(echo "$before") <(sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | sort) | tail -1); [ -n "$new" ] && break; done
[ -n "$new" ] || fail "no window task for Kate within 30 s"
KT=${new#taskId=}; sleep 4
cat > "$OUT/fs.js" <<'JS'
for (const w of workspace.windowList()) if (String(w.resourceClass).indexOf("kate") >= 0) w.fullScreen = true;
JS
"$A" push "$OUT/fs.js" /data/local/tmp/pad-fs.js >/dev/null
us 'cp /data/local/tmp/pad-fs.js /tmp/pad-fs.js 2>/dev/null; qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript padfs >/dev/null 2>&1; qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript /tmp/pad-fs.js padfs >/dev/null; qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1'
sleep 5
[ "$(irq)" = "$I0" ] || { echo "STOP: a real touch - restoring"; exit 3; }
sz=$(sh_ "wm size" | grep -oE '[0-9]+x[0-9]+' | tail -1); W=${sz%x*}; H=${sz#*x}
read -r b1 b2 b3 b4 <<<"$(sh_ "am stack list | grep -E \"taskId=$KT:\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ')"
log "Kate task $KT bounds $b1,$b2 $b3,$b4 (screen ${W}x${H})"
[ $((b3 - b1)) -ge $((W * 95 / 100)) ] && [ $((b4 - b2)) -ge $((H * 95 / 100)) ] || fail "Kate's task is not full screen"
KB=$(node Keyboard); GP=$(node "Game controls")
[ -n "$KB" ] || fail "no Keyboard button over the full-screen Kate task"
[ -n "$GP" ] || fail "no Game controls button over the full-screen Kate task"
log "PASS buttons present: keyboard at $KB, controls at $GP"
"$T/shot.sh" "$OUT/off.png" >/dev/null 2>&1
[ "$(padflag)" = true ] && tap_desc "Game controls"   # start from off
tap_desc "Game controls" || fail "tap on Game controls"
[ "$(padflag)" = true ] || fail "Game controls tapped, gamepad_shown is $(padflag)"
"$T/shot.sh" "$OUT/on.png" >/dev/null 2>&1
d=$(python3 - "$OUT/off.png" "$OUT/on.png" <<'PY'
import subprocess,sys
a,b=[subprocess.run(["ffmpeg","-v","error","-i",f,"-vf","scale=180:-1,format=gray","-f","rawvideo","-"],capture_output=True).stdout for f in sys.argv[1:]]
print(sum(1 for x,y in zip(a,b) if abs(x-y)>25)*1000//max(len(a),1))
PY
)
log "overlay on: $d per mille of the screen changed"
[ "${d:-0}" -ge 5 ] || fail "the overlay did not draw over full-screen Kate ($d per mille changed) - $OUT/on.png"
tap_desc "Game controls"; [ "$(padflag)" = false ] || fail "second tap did not turn the controls off"
tap_desc Keyboard || fail "tap on Keyboard"; sleep 1
sh_ "dumpsys input_method" | grep -q "mInputShown=true" || fail "Keyboard tapped, the IME is not shown"
tap_desc Keyboard 2>/dev/null; 
echo "PASS: over full-screen Kate (task $KT) the Keyboard and Game controls buttons work, overlay draws"
