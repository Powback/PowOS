#!/bin/bash
# lanes: emu? phone (calc, video - android, run on either lane; kate, ffplay need the Linux session - phone only)
# tools/phone/verify/window-max.sh <calc|kate|video> [--round R] [--leash-off]: a floating window's maximise / restore and an app's
# OWN full screen on the unfolded home (WindowFrames.maximise, FreeformTasks; KWin patch for Linux windows), with a
# screen recording of each stage for review (~/.cache/powos-verify/window-max/<round>/<stage>.mp4).
#   calc:  Calculator from home: the bar's maximise -> the window fills the area under the status bar and above home's
#          bottom bar, its content at that size (SurfaceFlinger draws the app's layer over the task's whole bounds, its
#          buffer not scaled); restore -> EXACTLY the bounds before; a double tap on the bar does the same.
#   kate:  Kate (a Linux window): the same maximise / restore; then Kate's own full screen (Ctrl+Shift+F): the task covers
#          the whole screen (no PowOS bar, home and its dock not shown); Ctrl+Shift+F again: back floating at its bounds.
#   ffplay: a test video in ffplay as an X11 window (SDL through Xwayland and KWin, the way Proton games draw): `f`
#          makes it full screen by its own request - the task covers the screen, no bar, no dock; `f` again: back
#          floating at exactly its bounds.
#   video: a page in Chrome (window-max-video.html, served on the phone's 127.0.0.1) whose video asks for full screen on a
#          tap: the task covers the whole screen, no bar, no dock; Back leaves it: floating at its bounds again.
# Only what it opened is closed (e2e-lib: Calculator/Chrome tasks it started, Kate if it started it; a stage whose app
# was already running is skipped - the user's). Queue each stage: queue.sh add [--close] <task> <this> <stage>.
# --leash-off: the A/B run - `settings put global powos_live_leash 0` (TaskLeash off: resizeTask, the old way) for the
# journey, the value before ALWAYS put back on exit. After each restore the task's SurfaceFlinger layer state (its
# layers, their parents, visible/alpha/crop/position, offscreen ones) goes to $OUT/<app>-layers.txt, one line in the log.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
STAGE=${1:-calc}; shift || true
case $STAGE in calc|kate|video|ffplay) ;; *) echo "stage: calc | kate | video | ffplay"; exit 2 ;; esac
. "$here/e2e-lib.sh"
e2e_args "$@"
E2E_LINUX="dolphin kate gwenview ffplay"
e2e_init "max-$STAGE"
e2e_setup inner
REC=$HOME/.cache/powos-verify/window-max/$ROUND; mkdir -p "$REC"
DID=$(sh_ "dumpsys display" | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
LEASH0=; case " $* " in *" --leash-off "*) LEASH0=$(sh_ "settings get global powos_live_leash"); LEASH0=${LEASH0:-null}
  sh_ "settings put global powos_live_leash 0"; log "A/B: powos_live_leash 0 for this run (was $LEASH0)" ;; esac
leash_back() { [ -n "$LEASH0" ] || return 0; if [ "$LEASH0" = null ]; then sh_ "settings delete global powos_live_leash" >/dev/null; else sh_ "settings put global powos_live_leash $LEASH0"; fi
  log "A/B: powos_live_leash back to $LEASH0 ($(sh_ "settings get global powos_live_leash"))"; LEASH0=; }
trap 'sh_ "pkill -INT screenrecord" >/dev/null 2>&1; leash_back; e2e_abort' EXIT
TOL=${TOL:-3}

