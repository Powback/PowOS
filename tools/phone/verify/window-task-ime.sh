#!/bin/bash
# lanes: phone
# window-task-ime.sh [OUT]: (Mac side; queue it: queue.sh add --close linux-apps-opened-as-their-own-task-e-g-dolphin
# tools/phone/verify/window-task-ime.sh) a Linux app opened as its OWN Android task raises the Android keyboard for its
# text field (Powback/PowOS#12, d80e9c58: the window task claims its window's keyboard from KWin - `ime <id> 1`, KWin
# cap window-ime - and hosts the keyboard itself). In one free window:
#   1. the running KWin has window-ime (else SKIP: not deployed); APP (default kwrite) isn't running already (the user's
#      typed-into windows are never touched: not now, exit 3);
#   2. APP opened on a fresh file the drawer's way (powos-open-task: the window as its own task) -> a new
#      PowosWindowActivity task in front within 30 s;
#   3. a tap in the middle of the task (the editor's text area) -> within 4 s the Android keyboard is up
#      (dumpsys input_method mInputShown=true) for that task's window (mCurFocusedWindowName / the IME target names
#      PowosWindowActivity); KWin's and the app's keyboard lines of the run are kept as evidence.
# Always restores: the keyboard hidden, only what this check started closed (its marker file in the command line),
# its task removed, home. Exit: 0 PASS; 1 FAIL; 3 a real touch / not now; 5 SKIP/can't run (ENV).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
APP=${APP:-kwrite}; case $APP in kwrite|kate) ;; *) echo "ENV: APP is kwrite or kate ($APP)"; exit 5 ;; esac
OUT=${1:-$HOME/.cache/powos-verify/window-task-ime-$(date +%m%d-%H%M)}; mkdir -p "$OUT"; R=$OUT/log.txt
L=$HOME/.cache/powos-verify.lock
N=$(date +%s)$RANDOM; F=/tmp/powos-ime-check-$N.txt
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# As the session user, with the session's environment (plasmashell's or KWin's: the bus, the display).
us() { printf '%s\n' 'P=$(pgrep -x plasmashell | head -1); [ -n "$P" ] || P=$(pgrep -x kwin_wayland | head -1)
[ -n "$P" ] && while IFS= read -r -d "" kv; do export "$kv"; done < /proc/$P/environ 2>/dev/null
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app}' "$1" > "$OUT/u.sh"
  "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
