#!/bin/bash
# float-windows.sh [OUT]: floating app windows on the unfolded home (board task powos-home-as-the-desktop-...), for a
# phone left unattended. Folded, apps open full screen by design, so the check needs the INNER screen: it forces it
# (cmd device_state state 3, as unfolded-checks.sh does), dismisses the keyguard / swipes the lock face (no PIN), home,
# then opens Calculator THROUGH HOME's own launch path - the bridge call a tap makes (state.ts launch ->
# powos.apps.launch -> PowosHost.postMessage [id, "apps.launch", [key]]; `powos` is a module, not a page global) - and
# it must be a freeform task, ~60% x 70% of the screen above home's bottom bar, its app laid out at the windows' density
# (text about its full-screen size: the task's dpi 70-95% of the screen's, >= 600 dp wide; the screencap goes onto the
# board task); then PowOS's frame (WindowFrame.kt): bar there, drag moves, grip resizes, maximise fills the area above
# the bottom bar and again puts it back, minimise hides it, its app's launch brings it back, the dock's icon tap
# minimises the window in front and brings it back, close closes; a full-screen task opened from recents (tasks.open)
# comes back floating; a Linux app (qdbusviewer) opens as a floating task named by its app key in windows.list, a window
# another app opens (kwrite started inside PowOS: KWin's export-new) floats too, their bars' close closes them.
# Always restores: Calculator stopped, home,
# `cmd device_state state reset` (the hinge decides again).
# Exit: 0 all passed; 1 a step failed (FAIL: ...); 3 a real touch / no free window / screen not awake (re-queued);
# 5 can't run (no screen size, keyguard with a PIN). Injected input only. A free window first, the lock only then (5a).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/float-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=com.oneplus.calculator
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am force-stop $PKG; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock float-windows.sh 120
# Our own trap (window_lock sets none under the queue's LOCK_HELD=1): restore always, the lock only if it's ours.
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
# A call on home's bridge, exactly as the page makes it (bridge.ts native()): its answer through __powosHost.resolve
# under our own id, the page's own pending calls untouched. $1 method, $2 JSON args array, $3 a JS function of the answer.
hcall_once() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910200+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# hcall with retries: an EMPTY answer is a failed adb/CDP hop before the call reached the page (cdp.sh's adb under
# set -e once exited silently: "Calculator's key from home's apps.list: ", 2026-10-23) - the call never ran, so it's
# made again (up to 4 tries, 2 s apart). An answer from the page (ok, ERR ...) is final.
hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) echo "hcall $2: try $i: '${v}'" >&2; sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer after 4 tries (${v:-empty})"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || fail "enable_freeform_support isn't 1 (OxygenOS coerces freeform to full screen)"
sh_ "cmd device_state state 3"; sleep 3; chk unfold
sh_ "dumpsys device_state | grep -m1 mCommittedState" | tee -a "$OUT/log.txt" | grep -q OPENED || fail "the inner screen didn't come on (device_state not OPENED)"
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
[ "${W:-0}" -gt 0 ] && [ "${H:-0}" -gt 0 ] || { echo "no screen size (wm size) - stopping before any input"; exit 5; }
[ "$W" -gt 2000 ] || fail "display 0 is ${W}x${H}, not the unfolded inner screen"
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5
fi
chk lock
sh_ "am force-stop $PKG; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -q "com.powos.app" || fail "home isn't in front after the home intent"
"$T/shot.sh" "$OUT/home.png"

