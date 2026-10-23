#!/bin/bash
# linux-float.sh [OUT]: Linux apps float on the unfolded home (board tasks "Linux apps from the launcher open floating"
# and "Linux apps opened by other apps ... get floating windows"), for a phone left unattended:
#   1. KWin 6.7.5-3.22+ (pkgs/kwin 0018: "export-new", new windows open as tasks) installed AND running - installed
#      with pacman -U (rollback tar of the old files, as bf-fold.sh) and a fresh session when the running one is older
#      (never with a game up);
#   2. Dolphin opened THROUGH HOME's launch path (apps.launch l:org.kde.dolphin, the bridge call a tap makes) is ONE
#      floating task (PowosWindowActivity, freeform, smaller than the screen), windows.list names it;
#   3. an image opened the way Dolphin opens one (kioclient exec: KIO's OpenUrlJob, KDE's own file association) comes
#      up as exactly ONE more floating task, Gwenview's, and one Gwenview window in KWin (no duplicates, nothing left
#      on the hidden desktop). Leftover Gwenview windows (six from 2026-10-23's tries) are closed first.
# Always restores: Gwenview closed, Dolphin closed if this started it, home, `cmd device_state state reset`.
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
#   KWIN_PKG=<pkg.tar.xz> (default: the newest targets/android/out/pkgs/kwin-*.pkg.tar.xz of this checkout or a
#   sibling worktree's)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/linux-float-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
IMG=/usr/share/wallpapers/Next/contents/images/1440x2960.png
PKG=${KWIN_PKG:-$(ls -t "$ROOT"/targets/android/out/pkgs/kwin-*.pkg.tar.xz "$ROOT"/../*/targets/android/out/pkgs/kwin-*.pkg.tar.xz 2>/dev/null | head -1)}
WANT=$(basename "${PKG:-none}" | sed -E 's/^kwin-([^-]+-[^-]+)-.*/\1/')
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
DOLPHIN_MINE=0
restore() {
  us "pkill -x gwenview; [ $DOLPHIN_MINE = 1 ] && pkill -x dolphin; true"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  sh_ "logcat -d -v time" | grep -E "WindowTasks|PowosWindow|PowosWindowFrames| runtime" > "$OUT/logcat.txt"
  echo "restored"
}
. "$here/window-lock.sh"
window_lock linux-float.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
# A call on home's bridge exactly as the page makes it (float-windows.sh's hcall).
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
lin() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
mode() { sh_ "dumpsys activity activities" | grep -m1 -E "Task\{[^ ]* #$1 " | grep -oE "mode=[a-z-]+"; }
bounds() { sh_ "am stack list | grep -E \"taskId=$1:\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
app_of() { hcall windows.list "[]" "l=>(l.find(w=>w.id===$1)||{app:'none'}).app||'none'"; }
# Waits up to $1 s for task ids not in $2 (newline list); prints them.
new_tasks() { local n="" i; for i in $(seq 1 "$1"); do sleep 1; n=$(comm -13 <(echo "$2") <(lin)); [ -n "$n" ] && break; done; echo "$n"; }
floats() {  # $1 task, $2 name: freeform and smaller than the screen
  local m b; m=$(mode "$1"); read -r b1 b2 b3 b4 <<<"$(bounds "$1")"; log "$2: task $1 $m bounds $b1,$b2 $b3,$b4"
  [ "$m" = mode=freeform ] || fail "$2's task $1 is $m, not a floating window"
  [ $((b3 - b1)) -lt $((W * 9 / 10)) ] || fail "$2's window is $((b3 - b1)) px wide on a $W px screen: full width"
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || fail "enable_freeform_support isn't 1"

# 1. KWin with export-new, running.
have=$(rs 'pacman -Q kwin | cut -d" " -f2' | tail -1)
kw() { rs 'k=$(pgrep -x kwin_wayland | head -1); n=0; [ -n "$k" ] && ! grep -q "libkwin.*(deleted)" /proc/$k/maps && n=1; echo "kwin=${k:--} kwin_new=$n"' | tail -1; }
log "kwin installed $have, package $WANT (${PKG:-none})"
if [ -n "${PKG:-}" ] && [ "$have" != "$WANT" ] && [ "$(printf '%s\n%s\n' "$have" "$WANT" | sort -V | tail -1)" = "$WANT" ]; then
  "$A" push "$PKG" /data/local/tmp/powos-kwin.pkg.tar.xz >/dev/null
  sh_ "mv /data/local/tmp/powos-kwin.pkg.tar.xz /data/powos/root/var/tmp/"
  rs "set -e; mkdir -p /var/cache/powos
pacman -Qlq kwin | while read -r f; do [ -f \"\$f\" ] && echo \"\$f\"; done | tar -cf /var/cache/powos/kwin-$have-files.tar -T -
pacman -U --noconfirm /var/tmp/powos-kwin.pkg.tar.xz >/dev/null && rm -f /var/tmp/powos-kwin.pkg.tar.xz
pacman -Q kwin" | tail -1 | tee -a "$OUT/log.txt"
fi
st=$(kw); log "running: $st"
if [[ $st != *kwin_new=1* ]]; then
  [ -z "$(rs 'pgrep -f "steam_app_|reaper SteamLaunch" | head -1')" ] || { log "a game runs on the old KWin: no fresh session now"; exit 3; }
  chk session
  log "fresh session for the new KWin"
  us "android-request power logout"; sleep 20
  for _ in $(seq 30); do st=$(kw); [[ $st == *kwin_new=1* ]] && break; sleep 5; done
  log "after the fresh session: $st"
  [[ $st == *kwin_new=1* ]] || fail "KWin didn't come back on the new package (rollback: tar -xf /var/cache/powos/kwin-$have-files.tar -C /)"
  sleep 15
fi
[ "$(rs 'grep -ac "export-new" /usr/lib/libkwin.so.6 2>/dev/null' | tail -1)" != 0 ] || fail "the running KWin has no export-new (pkgs/kwin 0018)"

# The inner screen, unlocked, home in front.
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
[ "${W:-0}" -gt 2000 ] || fail "display 0 is ${W:-?}x${H:-?}, not the unfolded inner screen"
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?)"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
sh_ "logcat -c"

# Leftover Gwenview windows (each try that showed nothing left one on the hidden desktop): closed.
g=$(us 'pgrep -xc gwenview' | tail -1); log "gwenview processes before: ${g:-0}"
[ "${g:-0}" = 0 ] || { us "pkill -x gwenview"; sleep 2; }

# 2. Dolphin from the launcher.
[ "$(us 'pgrep -xc dolphin' | tail -1)" = 0 ] && DOLPHIN_MINE=1
before=$(lin)
r=$(hcall apps.launch "['l:org.kde.dolphin']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch l:org.kde.dolphin: $r"
DT=$(new_tasks 30 "$before" | tail -1); chk dolphin
[ -n "$DT" ] || DT=$(lin | while read -r t; do [ "$(app_of "$t")" = l:org.kde.dolphin ] && echo "$t"; done | head -1)
[ -n "$DT" ] || fail "no window task for Dolphin within 30 s (logcat: $(sh_ "logcat -d -v time" | grep -E "WindowTasks| runtime" | tail -3 | tr '\n' ' '))"
sleep 2; floats "$DT" Dolphin; "$T/shot.sh" "$OUT/dolphin.png"
[ "$(app_of "$DT")" = l:org.kde.dolphin ] && pass "Dolphin from the launcher floats (task $DT), windows.list names it" ||
  fail "Dolphin's task $DT is '$(app_of "$DT")' in windows.list"

# 3. An image opened the way Dolphin opens it.
before=$(lin)
# setsid: out of the user.sh session, whose end took a plain `nohup ... &` kioclient with it before Gwenview started
# ("gwenview processes: 0", 2026-10-23 - likely; its log below says). KDE picks Gwenview (InitialPreference 8 over
# Brave's 1 for image/png).
us "setsid -f kioclient exec $IMG >/tmp/linux-float-kio.log 2>&1 < /dev/null"
GT=$(new_tasks 25 "$before"); sleep 3; chk gwenview
log "kioclient said: $(us 'tail -3 /tmp/linux-float-kio.log' | tr '\n' ' ')"
GT=$(comm -13 <(echo "$before") <(lin)); n=$(echo "$GT" | grep -c .)
g=$(us 'pgrep -xc gwenview' | tail -1); log "new tasks: $(echo $GT) gwenview processes: $g"
[ "$n" -ge 1 ] || fail "opening an image made no window task in 25 s (export-new?)"
[ "$n" = 1 ] || fail "opening one image made $n tasks ($(echo $GT)): duplicates"
GT=$(echo "$GT" | tail -1); floats "$GT" Gwenview; "$T/shot.sh" "$OUT/gwenview.png"
ga=$(app_of "$GT"); [ "$ga" = l:org.kde.gwenview ] || fail "the image opened in '$ga' (task $GT), not Gwenview"
[ "$g" = 1 ] || fail "$g Gwenview processes for one image"
pass "an image opened from Dolphin's path floats as one Gwenview window (task $GT)"
# Its frame's close: the task goes and, with export-new, so does the window.
sh_ "am stack remove $GT"; sleep 2.5
[ "$(us 'pgrep -xc gwenview' | tail -1)" = 0 ] && pass "closing its task closes Gwenview" || fail "Gwenview still runs after its task closed"
echo "all passed; artefacts: $OUT"