# --- measuring ---------------------------------------------------------------------------------------------------
# sfrow <layer name part>: "dl dt dr db cl ct cr cb" - where SurfaceFlinger composes the layer on the ON display (HWC
# Disp Frame) and the part of its buffer it shows (Source Crop): equal sizes = the app drew at the window's size.
# HWC frames are in the PANEL's own orientation: the inner screen's panel is landscape (2440x2268) under a portrait
# 2268x2440 display, so a screen rect (l t r b) shows as (t, W-r, b, W-l) there; turned back here (the crop stays as
# the buffer is: only its size counts, compared with the panel-space frame's). The size printed is the screen's way
# round, after the layer's Transform (a Linux window's SurfaceView is ROT_270: its 1360x1707 crop IS 1360 wide; read
# as pre-rotated it showed "1707x1360 for a 1360x1708 window", 2026-10-24).
sfrow() { sh_ "dumpsys SurfaceFlinger" | sfrow_of "$1"; }
# sfrow_of <layer name part>: the same from a SurfaceFlinger dump on stdin.
# Columns from the table's own header (OxygenOS has one more than AOSP's, e.g. the emulator: Disp Frame is the 6th
# field there, the 5th here); the phone's places when no header is seen.
HWCCOLS='BEGIN {dc = 6; cc = 7; tc = 5}
  on && /Disp Frame/ {n = split($0, h, "|"); for (i = 1; i <= n; i++) {if (h[i] ~ /Disp Frame/) dc = i; if (h[i] ~ /Source Crop/) cc = i; if (h[i] ~ /Transform/) tc = i}; next}'