key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
echo "launch $key" | tee -a "$OUT/log.txt"
case $key in a:$PKG/*) ;; *) fail "Calculator's key from home's apps.list: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 2.5; chk launch
sh_ "dumpsys activity activities | grep -m1 -E \"Task\\{.*$PKG\" | grep -oE \"mode=[a-z-]+\"" | tee "$OUT/mode.txt"
sh_ "am stack list | grep -m1 $PKG | grep -oE \"bounds=\\[[^ ]*\"" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/floating.png"
grep -q 'mode=freeform' "$OUT/mode.txt" && pass "a floating window" || fail "not freeform ($(head -1 "$OUT/mode.txt"))"

# Its content at the windows' density (FreeformTasks.density, AppWindows.windowDpi): the task's own dpi, a real
# relayout (not a scaled bitmap), so its text is about the size the app's is full screen, and the window is a wide layout.
FD=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1)
# The task's own configuration (= TaskInfo.configuration, what WindowFrames.dense reads back): `am stack list` prints
# each root task's "configuration={... wNNNdp ... NNNdpi ...}" above its "taskId=N: <pkg>/..." line; a freeform task is
# a root task of its own. Not the activity's CurrentConfiguration in dumpsys activity activities (came back empty on
# APK ccab7f0). dense re-applies the density every 500 ms until it shows (up to 4 s): poll up to 5 s for it to settle.
tcfg() { sh_ "am stack list" | awk -v p="$PKG" '/^ *configuration=/{c=$0} $0 ~ "taskId=[0-9]+: "p"/"{print c; exit}'; }
TD=; TW=; WANT=$((FD * 95 / 100))
for _ in 1 2 3 4 5 6 7 8 9 10; do
  cfg=$(tcfg); printf '%s\n' "$cfg" > "$OUT/task-config.txt"
  TD=$(printf %s "$cfg" | grep -oE '[ {][0-9]+dpi' | head -1 | tr -dc 0-9); TW=$(printf %s "$cfg" | grep -oE ' w[0-9]+dp' | head -1 | tr -dc 0-9)
  [ -n "$TD" ] && [ "$TD" -le "$WANT" ] && break
  sleep 0.5
done
sh_ "logcat -d -s PowosWindowFrames:I | tail -20" > "$OUT/frames-log.txt"
# For the record: the old read (the first CurrentConfiguration after the task's line in dumpsys activity activities).
sh_ "dumpsys activity activities" | awk "/Task\\{.*$PKG/{f=1} f" | head -60 > "$OUT/task-activities.txt"
grep -E 'dpi: set' "$OUT/frames-log.txt" | tail -3 | tee -a "$OUT/mode.txt"
echo "window: ${TD}dpi ${TW}dp wide; full screen ${FD}dpi" | tee -a "$OUT/mode.txt"
[ -n "$TD" ] && [ $((TD * 100)) -ge $((FD * 70)) ] && [ $((TD * 100)) -le $((FD * 95)) ] && pass "text at about its full-screen size (${TD} of ${FD} dpi)" ||
  fail "the window's content isn't at the windows' density: ${TD:-?}dpi against the screen's $FD (want 70-95%; task-config.txt, frames-log.txt)"
[ "${TW:-0}" -ge 600 ] && pass "a wide layout (${TW} dp)" || fail "the window is ${TW:-?} dp wide: the app's phone layout, blown up"
# Its default size and place: ~60% x 70% of the screen, never over home's bottom bar (read from the page, not assumed).
BAR=$("$T/cdp.sh" eval home 'Math.round(Math.min(...[...document.querySelectorAll(".home > .bar, .home > .dock, .home > .bottom-bar")].map(e=>e.getBoundingClientRect()).filter(r=>r.height>0).map(r=>r.top))*devicePixelRatio)' 2>&1 | tr -dc '0-9\n' | tail -1)
read -r L0 T0 R0 B0 <<<"$(sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ')"
echo "opened at $L0 $T0 $R0 $B0; bottom bar from y=$BAR" | tee -a "$OUT/mode.txt"
[ $(((R0 - L0) * 100 / W)) -ge 55 ] && [ $(((R0 - L0) * 100 / W)) -le 62 ] && pass "opens $(((R0 - L0) * 100 / W))% wide" || fail "opens $(((R0 - L0) * 100 / W))% of the screen wide, not ~60%"
[ $(((B0 - T0) * 100 / H)) -ge 50 ] && [ $(((B0 - T0) * 100 / H)) -le 71 ] && pass "opens $(((B0 - T0) * 100 / H))% high" || fail "opens $(((B0 - T0) * 100 / H))% of the screen high, not up to 70%"
[ -n "$BAR" ] && [ "$B0" -le "$BAR" ] && pass "above the bottom bar" || fail "its bottom $B0 is over home's bottom bar (y=${BAR:-?})"
[ -f "$OUT/floating.png" ] && "$T/review-image.sh" "$OUT/floating.png" >/dev/null 2>&1 && cp "$OUT/floating.png" "$OUT/float-density.png" &&
  "$T/review-image.sh" "$OUT/float-density.png" >/dev/null 2>&1 &&
  python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "${BOARD_TASK:-powos-home-as-the-desktop-linux-android-apps-as}" --image /home/powos/design-qa/float-density.png >/dev/null 2>&1 &&
  echo "screencap on the board task" | tee -a "$OUT/log.txt"

# PowOS's frame on it (system/WindowFrame.kt): the bar window is 26 dp above the task's top; close is its last button
# (30 dp, 6 dp from the end), minimise the one before it (4 dp gap); the grip disc sits on the lower-right corner.
bounds() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }
bars=$(sh_ "dumpsys window windows | grep -c \"PowOS window bar\""); echo "frame bars: $bars" | tee -a "$OUT/mode.txt"
[ "${bars:-0}" -ge 1 ] && pass "a title bar" || fail "no title bar"
# ONE title bar: SystemUI's own caption (WM Shell CaptionWindowDecoration: back/min/max/close inside the task) is off
# through the overlay system/OemCaption.kt registers - enabled, and no caption bar inset with any height on the screen.
sh_ "cmd overlay list com.android.systemui" | grep -q '^\[x\] com.android.shell:PowosNoCaption' &&
  pass "the system's caption overlay is on" || fail "the system's caption overlay (com.android.shell:PowosNoCaption) isn't enabled"
caps=$(sh_ "dumpsys window" | grep -oE 'type=captionBar frame=\[[0-9-]+,[0-9-]+\]\[[0-9-]+,[0-9-]+\]' | sort -u)
echo "caption insets: ${caps:-none}" | tee -a "$OUT/mode.txt"
tall=$(echo "$caps" | tr -c '0-9\n-' ' ' | awk 'NF>=4 && $4-$2>0' | wc -l | tr -d ' ')
[ "${tall:-0}" = 0 ] && pass "one title bar: no system caption" || fail "the system's caption still has height: $caps"
read -r XL XT XR XB <<<"$(bounds)"; echo "before: $XL $XT $XR $XB"
[ -n "${XB:-}" ] || fail "no bounds for the task"
BY=$((XT - $(px 20))); sh_ "input swipe $((XL + (XR - XL) / 3)) $BY $((XL + (XR - XL) / 3 + 240)) $((BY + 180)) 700"; sleep 1.5; chk drag
read -r XL2 XT2 XR2 XB2 <<<"$(bounds)"; echo "after drag: $XL2 $XT2 $XR2 $XB2" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/framed.png" && cp "$OUT/framed.png" "$OUT/float-framed.png" && "$T/review-image.sh" "$OUT/float-framed.png" >/dev/null 2>&1 &&
  python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "${BOARD_TASK:-powos-home-as-the-desktop-linux-android-apps-as}" --image /home/powos/design-qa/float-framed.png >/dev/null 2>&1
[ "$XL2" != "$XL" ] && [ "$XT2" != "$XT" ] && pass "the bar moves it" || fail "the drag didn't move it"
sh_ "input swipe $((XR2 - $(px 6))) $((XB2 - $(px 6))) $((XR2 + $(px 92))) $((XB2 + $(px 72))) 700"; sleep 1.5; chk grip
read -r XL3 XT3 XR3 XB3 <<<"$(bounds)"; echo "after resize: $XL3 $XT3 $XR3 $XB3" | tee -a "$OUT/mode.txt"
[ $((XR3 - XL3)) -gt $((XR2 - XL2)) ] && pass "the grip resizes it" || fail "the grip didn't resize it"
# Maximise (the button before close: close 6 dp from the end, 30 dp buttons, 4 dp gaps): the whole width, above the
# bottom bar; again: back where it was.
sh_ "input tap $((XR3 - $(px 55))) $((XT3 - $(px 20)))"; sleep 1.5; chk maximise
read -r ML MT MR MB <<<"$(bounds)"; echo "maximised: $ML $MT $MR $MB" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/maximised.png"
[ $((MR - ML)) -ge $((W * 98 / 100)) ] && [ -n "$BAR" ] && [ "$MB" -le "$BAR" ] && [ "$MB" -ge $((BAR - $(px 40))) ] && pass "maximise fills the area above the bottom bar" ||
  fail "maximised to $ML $MT $MR $MB (screen ${W} wide, bottom bar at ${BAR:-?})"
sh_ "input tap $((MR - $(px 55))) $((MT - $(px 20)))"; sleep 1.5; chk unmaximise
read -r XL3 XT3 XR3 XB3 <<<"$(bounds)"; echo "restored: $XL3 $XT3 $XR3 $XB3" | tee -a "$OUT/mode.txt"
[ $((XR3 - XL3)) -lt $((MR - ML)) ] && pass "maximise again puts it back" || fail "still maximised after the second tap"
# Minimise: off screen and minimised in home's window list; the app's launch (a dock tap) brings it back.
vis() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'visible=(true|false)'; }
sh_ "input tap $((XR3 - $(px 89))) $((XT3 - $(px 20)))"; sleep 1.5; chk minimise
m=$(hcall windows.list "[]" "l=>l.filter(w=>w.pkg==='$PKG'&&w.minimised).length")
echo "minimised: $(vis) windows.list minimised=$m" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/minimised.png"
[ "$m" = 1 ] && [ "$(vis)" = visible=false ] && pass "minimise" || fail "minimise (list: $m, $(vis))"
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch (restore): $r"
sleep 1.5; chk restore
[ "$(vis)" = visible=true ] && pass "the dock brings it back" || fail "not back after its app's launch"
# The dock's icon, taskbar style (ui/desktops.ts dockTap): a real tap on it while its window is in front minimises it,
# the next brings it back.
dockxy() { "$T/cdp.sh" eval home "(()=>{const e=document.querySelector('.dock .app[data-key=\"$key\"]');if(!e)return 'none';const r=e.getBoundingClientRect();return Math.round((r.left+r.width/2)*devicePixelRatio)+' '+Math.round((r.top+r.height/2)*devicePixelRatio)})()" 2>&1 | tr -d '"\r' | tail -1; }
xy=$(dockxy); echo "dock icon at $xy" | tee -a "$OUT/mode.txt"
case $xy in *[0-9]\ [0-9]*) ;; *) fail "no dock icon for $key ($xy)" ;; esac
sh_ "input tap $xy"; sleep 1.5; chk docktap
[ "$(vis)" = visible=false ] && pass "a dock tap minimises the window in front" || fail "a dock tap on its icon didn't minimise it ($(vis))"
xy=$(dockxy); sh_ "input tap $xy"; sleep 1.5; chk docktap2
[ "$(vis)" = visible=true ] && pass "a dock tap brings it back" || fail "a dock tap didn't bring it back ($(vis))"
read -r XL3 XT3 XR3 XB3 <<<"$(bounds)"
sh_ "input tap $((XR3 - $(px 6) - $(px 15))) $((XT3 - $(px 20)))"; sleep 1.5; chk close
sh_ "am stack list | grep -c $PKG" | grep -qx 0 && pass "close closes it" || fail "still open after close"
# Recents: a task that is full screen (started so here on purpose) opened from the switcher (tasks.open) floats.
sh_ "am start -W --windowingMode 1 -n ${key#a:} >/dev/null"; sleep 2
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk recents-setup
TID=$(sh_ "am stack list | grep -m1 $PKG" | grep -oE 'taskId=[0-9]+' | head -1 | tr -dc 0-9)
r=$(hcall tasks.open "[$TID, null]" "v=>String(v)"); sleep 2; chk recents
sh_ "dumpsys activity activities | grep -m1 -E \"Task\\{.*$PKG\" | grep -oE \"mode=[a-z-]+\"" | tee -a "$OUT/mode.txt" | grep -q mode=freeform &&
  pass "a full-screen task opened from recents floats" || fail "tasks.open ($r) left task $TID full screen"

# A Linux app (KDE's D-Bus viewer: small, not one the user keeps open) opens as its own task (PowosWindowActivity,
# WindowTasks) - floating too, with the frame, a dock entry by its app key and its bar's close closing it.
LKEY=l:qdbusviewer
lin() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
before=$(lin)
r=$(hcall apps.launch "['$LKEY']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch $LKEY: $r"
LT=""; for i in $(seq 1 20); do sleep 1; LT=$(comm -13 <(echo "$before") <(lin) | tail -1); [ -n "$LT" ] && break; done; chk linux
[ -n "$LT" ] || fail "no task for $LKEY within 20 s (PowosWindowActivity)"
sleep 1.5
lmode=$(sh_ "dumpsys activity activities" | grep -m1 -E "Task\{[^ ]* #$LT " | grep -oE "mode=[a-z-]+")
"$T/shot.sh" "$OUT/linux.png"
[ "$lmode" = mode=freeform ] && pass "a Linux app opens as a floating window ($LKEY, task $LT)" || fail "$LKEY's task $LT is $lmode, not freeform"
lw=$(hcall windows.list "[]" "l=>(l.find(w=>w.id===$LT)||{app:'none'}).app")
[ "$lw" = "$LKEY" ] && pass "windows.list names its app ($lw): dock entry, dot, pages" || fail "windows.list has task $LT as app '$lw', not $LKEY"
lb() { sh_ "am stack list | grep -E \"taskId=$LT:\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
read -r LL LTOP LR LB <<<"$(lb)"
# Opened from another app (as Dolphin opens an image in Gwenview): KDE's editor started inside PowOS, not from home -
# KWin's export-new (kwin 0018) gives it a floating task too. An older KWin still running: said, not failed.
printf '%s\n' 'nohup kwrite /tmp/powos-float-check.txt >/dev/null 2>&1 &' > "$OUT/kwrite.sh"
before=$(lin); "$T/user.sh" "$OUT/kwrite.sh" >/dev/null 2>&1
KT=""; for i in $(seq 1 15); do sleep 1; KT=$(comm -13 <(echo "$before") <(lin) | tail -1); [ -n "$KT" ] && break; done; chk child
if [ -n "$KT" ]; then
  kmode=$(sh_ "dumpsys activity activities" | grep -m1 -E "Task\{[^ ]* #$KT " | grep -oE "mode=[a-z-]+")
  "$T/shot.sh" "$OUT/linux-child.png"
  [ "$kmode" = mode=freeform ] && pass "a window another app opened floats too (task $KT)" || fail "the window another app opened is $kmode"
  read -r KL KTOP KR KB <<<"$(sh_ "am stack list | grep -E \"taskId=$KT:\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ')"
  sh_ "input tap $((KR - $(px 19))) $((KTOP - $(px 13)))"; sleep 2; chk kclose
  sh_ "am stack list | grep -cE \"taskId=$KT:\"" | grep -qx 0 && pass "its bar's close closes it" || fail "task $KT still open after its close"
else
  echo "SKIP: no task for a window another app opened in 15 s - KWin without export-new (0018) still running?" | tee -a "$OUT/log.txt"
  printf '%s\n' 'pkill -f "kwrite /tmp/powos-float-check.txt"' > "$OUT/kwrite.sh"; "$T/user.sh" "$OUT/kwrite.sh" >/dev/null 2>&1
fi
# Its bar's close (19 dp from the right end, 13 dp above the window: the 26 dp bar's middle).
sh_ "input tap $((LR - $(px 19))) $((LTOP - $(px 13)))"; sleep 2; chk lclose
sh_ "am stack list | grep -cE \"taskId=$LT:\"" | grep -qx 0 && pass "its bar's close closes the Linux window's task" || fail "task $LT still open after its close"
echo "all passed; artefacts: $OUT"
