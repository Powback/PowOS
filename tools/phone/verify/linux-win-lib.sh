# shellcheck shell=bash
# tools/phone/verify/linux-win-lib.sh (sourced by one-title-bar.sh, launch-window.sh): Linux window checks on the
# unfolded home - the helpers linux-dock.sh has inline. Needs here, T, A, OUT set; sets MINE (apps this check started:
# their window tasks closed and, but Steam, their processes ended by restore).
MINE=""
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
# A call on home's bridge exactly as the page makes it (float-windows.sh's hcall); $3 maps the answer.
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=911200+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
lin() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
tbounds() { sh_ "am stack list | grep -E \"taskId=$1[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ' | xargs; }
# frame_has bar|grip <task>: 1 when PowOS's frame window of that kind is there for the task, else 0.
frame_has() { [ -n "$(sh_ "dumpsys window windows" | grep -m1 "PowOS window $1 $2}")" ] && echo 1 || echo 0; }

# kwin_with <string in libkwin> <what>: the running KWin has it, else linux-float.sh installs the newest built package
# (+ a fresh session) first - it takes the window itself, so before this check's own lock.
kwin_with() {
  rs "k=\$(pgrep -x kwin_wayland | head -1); [ -n \"\$k\" ] && ! grep -q 'libkwin.*(deleted)' /proc/\$k/maps && grep -aq '$1' /usr/lib/libkwin.so.6 && echo yes" | grep -q yes && return 0
  log "the running KWin has no $2: linux-float.sh installs the newest kwin package"
  "$here/linux-float.sh" "$OUT/linux-float" | tail -3 | tee -a "$OUT/log.txt"
  rs "grep -aq '$1' /usr/lib/libkwin.so.6 && echo yes" | grep -q yes || { echo "FAIL: KWin still has no $2 (build pkgs/kwin: targets/android/build-pkgs.sh kwin)"; exit 1; }
}

# unfolded_home: the inner screen forced, unlocked (no PIN: a swipe), home in front; W, H set.
unfolded_home() {
  local s; s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
  [ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
  [ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || fail "enable_freeform_support isn't 1"
  sh_ "cmd device_state state 3"; sleep 3; chk unfold
  WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
  [ "${W:-0}" -gt 2000 ] || fail "display 0 is ${W:-?}x${H:-?}, not the unfolded inner screen"
  if sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true; then
    sh_ "wm dismiss-keyguard"; sleep 1.5
    sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
    sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?)"; exit 5; }
  fi
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
}

# livelog <name> <s>: the app's window lines captured live on the phone (the main log rotates in seconds); live: them
# so far in OUT/live.txt.
livelog() {
  LIVE=/data/local/tmp/$1-live.txt
  sh_ "rm -f $LIVE; (timeout $2 logcat -T 1 -v time -s WindowTasks PowosWindow PowosWindowFrame PowosWindowFrames LaunchWindows </dev/null >$LIVE 2>&1 &)"
}
live() { sh_ "cat $LIVE" > "$OUT/live.txt"; }

# launch_task <key> <max s>: the app launched through home's launch path (apps.launch, the call a tap makes); echoes
# the window task of its window once KWin opened it there ("open N (<app id>)"; a launch window's task counts once
# its window is in it), or nothing.
launch_task() {
  local key=$1 id=${1#l:} before t="" end
  before=$(lin)
  [ "$(hcall apps.launch "['$key']" "()=>'ok'")" = ok ] || return 0
  end=$((SECONDS + $2))
  while [ $SECONDS -lt $end ]; do
    sleep 2; live
    grep -aqE "WindowTasks.*open [0-9]+ \($id\)" "$OUT/live.txt" || continue
    t=$(comm -13 <(echo "$before") <(lin) | tail -1); [ -n "$t" ] && break
  done
  echo "$t"
}

# steam_window: Steam's window task id in home's windows.list, or "none".
steam_window() { hcall windows.list "[]" "l=>{const w=l.find(w=>w.app==='l:steam');return w?String(w.id):'none'}"; }

restore() {
  local t
  # Nothing started yet (the start's windows unread): nothing of this check's to close - never the user's windows.
  [ -n "${LIN0+set}" ] || { echo "nothing to restore"; return 0; }
  for t in $(comm -13 <(echo "${LIN0:-}") <(lin)); do hcall tasks.remove "[$t]" "()=>'ok'" >/dev/null; done
  for p in $MINE; do [ "$p" = steam ] || us "pkill -x $p; true" >/dev/null; done
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  [ -n "${LIVE:-}" ] && live
  echo "restored"
}