sfrow_of() { awk -v p="$1" -v W="$W" -v H="$H" "$HWCCOLS"'
  /\(active\) HWC layers:/ {on=1; next} /HWC layers:/ {on=0}
  on && want {n=split($0, f, "|"); if (n >= cc) {
    split(f[dc], d, " "); split(f[cc], c, " "); cw = int(c[3] - c[1] + 0.5); ch = int(c[4] - c[2] + 0.5)
    # AOSP prints display coordinates as decimals (0.0); the pixel comparisons below use shell integer arithmetic.
    for (i = 1; i <= 4; i++) d[i] = sprintf("%.0f", d[i])
    # The crop is in the BUFFER: a buffer the app pre-rotated for the panel (Transform 0: HWUI apps, home) reads
    # turned against the screen, one SurfaceFlinger turns (ROT_90/270: the SurfaceView of a Linux window, its consumer
    # draws upright) reads as the screen does. Swapped only when exactly one of the two turns it.
    t = (f[tc] ~ /ROT_90|ROT_270/) ? 1 : 0; sw = (rot != t)
    if (rot) print W - d[4], d[1], W - d[2], d[3], (sw ? ch : cw), (sw ? cw : ch); else print d[1], d[2], d[3], d[4], (sw ? ch : cw), (sw ? cw : ch)
    exit } }
  on && !seen && /HomeShell/ {seen=1}
  on && index($0, p) {want=1}
  END {}' rot=$SFROT | xargs; }
# The panel turned: home's own full-screen layer is H wide there (raw HWC Disp Frame right edge).
SFROT=$(sh_ "dumpsys SurfaceFlinger" | awk -v W="$W" -v H="$H" "$HWCCOLS"'/\(active\) HWC layers:/ {on=1; next} /HWC layers:/ {on=0}
  on && want {n=split($0, f, "|"); if (n >= cc) {split(f[dc], d, " "); print (W != H && d[3] == H && d[4] == W) ? 1 : 0; exit}}
  on && /HomeShell/ {want=1}')
SFROT=${SFROT:-0}
log "HWC frames in the panel's orientation turned: $SFROT"
mode() { sh_ "dumpsys activity activities" | grep -E "^ *\* Task\{.* #$1 " | grep -oE "mode=[a-z-]+" | head -1 | cut -d= -f2; }
near() { local d=$(($1 - $2)); [ ${d#-} -le "$3" ]; }
# eqrect "a b c d" "e f g h" tol
eqrect() { set -- $1 $2 "$3"; [ $# -ge 9 ] && near "$1" "$5" "$9" && near "$2" "$6" "$9" && near "$3" "$7" "$9" && near "$4" "$8" "$9"; }
# The status bar's bottom (its window's frame) and home's bottom bar top (the page), device px.
SB=$(sh_ "dumpsys window windows" | awk '/^ *Window #/{f=(index($0," StatusBar}")>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' ' | awk '{print $4}')
BARTOP=$(ev 'Math.round(Math.min(...[...document.querySelectorAll(".home > .bar, .home > .dock, .home > .bottom-bar")].map(e=>e.getBoundingClientRect()).filter(r=>r.height>0).map(r=>r.top))*devicePixelRatio)' | tr -dc '0-9')
log "status bar to ${SB:-?} px, home's bottom bar at ${BARTOP:-?} px, display $DID"
# what <task> <layer>: one line of facts for the log (mode, task bounds, content row, bar frame).
# grab <task>: the task's mode and bounds, its bar's frame and SurfaceFlinger's HWC table in ONE phone call (each adb
# call over the VPN takes ~2.5 s: four per look made the diag rounds of 2026-10-23 run past the queue's 300 s), kept in
# $OUT/snap.txt for what and g_*; what <task> <layer>: one line of facts for the log from it.
grab() { ash <<EOF > "$OUT/snap.txt"
echo "@@B \$(am stack list | grep -E "taskId=$1:" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)"
echo "@@M \$(dumpsys activity activities | grep -E "^ *\* Task\{.* #$1 " | grep -oE 'mode=[a-z-]+' | head -1)"
echo "@@W \$(dumpsys window windows | awk '/^ *Window #/{f=(index(\$0,"PowOS window bar $1}")>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1)"
dumpsys SurfaceFlinger | sed -n '/(active) HWC layers:/,/HWC layers:/p' | head -300
EOF
}
g_bounds() { sed -n 's/^@@B //p' "$OUT/snap.txt" | tr -c '0-9\n' ' ' | xargs; }
g_mode() { sed -n 's/^@@M mode=//p' "$OUT/snap.txt"; }
g_bar() { sed -n 's/^@@W //p' "$OUT/snap.txt" | tr -c '0-9\n-' ' ' | xargs; }
g_sf() { grep -v '^@@' "$OUT/snap.txt" | sfrow_of "$1"; }
# content <task> <layer> <label>: the layer's row when the first look had none - the change transition still playing
# (on the emulator's software renderer its leash came 2.4 s late, and a RESTORE's first redraw at the shrunk size can
# take longer still, 2026-10-24 wc7: still empty at 4.5 s): a fresh dump every 1.5 s, six at most (9 s) on the
# emulator, three (4.5 s) on the phone; none at all keeps the dump ($OUT/<label>-nolayer.txt).
content() { local c= n=3; [ "${POWOS_DEVICE:-}" = emu ] && n=6
  for _ in $(seq 1 "$n"); do sleep 1.5; grab "$1"; c=$(g_sf "$2"); [ -n "$c" ] && break; done
  [ -n "$c" ] || cp "$OUT/snap.txt" "$OUT/$(printf %s "$3" | tr ' ' -)-nolayer.txt"; echo "$c"; }
what() { grab "$1"; echo "mode=$(g_mode) task=[$(g_bounds)] content=[$(g_sf "$2")] bar=[$(g_bar)]"; }
# dumps <name> <task>: the raw facts behind a state, for the record.
dumps() { ash <<EOF > "$OUT/$1.txt"
dumpsys activity activities | awk '/\* Task\{.* #$2 /{f=1} f&&/\* Task\{/&&!/#$2 /{f=0} f' | head -40
echo ---; dumpsys window | grep -E "statusBars|navigationBars|mTopIsFullscreen|mForceShowSystemBars|mFocusedApp" | head -24
echo ---; dumpsys window windows | grep -E "Window #|isVisible|mHasSurface" | grep -B1 -E "isVisible=true" | grep -E "Window #" | head -30
EOF
}

# layerstate <task> <package> <label>: SurfaceFlinger's state of the task's layers ($OUT/<label>-layers.txt): the
# hierarchy around Task=<id> (its parents and children, and any of its layers left in the Offscreen Hierarchy), each
# such layer's state block (visible/invisible reason, color alpha, bounds, toDisplayTransform, geomCrop) and every
# leash / snapshot / screenshot layer there is; one summary line in the log.
layerstate() { local f="$OUT/$3-layers.txt"
  sh_ "dumpsys SurfaceFlinger" > "$OUT/$3-sf.txt"
  awk -v id="$1" -v pk="$2" '
    function mine(l) { return index(l, "Task=" id "#") || index(l, " t" id "}") || index(l, " " id "#") || (pk != "" && index(l, pk)) || l ~ /[Ll]eash|[Ss]napshot|creenshot/ }
    /^Layer Hierarchy/ {tree=1; print "== hierarchy"; next} /^Offscreen Hierarchy/ {off=1; print "== offscreen"; next}
    tree && /^[^ │├└]/ && !/^ / {tree=0; off=0}
    tree { d = index($0, "─"); n++; L[n] = $0; D[n] = d
      if (index($0, "Task=" id "#")) { m = d; P = ""; for (k = n - 1; k > 0 && m > 4; k--) if (D[k] < m) { P = L[k] "\n" P; m = D[k] }; printf "%s", P; print $0; sub_ = d; next }
      if (sub_ && d > sub_) { print; next } sub_ = 0
      if (off && mine($0)) print; next }
    /^  Layer \[/ { blk = mine($0); if (blk) {print "== " $0; c = 0}; next }
    blk && c++ < 14 && /reason|color|bounds=|geomCrop|alpha|isOpaque/ { print }
  ' "$OUT/$3-sf.txt" > "$f"
  local t; t=$(awk -v k="Task=$1#" '/^== /{f=index($0, "] " k) > 0; if (f) n++; next} f && n == 1' "$f" | grep -oE "(in)?visible reason=[^|]*|tx=[-0-9.]+ ty=[-0-9.]+|geomCrop=\[[^]]*\]|alpha=[0-9.]+" | tr '\n' ' ')
  log "layers $3: task $1: ${t:-NO Task=$1 layer state}; parent: $(awk '/^== hierarchy/{h=1;next} /^== /{h=0} h' "$f" | grep -B1 -m1 "─ Task=$1#" | head -1 | sed -E 's/^[ │├└─]*//' | cut -c1-60); in the offscreen hierarchy: $(awk '/^== offscreen/{o=1;next} /^== /{o=0} o' "$f" | grep -c "$1"); leash/snapshot layers: $(grep -E '^== .*([Ll]eash|[Ss]napshot|creenshot)' "$f" | sort -u | wc -l | tr -d ' ') ($f)"; }

# --- recording ---------------------------------------------------------------------------------------------------
rec_start() { sh_ "rm -f /data/local/tmp/wmax-$1.mp4; (screenrecord --display-id $DID --bit-rate 16000000 --time-limit ${2:-60} /data/local/tmp/wmax-$1.mp4 </dev/null >/dev/null 2>&1 &)"; sleep 1; }
rec_stop() { sh_ "pkill -INT screenrecord"; sleep 2; "$A" exec-out "su -c 'cat /data/local/tmp/wmax-$1.mp4'" > "$REC/$1.mp4" 2>/dev/null; sh_ "rm -f /data/local/tmp/wmax-$1.mp4"
  log "recording: $REC/$1.mp4 ($(wc -c < "$REC/$1.mp4" | tr -d ' ') bytes)"; }
# The log around each bounds change: what WM, WM Shell, OnePlus's window code and PowOS did (wm.txt), PowOS's own
# lines (logcat.txt). Not a whole-logcat capture running through the journey (2.6 MB in 5 min, and every adb call
# slower with it: both diag rounds of 2026-10-23 ran out of the 300 s budget before saving it): `mark` takes the phone's
# time right before a change, `wmlog` appends the tagged lines since it (logcat -t: the buffer, at once) to a file ON the
# phone - the main buffer rolls over in ~30 s here, so right after each change - and logc_get pulls it once.
WMTAGS="PowosTaskLeash PowosWindowFrames PowosWindowFrame PowosFreeform PowosWindowResize PowosWindowDrag WindowTasks PowosWindowActivity PowosTasks WindowManager WindowManagerShell ShellTransitions OplusShellTransition OplusTransitionController TaskOrganizerController ActivityTaskManager Transition TransitionChain TransitionControllerExtImpl FlexibleTaskTransitionController FlexibleTaskTransitionHandler FlexibleWindowManagerService FlexibleTaskController ShellTaskOrganizerExt OplusCompatModeManagerService OplusViewDragTouchViewHelper ViewRootImplExtImpl PowosPet AndroidRuntime"
MARK=""
mark() { MARK=$(sh_ "date +%m-%d\ %H:%M:%S"); MARK="$MARK.000"; }
logc() { sh_ "rm -f /data/local/tmp/wmax-wm.txt /data/local/tmp/wmax.log"; mark; MARK0=$MARK; }
wmlog() { [ -n "$MARK" ] || return 0; ash <<EOF
echo "===== $1 (since $MARK)" >> /data/local/tmp/wmax-wm.txt
logcat -t "$MARK" -v time -s $WMTAGS >> /data/local/tmp/wmax-wm.txt 2>&1
EOF
}
logc_get() { wmlog "the journey's end (PowOS lines since the start that are still in the buffer)"
  sh_ "cat /data/local/tmp/wmax-wm.txt" > "$OUT/wm.txt"; sh_ "rm -f /data/local/tmp/wmax-wm.txt"
  grep -E "=====|PowosWindowFrames|PowosWindowFrame|PowosFreeform|PowosTaskLeash|PowosWindowResize|WindowTasks|PowosWindowActivity" "$OUT/wm.txt" > "$OUT/logcat.txt"
  us "tail -n 60 /run/powos-app/hyprland.log 2>/dev/null | grep -iE 'window task|full|resiz|size' | tail -30" > "$OUT/kwin.txt"; }
# ttap <x> <y> <what>: a tap as DOWN, which windows the finger went to (dumpsys input), UP - a tap all the same; the
# touched windows go in the log (diag 2026-10-23: a maximise tap reached com.powos.app but no button logged).
touched() { sh_ "dumpsys input" | sed -n '/TouchStatesByDisplay/,/CursorStatesByDisplay/p' | head -30 | grep -E "name=|Window|pilfer" | tr -s ' ' | tr '\n' ' ' | cut -c1-900; }
ttap() { mdown "$1" "$2" "$3" || return 1; log "tap $3 at $1,$2 (down, touch state, up)"; log "  touched: $(touched)"; mup "$1" "$2"; }
# trace <task> <label>: the task's bounds (am stack list) sampled for ~2 s right after a change, with phone times, so a
# change that lands and is then undone shows (window-max after 2026-10-23: WM listed the maximised bounds at +0.1 s,
# the old ones again at +0.35 s).
trace() { local t; t=$(sh_ "for i in \$(seq 18); do echo \$(date +%T.%N | cut -c1-12) \$(am stack list | grep -E \"taskId=$1:\" | grep -oE \"bounds=[^ ]+\" | head -1); done")
  printf '%s\n' "$t" | sed "s/^/  $2 /" | tee -a "$OUT/log.txt"; wmlog "$2"; }

# --- maximise / restore ------------------------------------------------------------------------------------------
maxbtn() { local b; b=$(wframe "PowOS window bar $1}"); [ -n "$b" ] || return 0; set -- $b; echo "$(($3 - $(dp 55))) $((($2 + $4) / 2))"; }
# maxcheck <task> <layer> <label>: maximise from the bar's button, then restore; then a double tap on the bar.
maxcheck() {
  local id=$1 lay=$2 app=$3 b0 b1 b2 c p r
  note "$app before: $(what "$id" "$lay")"; b0=$(g_bounds)
  p=$(maxbtn "$id"); [ -n "$p" ] || { fail "$app: no title bar to maximise from"; return; }
  set -- $p; mark; ttap "$1" "$2" "$app's maximise" || return
  trace "$id" "$app maximise"
  chk maximise
  step "$app-max" "$app maximised from its title bar"; dumps "$app-max" "$id"
  note "$app maximised: $(what "$id" "$lay")"; b1=$(g_bounds); c=$(g_sf "$lay")
  [ -n "$c" ] || { c=$(content "$id" "$lay" "$app maximised"); b1=$(g_bounds); }
  set -- $b1
  [ $# -ge 4 ] && [ "$1" -le "$TOL" ] && [ "$3" -ge $((W - TOL)) ] && [ "$2" -ge "${SB:-0}" ] && [ "$4" -le "${BARTOP:-$H}" ] && [ "$4" -ge $((${BARTOP:-$H} - $(dp 40))) ] &&
    pass "$app maximised fills the area: [$b1] (status bar to ${SB:-?}, home's bar at ${BARTOP:-?})" || fail "$app maximised to [$b1], want 0..$W wide, under ${SB:-?}, just above ${BARTOP:-?}"
  r=$(g_bar); set -- $r
  # Its glass (under the bar window's clear 8 dp touch strip, which the status bar sits over in z-order) under the status bar.
  [ $# -ge 4 ] && [ $(($2 + $(dp 8))) -ge "${SB:-0}" ] && pass "$app's title bar glass stays under the status bar ($r)" || fail "$app's title bar [$r] covers the status bar (to ${SB:-?})"
  set -- $c; if [ $# -ge 6 ]; then
    eqrect "$1 $2 $3 $4" "$b1" 4 && near $(($3 - $1)) "$5" 4 && near $(($4 - $2)) "$6" 4 &&
      pass "$app's content drawn at the maximised size ([$c])" || fail "$app's content [$c] isn't the maximised window [$b1] (stale or scaled)"
  else layerstate "$id" "$lay" "$app-maximised-missing"; fail "$app: no content layer ($c)"; fi
  p=$(maxbtn "$id"); set -- $p; mark; ttap "$1" "$2" "$app's restore" || return
  trace "$id" "$app restore"
  chk restore
  step "$app-restored" "$app restored from its title bar"
  note "$app restored: $(what "$id" "$lay")"; b2=$(g_bounds); c=$(g_sf "$lay")
  [ -n "$c" ] || { c=$(content "$id" "$lay" "$app restored"); b2=$(g_bounds); }
  [ "$b2" = "$b0" ] && pass "$app restored to exactly its bounds before ([$b2])" || fail "$app restored to [$b2], was [$b0]"
  layerstate "$id" "${lay%/}" "$app-restored"
  set -- $c; [ $# -ge 6 ] && eqrect "$1 $2 $3 $4" "$b2" 4 && near $(($3 - $1)) "$5" 4 && pass "$app's content back at its size ([$c])" || fail "$app's content [$c] after restore, window [$b2]"
  # A double tap on the bar (the desktop convention): maximised, again: back.
  p=$(barpt "$id"); [ -n "$p" ] || return; set -- $p
  log "double tap $app's bar at $1,$2"; offpill "$1" "$2" "bar" || return
  mark; sh_ "input tap $1 $2; input tap $1 $2"; trace "$id" "$app dtap"; chk dtap
  b1=$(tbounds "$id"); step "$app-dtap" "$app's bar double-tapped"
  set -- $b1; [ $# -ge 4 ] && [ "$3" -ge $((W - TOL)) ] && [ "$1" -le "$TOL" ] && pass "$app: a double tap on the bar maximises ([$b1])" || fail "$app: a double tap on the bar left it at [$b1]"
  p=$(barpt "$id"); set -- $p; mark; sh_ "input tap $1 $2; input tap $1 $2"; trace "$id" "$app dtap2"; chk dtap2
  b2=$(tbounds "$id"); [ "$b2" = "$b0" ] && pass "$app: a second double tap restores exactly ([$b2])" || fail "$app: after the second double tap [$b2], was [$b0]"
}

# --- an app's own full screen ------------------------------------------------------------------------------------
# fscheck <task> <layer> <label> <enter cmd> <leave cmd>: the app asks for full screen, then leaves it.
fscheck() {
  local id=$1 lay=$2 app=$3 b0 b1 b2 m r hv
  note "$app before full screen: $(what "$id" "$lay")"; b0=$(g_bounds)
  mark; eval "$4"; trace "$id" "$app full screen"; chk fullscreen
  step "$app-fullscreen" "$app asked for full screen"; dumps "$app-fullscreen" "$id"
  hv=$(tvis "$HOMET"); note "$app full screen: $(what "$id" "$lay") home visible=$hv"
  b1=$(g_bounds); m=$(g_mode); r=$(g_bar)
  set -- $b1; [ $# -ge 4 ] && [ "$1" -le 0 ] && [ "$2" -le 0 ] && [ "$3" -ge "$W" ] && [ "$4" -ge "$H" ] && pass "$app full screen covers the whole screen ([$b1], $m)" || fail "$app full screen: [$b1] mode $m, want 0 0 $W $H"
  [ -z "$r" ] && pass "$app full screen has no PowOS title bar" || fail "$app full screen still has a title bar [$r]"
  [ "$hv" = false ] && pass "home (and its dock) out of sight under $app" || fail "home visible=$hv under $app's full screen"
  set -- $(g_sf "$lay"); [ $# -ge 6 ] && [ $(($3 - $1)) -ge $((W - 4)) ] && [ $(($4 - $2)) -ge $((H - 4)) ] && pass "$app's content at full-screen size ($*)" || fail "$app's content [$*] isn't full screen"
  mark; eval "$5"; trace "$id" "$app leaves full screen"; chk leave
  step "$app-left-fullscreen" "$app left full screen"
  note "$app after full screen: $(what "$id" "$lay")"; b2=$(g_bounds); m=$(g_mode)
  [ "$m" = freeform ] && [ "$b2" = "$b0" ] && pass "$app floats again at exactly its bounds before ([$b2])" || fail "$app after full screen: [$b2] mode $m, was [$b0] freeform"
  [ -n "$(g_bar)" ] && pass "$app's title bar is back" || fail "$app has no title bar after full screen"
}

HOMET=$(tasks | awk '/HomeShell/{print $1; exit}')
logc
case $STAGE in
calc)
  CALC=${TEST_APP:-com.oneplus.calculator}
  grep -q " $CALC" <<<"$TASKS0" && { note "Calculator was already open (the user's): the stage skipped"; e2e_finish; exit 0; }
  rec_start calc 70
  r=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$CALC\\//.test(a.key))||{}).key||'none'"); hcall apps.launch "['$r']" "()=>'ok'" >/dev/null
  sleep 2.5; chk calc; CT=$(waitwin $CALC 6)
  step calc "Calculator in a window"
  if [ "$CT" != none ] && [ -n "$CT" ]; then maxcheck "$CT" "$CALC/" calc; else fail "no Calculator window"; fi
  rec_stop calc ;;
kate)
  grep -qx kate <<<"$LIN0" && { note "Kate was already running (the user's): the stage skipped"; e2e_finish; exit 0; }
  rec_start kate 110
  hcall apps.launch "['l:org.kde.kate']" "()=>'ok'" >/dev/null
  KT=$(waitwin l:org.kde.kate 15); chk kate
  step kate "Kate in a window"
  if [ "$KT" != none ] && [ -n "$KT" ]; then
    KL="SurfaceView[com.powos.app/andro.marchy.PowosWindowActivity"
    maxcheck "$KT" "$KL" kate
    set -- $(tbounds "$KT"); tap $((($1 + $3) / 2)) $((($2 + $4) / 2)) "Kate's text (its focus)"; sleep 0.6
    fscheck "$KT" "$KL" kate "sh_ 'input keycombination KEYCODE_CTRL_LEFT KEYCODE_SHIFT_LEFT KEYCODE_F'" "sh_ 'input keycombination KEYCODE_CTRL_LEFT KEYCODE_SHIFT_LEFT KEYCODE_F'"
  else fail "no Kate window"; fi
  rec_stop kate ;;
video)
  CH=com.android.chrome
  grep -q " $CH" <<<"$TASKS0" && { note "Chrome was already open (the user's): the stage skipped"; e2e_finish; exit 0; }
  "$A" push "$here/window-max-video.html" /data/local/tmp/wmax-fs.html >/dev/null 2>&1
  sh_ "mkdir -p /data/powos/root/tmp/wmax; cp /data/local/tmp/wmax-fs.html /data/powos/root/tmp/wmax/fs.html; chmod -R a+rX /data/powos/root/tmp/wmax"
  us "cd /tmp/wmax && setsid -f timeout 240 python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1; sleep 1; echo served"
  rec_start video 80
  r=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$CH\\//.test(a.key))||{}).key||'none'"); hcall apps.launch "['$r']" "()=>'ok'" >/dev/null
  VT=$(waitwin $CH 8); chk chrome
  sh_ "am start -a android.intent.action.VIEW -d http://127.0.0.1:8765/fs.html -p $CH >/dev/null"; sleep 3.5; chk page
  step video "the video page in Chrome's window"
  if [ "$VT" != none ] && [ -n "$VT" ]; then
    set -- $(tbounds "$VT"); CX=$((($1 + $3) / 2)); CY=$((($2 + $4) * 3 / 5))
    fscheck "$VT" "$CH/" video "tap $CX $CY 'the video (asks for full screen)'" "back 0.2"
    back 1.2
  else fail "no Chrome window"; fi
  us "pkill -f 'http.server 8765'; rm -rf /tmp/wmax; true" >/dev/null
  rec_stop video ;;
ffplay)
  [ -n "$(us 'pgrep -x ffplay' | tail -1)" ] && { note "ffplay was already running (the user's): the stage skipped"; e2e_finish; exit 0; }
  rec_start ffplay 90
  # In the Plasma session's own environment (plasmashell's), as an X11 client: Xwayland, like a Proton game.
  us "P=\$(pgrep -x plasmashell | head -1); while IFS= read -r -d '' kv; do export \"\$kv\"; done < /proc/\$P/environ; SDL_VIDEODRIVER=x11 setsid -f ffplay -loglevel error -window_title PowOS-check-video -x 960 -y 540 -f lavfi testsrc2=size=1280x720:rate=30 >/tmp/wmax-ffplay.log 2>&1 </dev/null; echo started" >/dev/null
  FT=none; for _ in $(seq 1 15); do FT=$(tasks | awk '/PowosWindowActivity/{print $1}' | while read -r t; do grep -q "^$t " <<<"$TASKS0" || echo "$t"; done | head -1); [ -n "$FT" ] && break; FT=none; sleep 1; done
  chk ffplay; step ffplay "ffplay's video in a window"
  if [ "$FT" != none ]; then
    sleep 1.5; set -- $(tbounds "$FT"); tap $((($1 + $3) / 2)) $((($2 + $4) / 2)) "the video (its focus)"; sleep 0.6
    fscheck "$FT" "SurfaceView[com.powos.app/andro.marchy.PowosWindowActivity" ffplay "sh_ 'input keyevent KEYCODE_F'" "sh_ 'input keyevent KEYCODE_F'"
  else fail "no ffplay window task ($(us 'cat /tmp/wmax-ffplay.log' | tail -2))"; fi
  us "pkill -x ffplay; true" >/dev/null
  rec_stop ffplay ;;
esac
leash_back
logc_get
grep -E "maximis|full screen|now a window|PowosFreeform" "$OUT/logcat.txt" | tail -12 | tee -a "$OUT/log.txt"
log "facts: $OUT (dumps, logcat.txt, kwin.txt); recordings: $REC"
e2e_finish
