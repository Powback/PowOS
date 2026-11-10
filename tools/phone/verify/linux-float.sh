#!/bin/bash
# lanes: phone
# needs: kwin
# linux-float.sh [OUT]: Linux apps float on the unfolded home (board tasks "Linux apps from the launcher open floating"
# and "Linux apps opened by other apps ... get floating windows"), for a phone left unattended:
#   1. KWin 6.7.5-3.22+ (pkgs/kwin 0018: "export-new", new windows open as tasks) installed AND running - installed
#      with pacman -U (rollback tar of the old files, as bf-fold.sh) and a fresh session when the running one is older
#      (never with a game up);
#   2. Dolphin opened THROUGH HOME's launch path (state.ts launch('l:org.kde.dolphin'), what a launcher tap runs) is
#      ONE floating web window (W1, docs/WEB_WINDOWS.md: home's webwindows.list key l:org.kde.dolphin, state floating,
#      its frame on the unfolded screen and smaller than it) within 30 s; its body DRAWS: live (no placeholder) and
#      not black (Kate and Dolphin floated with black content, 2026-10-23) - and so does Kate's, opened the same way;
#   3. Gwenview opened from inside the session (the session's own environment, as Dolphin's "Open With" starts it: a
#      Wayland window) comes up as exactly ONE more floating web window, and closing it (its bar's close:
#      webwindows.close) closes Gwenview; then again as an X11 window (QT_QPA_PLATFORM=xcb: an Xwayland window gets its
#      wl_surface after KWin adds it - kwin 0019).
#      Leftover Gwenview windows (six from 2026-10-23's tries) are closed first.
# Always restores: Gwenview closed, Dolphin closed if this started it, home, `cmd device_state state reset`.
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
#   KWIN_PKG=<pkg.tar.xz> (default: the newest targets/android/out/pkgs/kwin-*.pkg.tar.xz of this checkout or a
#   sibling worktree's)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/linux-float-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
IMG=/usr/share/wallpapers/Next/contents/images/1440x2960.png
PKG=${KWIN_PKG:-$(ls -t "$ROOT"/targets/android/out/pkgs/kwin-*.pkg.tar.xz "$ROOT"/../*/targets/android/out/pkgs/kwin-*.pkg.tar.xz \
  "${POWOS_BUILD_INPUTS_CACHE:-$HOME/.cache/powos-build-inputs}"/pkgs/kwin-*.pkg.tar.xz 2>/dev/null | head -1)}
WANT=$(basename "${PKG:-none}" | sed -E 's/^kwin-([^-]+-[^-]+)-.*/\1/')
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
# $1 run in the Plasma session's own environment (plasmashell's: WAYLAND_DISPLAY, XDG_SESSION_TYPE, XAUTHORITY...) -
# user.sh's has none of them, so a Qt app started there was an X11 window (2026-10-23), not what the session starts.
ses() { us "P=\$(pgrep -x plasmashell | head -1); while IFS= read -r -d '' kv; do export \"\$kv\"; done < /proc/\$P/environ; $1"; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
DOLPHIN_MINE=0 KATE_MINE=0 GWEN_MINE=0
restore() {
  us "[ $GWEN_MINE = 1 ] && pkill -x gwenview; [ $DOLPHIN_MINE = 1 ] && pkill -x dolphin; [ $KATE_MINE = 1 ] && pkill -x kate; true"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  # The window lines, streamed since the start (LOGPID): a dump at the end lost them - the OnePlus main ring buffer
  # rolls over in ~1 min under system_server's D-level spam (f276: the run's own "open"/"surface" lines missing).
  [ -n "${LOGPID:-}" ] && kill "$LOGPID" 2>/dev/null
  [ -s "$OUT/logcat.txt" ] || sh_ "logcat -d -v time" | grep -E "WindowTasks|WebWindowSource|PowosWebWindows|PowosWindow| runtime" > "$OUT/logcat.txt"
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
# Home's page (ev) and bridge (hcall), and the web-window helpers: ww-lib.sh, shared with e2e-lib.sh.
. "$here/ww-lib.sh"
# Linux windows are web windows since 10-30 (docs/WEB_WINDOWS.md S6: no PowosWindowActivity task): ids "w<id>" from
# home's webwindows.list (key "l:<app>", state), where each is from its .webwindow element on home's page.
lin() { wwids l:; }
mode() { wwhost "$1" state; }
bounds() { wwrect "$1"; }
app_of() { wwhost "$1" key; }
# Page calls as a tap makes them: the launcher's (state.ts launch), the dock's (dockToggle), a switcher card's (the
# host's webwindows.show event, ShellBridge.openTask).
plaunch() { ev "importShim('./state.ts').then(m=>m.launch('$1')).then(()=>'ok',e=>'ERR '+e)"; }
pdock() { ev "importShim('./ui/webwindows.tsx').then(m=>String(m.dockToggle('$1')))"; }
pcard() { ev "(window.__powosHost.emit('webwindows.show', ${1#w}), 'ok')"; }
# Waits up to $1 s for Linux windows not in $2 (lin's lines); prints them.
new_tasks() { wwnew "$1" "$2" l:; }
floats() {  # $1 window, $2 name: floating, its frame on the unfolded screen and smaller than it
  local m b1 b2 b3 b4; m=$(mode "$1"); read -r b1 b2 b3 b4 <<<"$(bounds "$1")"; log "$2: window $1 $m frame $b1,$b2 $b3,$b4"
  [ "$m" = floating ] || fail "$2's window $1 is ${m:-?}, not a floating window"
  [ -n "${b4:-}" ] || fail "$2's window $1 has no frame on the screen"
  [ "$b1" -ge 0 ] && [ "$b2" -ge 0 ] && [ "$b3" -le "$W" ] && [ "$b4" -le "$H" ] || fail "$2's frame $b1,$b2 $b3,$b4 isn't on the ${W}x$H screen"
  [ $((b3 - b1)) -lt $((W * 9 / 10)) ] || fail "$2's window is $((b3 - b1)) px wide on a $W px screen: full width"
}
# draws <window> <name>: live (its app's frames, not the placeholder: that is the theme's surface, never black), then a
# screencap; its body (inset past the edges) must not be black -
# at least 20% of its pixels brighter than 24/255 (a light KDE window), or at least 3% brighter than 64/255 (text and
# icons of a DARK one: the Breeze dark theme since 2026-10-23 drew Dolphin fully at 18% over 24 - read as black), or
# a dark theme's base colour nearly everywhere (90% over 8: Breeze dark's view is 13/255) with some detail (1% over
# 64). Dolphin in a near-empty folder (it reopens the last one: sketch/out/ui/pages, one file) was fully drawn at 5%
# over 24 and 2% over 64 - three false "black" FAILs 2026-10-24 18:27-18:50. A black window has ~0% of all of them.
draws() {
  local png="$OUT/$2.png" b1 b2 b3 b4 f i lv=""
  for i in $(seq 1 15); do lv=$(wwel "$1" "e=>e.querySelector('.webwindow-body.live')?'live':'placeholder'"); [ "$lv" = live ] && break; sleep 1; done
  [ "$lv" = live ] || fail "$2's window $1 is still '${lv:-?}' after 15 s, not its app's content"
  read -r b1 b2 b3 b4 <<<"$(wwbody "$1")"; [ -n "${b4:-}" ] || fail "$2's window $1 has no body on the screen"
  "$T/shot.sh" "$png" >/dev/null 2>&1 || fail "no screencap for $2 (shot.sh)"
  f=$(ffmpeg -v error -i "$png" -vf "crop=$((b3 - b1 - 40)):$((b4 - b2 - 40)):$((b1 + 20)):$((b2 + 20)),scale=200:-1,format=gray" \
      -f rawvideo - 2>/dev/null | python3 -c 'import sys; d=sys.stdin.buffer.read(); n=max(len(d), 1); print(sum(1 for b in d if b > 24) * 100 // n, sum(1 for b in d if b > 64) * 100 // n, sum(1 for b in d if b > 8) * 100 // n)')
  local base=${f##* }; f=${f% *}; local lit=${f#* }; f=${f%% *}
  log "$2: ${f:-?}% of its window drawn (not black), ${lit:-?}% bright detail, ${base:-?}% dark-theme base"
  [ "${f:-0}" -ge 20 ] || [ "${lit:-0}" -ge 3 ] || { [ "${base:-0}" -ge 90 ] && [ "${lit:-0}" -ge 1 ]; } ||
    fail "$2's window is black (${f:-?}% drawn, ${lit:-?}% bright detail, ${base:-?}% base) - $png"
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
# Physically folded, the forced state 3 doesn't take (11-01 04:32: 1116x2484, the cover): not now, re-queued - not a FAIL.
[ "${W:-0}" -gt 2000 ] || { log "display 0 is ${W:-?}x${H:-?}, not the unfolded inner screen (folded?): not now"; exit 3; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?)"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
sh_ "logcat -c"
"$A" shell "su -c 'logcat -v time -s WindowTasks:V WebWindowSource:V PowosWebWindows:V PowosWindow:V PowosWindowFrames:V PowosWindowFrame:V LaunchWindows:V AndroidRuntime:E'" 2>/dev/null \
  | tr -d '\r' > "$OUT/logcat.txt" & LOGPID=$!

# A Gwenview already running may be the user's: never closed (rule) - not now. Only the ones this check starts are
# closed at the end (GWEN_MINE), like Dolphin and Kate.
g=$(us 'pgrep -xc gwenview' | tail -1); log "gwenview processes before: ${g:-0}"
[ "${g:-0}" = 0 ] || { echo "gwenview already runs (maybe the user's): not now"; exit 3; }
GWEN_MINE=1

# 2. Dolphin from the launcher.
[ "$(us 'pgrep -xc dolphin' | tail -1)" = 0 ] && DOLPHIN_MINE=1
before=$(lin)
r=$(ev "importShim('./ui/webwindows.tsx').then(m=>m.webWindowsOn()).then(String)"); [ "$r" = true ] || fail "home's web windows aren't on (webWindowsOn: ${r:-?}): Linux apps would open as tasks"
r=$(plaunch l:org.kde.dolphin); [ "$r" = ok ] || fail "launch l:org.kde.dolphin: $r"
DT=$(new_tasks 30 "$before" | tail -1); chk dolphin
[ -n "$DT" ] || DT=$(lin | while read -r t; do [ "$(app_of "$t")" = l:org.kde.dolphin ] && echo "$t"; done | head -1)
[ -n "$DT" ] || fail "no web window for Dolphin within 30 s (logcat: $(grep -E "WindowTasks|WebWindowSource|PowosWebWindows" "$OUT/logcat.txt" | tail -3 | tr '\n' ' '))"
sleep 2; floats "$DT" Dolphin; "$T/shot.sh" "$OUT/dolphin.png"
[ "$(app_of "$DT")" = l:org.kde.dolphin ] && pass "Dolphin from the launcher floats (window $DT), webwindows.list names it" ||
  fail "Dolphin's window $DT is '$(app_of "$DT")' in webwindows.list"
sleep 3; draws "$DT" dolphin; pass "Dolphin's window draws its content"

# 2b. Kate from the launcher: floats and draws (e2e-desktop's 04-kate.png was black).
[ "$(us 'pgrep -xc kate' | tail -1)" = 0 ] && KATE_MINE=1
before=$(lin)
r=$(plaunch l:org.kde.kate); [ "$r" = ok ] || fail "launch l:org.kde.kate: $r"
KT=$(new_tasks 30 "$before" | tail -1); chk kate
[ -n "$KT" ] || fail "no web window for Kate within 30 s"
[ "$(app_of "$KT")" = l:org.kde.kate ] || fail "Kate's window $KT is '$(app_of "$KT")' in webwindows.list"
sleep 4; floats "$KT" Kate; draws "$KT" kate; pass "Kate from the launcher floats (window $KT) and draws its content"
# 2c. Opening Kate leaves Dolphin as it was (2026-10-24: KWin's second "open" for Kate raised its task from recents,
# which sent Dolphin's task TO_BACK - Dolphin minimised as Kate showed). Both stay visible, neither minimised: a web
# window is visible = floating in the host's list and its frame on the screen.
vis() { [ "$(mode "$1")" = floating ] && [ -n "$(bounds "$1")" ] && echo visible=true || echo "visible=false ($(mode "$1"))"; }
[ "$(vis "$DT")" = visible=true ] || fail "Dolphin's window $DT went $(vis "$DT") when Kate opened: minimised by Kate's launch"
[ "$(vis "$KT")" = visible=true ] || fail "Kate's window $KT is $(vis "$KT") after opening"
pass "Dolphin then Kate: both stay visible, neither minimised"
# 2d. Raising the window behind keeps the other one (2026-10-24, f257: a raise was startActivityFromRecents, a TO_FRONT
# that sent every other floating task TO_BACK). As the page does it now: the dock (dockToggle), the switcher's card
# (the host's webwindows.show) and a launcher tap on an app whose window is open (launch: linuxWindow raises it).
both() {  # $1 how: both windows visible, $2 the raised one on top (the page's webWins order)
  sleep 2.5
  [ "$(vis "$DT")" = visible=true ] || fail "$1: Dolphin's window $DT went $(vis "$DT")"
  [ "$(vis "$KT")" = visible=true ] || fail "$1: Kate's window $KT went $(vis "$KT")"
  local top; top=$(wwtop "$DT" "$KT")
  log "$1: of Dolphin/Kate, window ${top:-?} is on top"
  [ "$top" = "$2" ] || fail "$1: window $2 asked for the front, window ${top:-?} is on top"
  bars "$1"
  pass "$1: window $2 raised, Dolphin and Kate both still visible, each with its title bar"
}
# Each showing window keeps its PowOS title bar after a raise (2026-10-24 18:22, "i dont see the titlebars for floating
# windows anymore": the window left under the raised one lost its bar). A web window's bar is its frame's
# .webwindow-title (it replaced the "PowOS window bar" layer over a task).
bars() {
  local id b
  for id in "$DT" "$KT"; do
    b=$(wwbar "$id"); log "$1: window $id title bar shown: ${b:-?}"
    [ "$b" = true ] || fail "$1: window $id shows with no PowOS title bar on screen"
  done
}
r=$(pdock l:org.kde.dolphin); log "dock: dockToggle dolphin: $r"; both "dock tap on Dolphin (behind Kate)" "$DT"
r=$(pcard "$KT"); log "switcher card: webwindows.show $KT: $r"; both "switcher card of Kate (behind Dolphin)" "$KT"
r=$(plaunch l:org.kde.dolphin); log "launch dolphin again: $r"; both "launcher tap on open Dolphin (behind Kate)" "$DT"
# 2e. One web window per Linux window, none without its window (2026-10-24 18:33, "i got two kate windows now one
# black": KWin's second "open 2" came before the adopted launch window registered and started task 2970 for window 2
# too). One Dolphin and one Kate window are open: webwindows.list names exactly one "l:" window for each, every one is
# one of the two, and each draws (a window with nothing feeding its content is black).
one_each() {
  local all t a nd=0 nk=0
  all=$(lin); log "after the launches and raises: Linux web windows $(echo $all)"
  for t in $all; do
    a=$(app_of "$t"); log "window $t: $a"
    case "$a" in
      l:org.kde.dolphin) nd=$((nd + 1)) ;;
      l:org.kde.kate) nk=$((nk + 1)) ;;
      *) fail "web window $t ('$a') is no Dolphin or Kate window: a window without its KWin window" ;;
    esac
    draws "$t" "one-each-$t"
  done
  [ "$nd" = 1 ] && [ "$nk" = 1 ] || fail "$nd Dolphin and $nk Kate web windows for one KWin window each: duplicates"
  pass "one web window per Linux window (Dolphin $DT, Kate $KT), each drawing"
}
one_each

# 3. Gwenview started from inside the session (Dolphin's "Open With > Gwenview": another app's window, no launch path
# of PowOS's): one more floating web window, and closing it closes Gwenview. Not through kioclient: KIO opened the PNG in
# Brave (the user's file association - left alone). Once as the session starts it (a Wayland window), once as an X11
# window (Xwayland: its wl_surface comes after KWin adds it, and export-new looked only then - kwin 0019).
gwen() {  # $1 label, $2 extra environment
  local before GT n g ga
  before=$(lin)
  ses "$2 setsid -f gwenview $IMG >/tmp/linux-float-gwen.log 2>&1 < /dev/null"
  GT=$(new_tasks 25 "$before"); sleep 3; chk "gwenview $1"
  GT=$(comm -13 <(echo "$before") <(lin)); n=$(echo "$GT" | grep -c .)
  g=$(us 'pgrep -xc gwenview' | tail -1); log "Gwenview ($1): new windows: $(echo $GT) gwenview processes: $g; it said: $(us 'grep -v -e udisks2 -e locale -e UTF-8 -e "more information" /tmp/linux-float-gwen.log | tail -3' | tr '\n' ' ')"
  [ "$n" -ge 1 ] || fail "Gwenview ($1) made no web window in 25 s"
  [ "$n" = 1 ] || fail "one Gwenview ($1) made $n web windows ($(echo $GT)): duplicates"
  GT=$(echo "$GT" | tail -1); floats "$GT" "Gwenview ($1)"
  ga=$(app_of "$GT"); [ "$ga" = l:org.kde.gwenview ] || fail "Gwenview ($1)'s window $GT is '$ga' in webwindows.list"
  [ "$g" = 1 ] || fail "$g Gwenview processes for one image"
  pass "Gwenview opened from the session ($1) floats as one window ($GT)"
  # Its bar's close (webwindows.close: KWin's quit, kwin 0041): the window goes and so does Gwenview.
  r=$(hcall webwindows.close "[${GT#w}]" "v=>String(v)"); log "webwindows.close $GT: $r"; sleep 2.5
  [ "$(wwhost "$GT" gone)" = true ] || fail "Gwenview ($1)'s window $GT is still listed after its close"
  [ "$(us 'pgrep -xc gwenview' | tail -1)" = 0 ] && pass "closing its window closes Gwenview ($1)" || fail "Gwenview ($1) still runs after its window closed"
}
gwen wayland ""
gwen x11 "QT_QPA_PLATFORM=xcb"
echo "all passed; artefacts: $OUT"