log() { echo "$(date +%T) $*" | tee -a "$R"; }
fail() { log "FAIL: $*"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { log "PASS: $*"; }
ime() { sh_ "dumpsys input_method | grep -m1 -oE \"mInputShown=[a-z]+\"" | sed 's/.*=//'; }
# The window the keyboard serves: the focused window's line of dumpsys input_method (its name differs per Android release).
target() { sh_ "dumpsys input_method" | grep -m1 -oE "(mCurFocusedWindow|mFocusedWindow|mCurFocusedWindowName)=[^ ]*( [^ ]+){0,2}" | cut -c1-200; }
tasks() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
tbounds() { sh_ "am stack list | grep -E \"taskId=$1[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }

. "$here/window-lock.sh"
window_lock window-task-ime.sh 120
STARTED=0; KT=""
restore() {
  [ "$(ime)" = true ] && sh_ "input keyevent KEYCODE_BACK"
  if [ $STARTED = 1 ]; then
    us "pkill -f powos-ime-check-$N; rm -f $F; true" >/dev/null
    [ -n "$KT" ] && sleep 1 && [ -n "$(sh_ "am stack list | grep -E \"taskId=${KT}[^0-9]\"")" ] && sh_ "am stack remove $KT"
  fi
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  echo "restored; artefacts $OUT"
}
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { log "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { log "the screen is $s - not woken (rule); nothing done"; exit 3; }
if sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true && { echo "ENV: the keyguard is up"; exit 5; }
fi

# 1. Deployed? Not now?
rs "k=\$(pgrep -x kwin_wayland | head -1); [ -n \"\$k\" ] && ! grep -q 'libkwin.*(deleted)' /proc/\$k/maps && grep -aq 'window-ime' /usr/lib/libkwin.so.6 && echo yes" | grep -q yes \
  || { log "SKIP: the running KWin has no window-ime cap (pkgs/kwin 0043 not in the running session)"; exit 5; }
[ -z "$(us "pgrep -x $APP" | tail -1)" ] || { log "$APP already runs (maybe the user's): not now"; exit 3; }
us "command -v powos-open-task >/dev/null && command -v $APP >/dev/null && echo ok" | grep -q ok \
  || { log "SKIP: powos-open-task or $APP isn't installed in the session"; exit 5; }
log "apk $(sh_ "dumpsys package com.powos.app | grep -m1 versionName" | sed 's/ *//'), kwin $(us 'pacman -Q kwin' | tail -1)"

# 2. Its own task, the drawer's way.
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
[ "$(ime)" = true ] && { sh_ "input keyevent KEYCODE_BACK"; sleep 1; }
before=$(tasks); KL0=$(us "grep -a -c . /run/powos-app/hyprland.log" | tail -1); KL0=${KL0:-0}
t0=$(sh_ "date +\"%m-%d %H:%M:%S.000\"")
STARTED=1
us "printf 'PowOS keyboard check\n' > $F; setsid -f powos-open-task -- $APP $F >/tmp/powos-ime-check-$N.out 2>&1 </dev/null; echo started" >/dev/null
for _ in $(seq 30); do sleep 1; KT=$(comm -13 <(echo "$before") <(tasks) | tail -1); [ -n "$KT" ] && break; done
chk launch
[ -n "$KT" ] || fail "no window task for $APP in 30 s (powos-open-task: $(us "tail -3 /tmp/powos-ime-check-$N.out" | tr '\n' '|'))"
sleep 3
tp=$(sh_ "dumpsys activity activities | grep -m1 topResumedActivity")
case $tp in *PowosWindowActivity*" t$KT}"*) ;; *PowosWindowActivity*) log "note: top is $tp (task $KT expected)" ;;
  *) fail "$APP's window task $KT isn't in front ($tp)" ;; esac
read -r l t r b <<<"$(tbounds "$KT")"
if [ -z "${b:-}" ] || [ "${r:-0}" -le "${l:-0}" ]; then
  read -r r b <<<"$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)"; l=0; t=0
fi
k0=$(ime)
log "$APP in its own task $KT ($l $t $r $b); keyboard before the tap: $k0"
"$T/shot.sh" "$OUT/opened.png" >/dev/null 2>&1

# 3. A tap in the text area -> the Android keyboard.
x=$(( (l + r) / 2 )); y=$(( t + (b - t) * 45 / 100 ))
sh_ "input tap $x $y"; log "tapped $x,$y"
k=""; for _ in 1 2 3 4 5 6 7 8; do sleep 0.5; k=$(ime); [ "$k" = true ] && break; done
chk tap
tg=$(target); log "keyboard: ${k:-?}; IME target: ${tg:-?}"
"$T/shot.sh" "$OUT/tapped.png" >/dev/null 2>&1
sh_ "logcat -d -T \"$t0\" -v time" | grep -aiE "WebWindowSource|SystemIME|keyboard|window-ime|ime\\b" | tail -20 > "$OUT/logcat.txt"
us "tail -n +$((KL0 + 1)) /run/powos-app/hyprland.log | grep -aiE 'keyboard|input method|ime ' | tail -20" > "$OUT/kwin.txt"
log "app: $(tail -3 "$OUT/logcat.txt" | cut -c1-160 | tr '\n' '|')"
log "kwin: $(tail -3 "$OUT/kwin.txt" | cut -c1-160 | tr '\n' '|')"
[ "$k" = true ] || fail "no Android keyboard 4 s after a tap in $APP's text area (its own task $KT; mInputShown=${k:-?})"
case $tg in *PowosWindowActivity*) ;; "") log "note: the IME target line isn't in this dumpsys format" ;;
  *) fail "the keyboard is up but for another window ($tg), not $APP's task" ;; esac
pass "a tap in $APP's text field (its own window task $KT) raises the Android keyboard"
echo "all passed; artefacts: $OUT"
