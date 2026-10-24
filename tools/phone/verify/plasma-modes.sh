#!/bin/bash
# lanes: phone
# needs: kwin
# plasma-modes.sh MODE [OUT]: Plasma and the PowOS web shell each work on their own and together (the user,
# 2026-10-24: "both plasma and our webui should both work perfectly independently and together"; docs/DESKTOP-NATIVE.md).
# Mac side, queue it: queue.sh add <board-task> tools/phone/verify/plasma-modes.sh <plasma|shell|together>
#   plasma    Plasma alone (the Plasma app, l:org.powos.plasma): Kate started inside the session is a KWin window ON
#             Plasma's desktop with KDE's decoration and NO Android window task; a tap + keys reach it (its caption
#             gets Kate's modified mark); a drag on its title bar moves it; KWin's maximize (the window operation the
#             title bar's button and double tap run) maximizes it the KDE way (frame = the work area) and still no
#             task; the Menu key's popup, if one comes up, lies inside the screen.
#   shell     the web shell alone (home): Kate from home's launch call (apps.launch l:org.kde.kate) is ONE window task
#             (PowosWindowActivity), its KWin window on the hidden tasks desktop (not on Plasma's), one PowOS title
#             bar for it, and a tap + keys reach it (caption marked modified).
#   popup     a task's popups stay inside it (kwin 0027, >= 6.7.5-3.31): Kate from home as a window task, its cursor
#             taken to the bottom line of the view (Enter x 60), then the Menu key's context menu - placed against the
#             output it ran below the task and was cut off. PASS when the popup's frame lies inside Kate's client area
#             (what the task shows), 1 logical px slack.
#   together  both: Kate as a task from home, then the Plasma app: Kate stays its task (not also on Plasma's desktop),
#             SurfaceFlinger composes Android's wallpaper directly under the desktop's translucent surface (no layer
#             that could show black between them); Dolphin started inside Plasma stays a KWin window, and going home
#             keeps it there (kwin 0025: the desktop's own windows are never pulled out into floating tasks).
# Every mode first has the newest built KWin running, >= 6.7.5-3.29 (kwin-up.sh: install + a fresh session if stale).
# Kate/Dolphin must not be running (maybe the user's: exit 3). Ours are closed at the end, home in front.
# Exit: 0 passed; 1 FAIL; 3 a real touch / not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
MODE=${1:-}; case "$MODE" in plasma|shell|together|popup) ;; *) sed -n 2,24p "$0"; exit 5 ;; esac
OUT=${2:-$HOME/.cache/powos-verify/plasma-modes-$MODE-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
KWIN_MIN=6.7.5-3.29; [ "$MODE" = popup ] && KWIN_MIN=6.7.5-3.31
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -av -e "file pushed" -e locale -e "Qt depends" -e "If this causes" -e "for more information" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
RC=0; MINE=""
fail() { echo "FAIL [$MODE] $*" | tee -a "$OUT/log.txt"; RC=1; }
pass() { echo "PASS [$MODE] $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
restore() {
  for p in $MINE; do us "pkill -x $p; true" >/dev/null; done
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  sh_ "logcat -d -v time" | grep -aE "WindowTasks|PowosWindow" | tail -200 > "$OUT/logcat.txt"
  echo "restored; files in $OUT"
}
. "$here/window-lock.sh"
window_lock plasma-modes.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=911400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',$2]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:'ok')" 2>&1 | tr -d '"\r' | tail -1
}
tasks() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
focus() { sh_ "dumpsys window | grep -m1 mCurrentFocus" | sed 's/^ *//'; }

# KWin's view (a script; its print() lands in KWin's stdout, /run/powos-app/hyprland.log): one line per application
# window "PMW|caption|class|onCurrentDesktop|noBorder|x,y,w,h|maximized|popup|deleted" and "PMC|class|x,y,w,h" (its
# client area), then "PMS|scale|current desktop".
KJS='var cur = workspace.currentDesktop, scr = workspace.activeScreen, tag = "PMQ-" + Date.now();
var sc = scr ? (2268 / scr.geometry.width) : 0;
print("PMS|" + sc.toFixed(3) + "|" + (cur ? cur.name : "?"));
workspace.windowList().forEach(function (w) {
  if (!(w.normalWindow || w.popupWindow || w.dialog) || w.specialWindow) return;
  var g = w.frameGeometry, m = workspace.clientArea(KWin.MaximizeArea, w);
  var onCur = w.desktops.length === 0;
  var dn = [];
  for (var i = 0; i < w.desktops.length; i++) { dn.push(w.desktops[i].name); if (cur && (w.desktops[i] === cur || w.desktops[i].id === cur.id || w.desktops[i].name === cur.name)) onCur = true; }
  if (w.onAllDesktops) onCur = true;
  var maxd = Math.abs(g.x - m.x) < 2 && Math.abs(g.y - m.y) < 2 && Math.abs(g.width - m.width) < 2 && Math.abs(g.height - m.height) < 2;
  print("PMW|" + w.caption + "|" + w.resourceClass + "|" + onCur + "|" + w.noBorder + "|" + [Math.round(g.x), Math.round(g.y), Math.round(g.width), Math.round(g.height)].join(",") + "|" + maxd + "|" + w.popupWindow + "|" + w.deleted + "|" + dn.join(","));
  var c = w.clientGeometry;
  if (c && !w.popupWindow) print("PMC|" + w.resourceClass + "|" + [Math.round(c.x), Math.round(c.y), Math.round(c.width), Math.round(c.height)].join(","));
});'
kwin_q() {  # -> OUT/kwin-<n>.txt; prints its PMW/PMS lines
  printf '%s\n' "$KJS" > "$OUT/pm.js"
  "$A" push "$OUT/pm.js" /data/local/tmp/pm.js >/dev/null 2>&1; sh_ "mv /data/local/tmp/pm.js /data/powos/root/tmp/pm.js; chmod 644 /data/powos/root/tmp/pm.js"
  us 'n=$(grep -ac . /run/powos-app/hyprland.log); qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript pmq >/dev/null 2>&1
id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript /tmp/pm.js pmq 2>/dev/null)
qdbus6 org.kde.KWin /Scripting/Script$id org.kde.kwin.Script.run >/dev/null 2>&1; sleep 1
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript pmq >/dev/null 2>&1
tail -n +$((n + 1)) /run/powos-app/hyprland.log | grep -a -oE "PM[SW]\|.*"' | tee "$OUT/kwin-$1.txt"
}
# $2 = class, bare or reverse-DNS: KWin reports Kate as org.kde.kate (the desktop-file id), so a bare `kate` never
# matched and every mode said "no Kate window in KWin" while Kate's window was in the list (2026-10-24, kwin 3.31).
win() { grep -aE "^PMW\|[^|]*\|([^|]*\.)?$2\|" "$OUT/kwin-$1.txt" | grep -avE "\|true\|[^|]*$" | grep -avE "\|true\|false\|[^|]*$" | head -1; }
field() { cut -d'|' -f"$2" <<<"$1"; }
SCALE=1
px() { awk -v v="$1" -v s="$SCALE" 'BEGIN{printf "%d", v * s}'; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
for p in kate dolphin; do [ -n "$(us "pgrep -x $p" | tail -1)" ] && { echo "$p already runs (maybe the user's): not now"; exit 3; }; done
[ "$(us "pgrep -fc 'SteamLaunch AppId='" | tail -1)" = 0 ] || { echo "a game runs under Steam (the user's): not now"; exit 3; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
if sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true; then sh_ "wm dismiss-keyguard"; sleep 1.5; fi
. "$here/kwin-up.sh"
kwin_up "$KWIN_MIN"; chk kwin
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 3; chk home
log "apk $(sh_ "dumpsys package com.powos.app | grep -m1 versionName" | sed 's/ *//'), kwin $(us 'pacman -Q kwin' | tail -1)"

# A KDE app started inside the session (its own environment: plasmashell's), as Kickoff or Dolphin would.
in_session() { us "P=\$(pgrep -x plasmashell | head -1); while IFS= read -r -d '' kv; do export \"\$kv\"; done < /proc/\$P/environ; setsid $1 >/dev/null 2>&1 < /dev/null & echo started" >/dev/null; MINE="$MINE $1"; }
open_plasma() {
  local r; r=$(hcall apps.launch "['l:org.powos.plasma']"); [ "$r" = ok ] || { fail "apps.launch Plasma: $r"; return 1; }
  sleep 6; chk plasma
  focus | grep -qE 'andro\.marchy\.(MainActivity|HomeDesktop)' || { fail "Plasma's desktop isn't in front: $(focus)"; return 1; }
}
wait_win() {  # $1 class, $2 tag -> W (its line) within 25 s
  W=""; for i in $(seq 8); do sleep 3; kwin_q "$2-$i" >/dev/null; W=$(win "$2-$i" "$1"); [ -n "$W" ] && { cp "$OUT/kwin-$2-$i.txt" "$OUT/kwin-$2.txt"; return 0; }; done; return 1
}
# Kate opens on a Welcome page with no text view: keys have nowhere to go and the caption can't change. Ctrl+N (after
# a tap that focuses the window) opens an empty document first; c0 is read after it.
newdoc() {  # $1 x, $2 y (physical) -> W, c0
  sh_ "input tap $1 $2"; sleep 1; sh_ "input keycombination 113 42"; sleep 2
  kwin_q doc >/dev/null; W=$(win doc kate); c0=$(field "$W" 2)
}
typed() {  # $1 x, $2 y (physical): tap there, type; Kate's caption gets its modified mark
  sh_ "input tap $1 $2"; sleep 1; sh_ "input text powosmodes"; sleep 2
}

mode_plasma() {
  local before after g x y w h tx ty c0
  open_plasma || return
  before=$(tasks); in_session kate
  wait_win kate kate || { fail "no Kate window in KWin within 25 s"; return; }
  SCALE=$(grep -a '^PMS|' "$OUT/kwin-kate.txt" | cut -d'|' -f2); log "KWin scale $SCALE; Kate: $W"
  after=$(tasks); [ "$before" = "$after" ] && pass "Kate opened in Plasma is no Android window task" || fail "Kate opened in Plasma became a window task ($(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' '))"
  [ "$(field "$W" 4)" = true ] && pass "Kate is on Plasma's current desktop" || fail "Kate isn't on Plasma's current desktop: $W"
  [ "$(field "$W" 5)" = false ] && pass "Kate has KDE's decoration (noBorder false)" || fail "Kate has no KDE decoration: $W"
  IFS=, read -r x y w h <<<"$(field "$W" 6)"
  newdoc "$(px $((x + w / 2)))" "$(px $((y + h / 2)))"; log "Kate's new document: '$c0'"
  "$T/shot.sh" "$OUT/plasma-kate.png" >/dev/null 2>&1
  typed "$(px $((x + w / 2)))" "$(px $((y + h / 2)))"; chk type
  kwin_q typed >/dev/null; W=$(win typed kate)
  [ "$(field "$W" 2)" != "$c0" ] && pass "a tap + keys reached Kate (caption '$c0' -> '$(field "$W" 2)')" || fail "a tap + keys changed nothing in Kate's caption ('$c0')"
  IFS=, read -r x y w h <<<"$(field "$W" 6)"
  tx=$(px $((x + w / 2))); ty=$(px $((y + 14)))
  sh_ "input swipe $tx $ty $((tx + $(px 60))) $((ty + $(px 50))) 700"; sleep 2; chk move
  kwin_q moved >/dev/null; W=$(win moved kate)
  [ "$(field "$W" 6)" != "$x,$y,$w,$h" ] && pass "a title-bar drag moved Kate ($x,$y -> $(field "$W" 6))" || fail "a title-bar drag didn't move Kate ($(field "$W" 6))"
  IFS=, read -r x y w h <<<"$(field "$W" 6)"
  tx=$(px $((x + w / 2))); ty=$(px $((y + 14)))
  # KWin's maximize window operation (performWindowOperation, the one the title bar's button / double tap run and
  # kwin 0014's platform hook sees); a double tap from `input` is two JVM starts apart, slower than a double click.
  us 'qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut "Window Maximize"' >/dev/null; sleep 2; chk maximize
  kwin_q max >/dev/null; W=$(win max kate)
  [ "$(field "$W" 7)" = true ] && pass "KWin's maximize maximized Kate the KDE way ($(field "$W" 6))" || fail "KWin's maximize didn't maximize Kate in Plasma: $W"
  after=$(tasks); [ "$before" = "$after" ] && pass "maximized, Kate is still no Android task" || fail "maximize sent Kate out into an Android task"
  "$T/shot.sh" "$OUT/plasma-kate-max.png" >/dev/null 2>&1
  IFS=, read -r x y w h <<<"$(field "$W" 6)"
  sh_ "input tap $(px $((x + w / 2))) $(px $((y + h / 2)))"; sleep 0.5; sh_ "input keyevent KEYCODE_MENU"; sleep 1.5; chk popup
  kwin_q popup >/dev/null
  local p; p=$(grep -a '^PMW|' "$OUT/kwin-popup.txt" | awk -F'|' '$8=="true"' | head -1)
  if [ -z "$p" ]; then log "INFO no popup came up for the Menu key (nothing to measure)"
  else
    IFS=, read -r x y w h <<<"$(field "$p" 6)"
    local sw; sw=$(awk -v s="$SCALE" 'BEGIN{printf "%d", 2268 / s}')
    [ "$x" -ge 0 ] && [ "$y" -ge 0 ] && [ $((x + w)) -le $((sw + 1)) ] && pass "Kate's popup lies inside the screen ($x,$y ${w}x$h)" || fail "Kate's popup is cut by the screen edge ($x,$y ${w}x$h, screen $sw wide)"
    "$T/shot.sh" "$OUT/plasma-kate-popup.png" >/dev/null 2>&1; sh_ "input keyevent KEYCODE_ESCAPE"
  fi
}

kate_task() {  # Kate from home's launch call -> KT (its task)
  local before r; before=$(tasks)
  r=$(hcall apps.launch "['l:org.kde.kate']"); [ "$r" = ok ] || { fail "apps.launch Kate: $r"; return 1; }
  MINE="$MINE kate"; KT=""
  for _ in $(seq 30); do sleep 1; KT=$(comm -13 <(echo "$before") <(tasks) | tail -1); [ -n "$KT" ] && break; done; chk launch
  [ -n "$KT" ] || { fail "Kate from home: no window task in 30 s"; return 1; }
  [ "$(comm -13 <(echo "$before") <(tasks) | wc -l | tr -d ' ')" = 1 ] && pass "Kate from home is ONE window task ($KT)" || fail "Kate from home made more than one task: $(comm -13 <(echo "$before") <(tasks) | tr '\n' ' ')"
  sleep 3
}

mode_shell() {
  local l t r b c0 bars
  kate_task || return
  wait_win kate kate || { fail "no Kate window in KWin"; return; }
  [ "$(field "$W" 4)" = false ] && pass "Kate's KWin window is on the tasks desktop, not on Plasma's" || fail "Kate's KWin window is on Plasma's current desktop too: $W"
  bars=$(sh_ "dumpsys window windows" | grep -cE "Window #.*PowosWindowFrame|Window #.*powos.*frame" || true)
  log "PowOS frame windows: $bars (window tasks: $(tasks | wc -l | tr -d ' '))"
  [ "${bars:-0}" -le "$(tasks | wc -l | tr -d ' ')" ] && pass "one PowOS title bar at most per window task" || fail "more PowOS title bars ($bars) than window tasks"
  read -r l t r b <<<"$(sh_ "am stack list | grep -E \"taskId=${KT}[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ')"
  newdoc $(( (l + r) / 2 )) $(( (t + b) / 2 )); log "Kate's new document: '$c0'"; "$T/shot.sh" "$OUT/shell-kate.png" >/dev/null 2>&1
  typed $(( (l + r) / 2 )) $(( (t + b) / 2 )); chk type
  kwin_q typed >/dev/null; W=$(win typed kate)
  [ "$(field "$W" 2)" != "$c0" ] && pass "a tap + keys reached Kate's task (caption '$c0' -> '$(field "$W" 2)')" || fail "a tap + keys changed nothing in Kate's task ('$c0')"
}

mode_together() {
  local before after sf
  kate_task || return
  open_plasma || return
  kwin_q desk >/dev/null; W=$(win desk kate)
  [ "$(field "$W" 4)" = false ] && pass "in Plasma, Kate stays its task (not also on Plasma's desktop: no duplicate)" || fail "Kate shows on Plasma's desktop as well as in its task: ${W:-no kate window found by kwin_q desk (empty answer)}"
  sh_ "dumpsys SurfaceFlinger" > "$OUT/sf.txt"
  sf=$(awk '/Composition list \(bottom to top\)/{p=1} p&&/^  Layer \[/{print}' "$OUT/sf.txt" | head -4)
  log "bottom layers: $(tr '\n' '|' <<<"$sf")"
  sed -n '1p' <<<"$sf" | grep -q 'Wallpaper' && sed -n '2p' <<<"$sf" | grep -qE 'SurfaceView\[com\.powos\.app/andro\.marchy\.(MainActivity|HomeDesktop)' \
    && pass "the wallpaper is composed directly under the desktop's surface (nothing between that could show black)" \
    || fail "something sits between the wallpaper and the desktop's surface: $(sed -n '1,2p' <<<"$sf" | tr '\n' '|')"
  awk '/SurfaceView\[com\.powos\.app\/andro\.marchy\.(MainActivity|HomeDesktop)\]/{p=1} p&&/isOpaque=/{print; exit}' "$OUT/sf.txt" | grep -q 'isOpaque=false' \
    && pass "the desktop's surface is translucent (isOpaque=false)" || fail "the desktop's surface is opaque: Android draws black where Plasma is transparent"
  "$T/shot.sh" "$OUT/together-plasma.png" >/dev/null 2>&1
  before=$(tasks); in_session dolphin
  wait_win dolphin dolphin || { fail "no Dolphin window in KWin within 25 s"; return; }
  [ "$(field "$W" 4)" = true ] && [ "$before" = "$(tasks)" ] && pass "Dolphin started in Plasma is a KWin window on its desktop, no task" || fail "Dolphin started in Plasma: $W, tasks $(tasks | tr '\n' ' ')"
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 4; chk home2
  after=$(tasks); kwin_q home >/dev/null; W=$(win home dolphin)
  [ "$before" = "$after" ] && [ "$(field "$W" 4)" = true ] && pass "going home leaves Dolphin on Plasma's desktop (not pulled out into a floating task)" || fail "going home pulled Dolphin out of Plasma: $W, tasks $(echo "$after" | tr '\n' ' ')"
  "$T/shot.sh" "$OUT/together-home.png" >/dev/null 2>&1
}

mode_popup() {
  local l t r b x y w h cx cy cw ch p
  kate_task || return
  wait_win kate kate || { fail "no Kate window in KWin"; return; }
  read -r l t r b <<<"$(sh_ "am stack list | grep -E \"taskId=${KT}[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ')"
  [ -n "${b:-}" ] || { fail "no bounds for Kate's task $KT"; return; }
  sh_ "input tap $(( (l + r) / 2 )) $(( (t + b) / 2 ))"; sleep 1
  sh_ "input keyevent $(printf '66 %.0s' $(seq 60))"; sleep 1.5
  sh_ "input keyevent KEYCODE_MENU"; sleep 2; chk popup
  kwin_q popup >/dev/null
  IFS=, read -r cx cy cw ch <<<"$(grep -a '^PMC|kate|' "$OUT/kwin-popup.txt" | head -1 | cut -d'|' -f3)"
  p=$(grep -a '^PMW|' "$OUT/kwin-popup.txt" | awk -F'|' '$8=="true" && $9!="true"' | tail -1)
  "$T/shot.sh" "$OUT/popup-kate.png" >/dev/null 2>&1
  [ -n "${ch:-}" ] || { fail "no client area for Kate in KWin's answer"; sh_ "input keyevent KEYCODE_ESCAPE"; return; }
  [ -n "$p" ] || { fail "no popup came up for the Menu key in Kate's task (nothing to measure)"; return; }
  IFS=, read -r x y w h <<<"$(field "$p" 6)"
  log "Kate's client area $cx,$cy ${cw}x$ch; popup $x,$y ${w}x$h (KWin logical px)"
  [ "$x" -ge $((cx - 1)) ] && [ "$y" -ge $((cy - 1)) ] && [ $((x + w)) -le $((cx + cw + 1)) ] && [ $((y + h)) -le $((cy + ch + 1)) ] \
    && pass "Kate's context menu lies inside its task ($x,$y ${w}x$h in $cx,$cy ${cw}x$ch)" \
    || fail "Kate's context menu runs out of its task and is cut off ($x,$y ${w}x$h, task $cx,$cy ${cw}x$ch)"
  sh_ "input keyevent KEYCODE_ESCAPE"
}

"mode_$MODE"
chk end
[ $RC = 0 ] && pass "all ($OUT)"
exit $RC
