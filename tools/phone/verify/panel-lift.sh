#!/bin/bash
# lanes: emu phone
# panel-lift.sh [OUT]: home's panels above the floating windows (shell/PanelLift.kt, ui/panellift.ts; board task
# launcher-shade-and-system-panels-always-above-fl). Unfolds, swipes the lock face away, opens Calculator through
# home's own launch path (a floating window), then:
#   1. the drawer, opened by a swipe up on home beside the window (recorded): SurfaceFlinger's layer tree has home's
#      window relative to "PowOS panel anchor" (above the task area), logcat PowosPanelLift "home over the windows",
#      and the window's part of a screencap is blurred (its edge energy - ffmpeg edgedetect - well under the sharp one);
#      the recording's first frames as a sheet (OUT/open-sheet.png) for a flash of home's tiles over the window;
#   2. Back closes it: home under the windows again (no relative layer, "home under the windows again"), the window
#      sharp again and its title bar back;
#   3. the shade pulled down over the window: the "PowOS shade" window shows (a screencap of it over the window).
# Always restores: the drawer/shade closed (Back), Calculator stopped, home, `cmd device_state state reset`.
# Exit: 0 all passed; 1 a step failed (FAIL: ...); 3 a real touch / no free window / screen not awake; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/panel-lift-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=${TEST_APP:-com.oneplus.calculator}
FF=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { [ "${TOUCHED:-0}" = 1 ] || return 0; [ -n "$CLAIMED" ] && sh_ "input keyevent BACK; sleep 0.5"; release_pkgs; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock panel-lift.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
note() { echo "NOTE: $*" | tee -a "$OUT/log.txt"; }
hcall_once() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer after 4 tries (${v:-empty})"; }
# Read-only: whether home's drawer shows (.home.open) and whether home's pages are hidden over windows.
homeState() { "$T/cdp.sh" eval home "(()=>{const h=document.querySelector('.home');return h?(h.classList.contains('open')?'open':'shut')+(h.classList.contains('over-windows')?' over-windows':''):'no home'})()" 2>&1 | tr -d '"\r' | tail -1; }
wframe() { sh_ "dumpsys window windows" | awk -v p="$1" '/^ *Window #/{f=($0 ~ p)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' '; }
# The window's region of a picture: mean edge strength (0-255), ffmpeg edgedetect + signalstats.
edges() { "$FF" -loglevel error -i "$1" -vf "crop=$CW:$CH:$CX:$CY,edgedetect=low=0.1:high=0.3,signalstats,metadata=print:file=-" -f null - 2>/dev/null | sed -n 's/.*YAVG=//p' | head -1; }
# SurfaceFlinger's layer tree: home's window is relative to the anchor.
lifted() {
  sh_ "dumpsys SurfaceFlinger" | sed -n '/^Layer Hierarchy/,/^Offscreen/p' > "$OUT/sf-$1.txt"
  grep -iE "relative.*HomeShell|HomeShell.*relative" "$OUT/sf-$1.txt" | head -3 > "$OUT/sf-$1-rel.txt"
  if [ -s "$OUT/sf-$1-rel.txt" ]; then echo yes; return; fi
  # Without a "Relative" mark: home's window drawn under the anchor's node in the tree.
  awk '/PowOS panel anchor/{a=1} a&&/[0-9a-f]+ com.powos.app\/andro.marchy.HomeShell#/{print "under-anchor"; exit}' "$OUT/sf-$1.txt" | grep -q . && echo yes || echo no
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
claim_pkg $PKG
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }
[ "${W:-0}" -gt 2000 ] || { echo "ENV: display 0 is ${W:-?}x${H:-?}, not the inner screen - stopping before any input"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock" && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; logcat -c"; sleep 2; chk home
case $(homeState) in open*) sh_ "input keyevent BACK"; sleep 1 ;; esac
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key from home's apps.list: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 3; chk launch
read -r AL AT AR AB <<<"$(wframe "$PKG")"
[ -n "${AB:-}" ] || fail "no window of $PKG"
echo "window: $AL $AT $AR $AB (screen ${W}x${H})" | tee -a "$OUT/log.txt"
[ $((AR - AL)) -lt $((W * 9 / 10)) ] || fail "Calculator isn't a floating window ($AL..$AR of $W)"
# The window's middle, inset: its content, not its edges.
CX=$((AL + (AR - AL) / 8)); CY=$((AT + (AB - AT) / 8)); CW=$(((AR - AL) * 3 / 4)); CH=$(((AB - AT) * 3 / 4))
"$T/shot.sh" "$OUT/0-window.png" >/dev/null 2>&1 || fail "no screencap"
# The drawer paints its own icons over the window (sharp by themselves: the whole-window crop read 2.7 -> 7.5 with the
# window fully hidden, 20261024-181447-41425). So the drawer check measures a strip at the window's right, in the gutter
# between the icon grid and the A-Z index, where only the blurred backdrop shows. (A rise there = window unblurred.)
SX0=$((AR - (AR - AL) / 8)); SW=$(((AR - AL) / 20)); SY=$((AT + (AB - AT) / 5)); SH=$(((AB - AT) * 3 / 5))
estrip() { "$FF" -loglevel error -i "$1" -vf "crop=$SW:$SH:$SX0:$SY,edgedetect=low=0.1:high=0.3,signalstats,metadata=print:file=-" -f null - 2>/dev/null | sed -n 's/.*YAVG=//p' | head -1; }
S0=$(estrip "$OUT/0-window.png")
E0=$(edges "$OUT/0-window.png"); echo "window sharp: edge energy $E0" | tee -a "$OUT/log.txt"
[ "$(lifted before)" = no ] || fail "home is already over the windows before any panel"

# A spot of home beside the window for the swipes: the wider side.
if [ "$AL" -gt $((W - AR)) ]; then SX=$((AL / 2)); else SX=$(((AR + W) / 2)); fi
[ $((SX < AL || SX > AR)) = 1 ] || fail "no room beside the window for a swipe"

# 1. The drawer over the window, recorded from just before the swipe. The PowosPanelLift line is read from a time
# MARK taken right before the swipe (logcat -t), not the "-c" clear back at the home launch: the main buffer can roll
# over well inside that longer window on the emulator's noisier logcat (far more Choreographer/Skia lines under its
# software renderer), which lost the tagged line even though the SurfaceFlinger check right below it passed - a false
# FAIL on the emulator lane, 2026-10-24 (panel-lift task desktop-mode-stabilisation-move-resize-maximise).
MARK=$(sh_ "date +'%m-%d %H:%M:%S.000'")
sh_ "rm -f /data/local/tmp/pl-open.mp4; (screenrecord --time-limit 4 /data/local/tmp/pl-open.mp4 >/dev/null 2>&1 &)"; sleep 0.6
sh_ "input swipe $SX $((H * 80 / 100)) $SX $((H * 30 / 100)) 220"
sleep 3.6; chk drawer
st=$(homeState); echo "home: $st" | tee -a "$OUT/log.txt"
case $st in open*) ;; *) fail "the swipe up beside the window didn't open the drawer ($st)" ;; esac
"$T/shot.sh" "$OUT/1-drawer.png" >/dev/null 2>&1
E1=$(edges "$OUT/1-drawer.png"); S1=$(estrip "$OUT/1-drawer.png"); echo "under the drawer: whole-window edge energy $E1 (icons count, not used); gutter strip $S0 -> $S1" | tee -a "$OUT/log.txt"
sh_ "logcat -t '$MARK' -s PowosPanelLift:I PowosPanelLift:W" | tail -5 | tee -a "$OUT/log.txt" > "$OUT/lift-log.txt"
[ "$(lifted open)" = yes ] && pass "drawer open: home's window is stacked over the task area (SurfaceFlinger: $(head -c 160 "$OUT/sf-open-rel.txt" | tr '\n' ' '))" ||
  fail "drawer open but home's window isn't relative to the anchor (sf-open.txt; PanelLift: $(tail -1 "$OUT/lift-log.txt"))"
# The state above (home's surface relative to the anchor, from SurfaceFlinger) is the assertion; the log line is only
# a note: it is absent when the lift happened before MARK or rolled out of logcat (2026-10-24 20261024-155708-850 FAILed
# on the missing line while the z-order PASSed).
grep -q "home over the windows" "$OUT/lift-log.txt" && pass "PanelLift: $(grep "home over the windows" "$OUT/lift-log.txt" | tail -1 | sed 's/.*: //')" || note "no 'home over the windows' line in logcat since the swipe (the z-order above is the check)"
awk -v a="$S0" 'BEGIN{exit !(a > 1)}' || note "the window's gutter strip is flat even sharp ($S0): the blur check below proves little"
awk -v a="$S0" -v b="$S1" 'BEGIN{exit !(b < a * 0.6)}' && pass "the window under the drawer is blurred (gutter strip edge energy $S0 -> $S1)" ||
  fail "the window under the drawer isn't blurred (gutter strip edge energy $S0 -> $S1; 1-drawer.png)"
case $st in *over-windows*) pass "home's pages hidden over the window" ;; *) note "home's pages not marked over-windows ($st)" ;; esac
"$A" pull /data/local/tmp/pl-open.mp4 "$OUT/open.mp4" >/dev/null 2>&1 && {
  "$FF" -loglevel error -y -i "$OUT/open.mp4" -vf "select='between(t\,0.3\,1.3)',scale=180:-1,drawtext=text='%{n} %{pts\:flt}':x=2:y=2:fontsize=12:fontcolor=yellow:box=1:boxcolor=black,tile=10x4" -fps_mode passthrough -frames:v 1 "$OUT/open-sheet.png" 2>/dev/null
  "$FF" -loglevel error -i "$OUT/open.mp4" -vf "crop=$CW:$CH:$CX:$CY,edgedetect=low=0.1:high=0.3,signalstats,metadata=print:file=-" -f null - 2>/dev/null |
    awk '/pts_time/{t=$3} /YAVG/{sub(/.*YAVG=/,""); printf "%s %s\n", t, $0}' | sed 's/pts_time://' > "$OUT/open-edges.txt"
  note "opening, the window's edge energy per frame (t, YAVG): $(head -40 "$OUT/open-edges.txt" | awk '{printf "%.2f:%.1f ", $1, $2}')"
} || note "no recording of the opening"

# 2. Back closes it: home under the window again.
MARK=$(sh_ "date +'%m-%d %H:%M:%S.000'")
sh_ "input keyevent BACK"; sleep 2; chk back
st=$(homeState); echo "home: $st" | tee -a "$OUT/log.txt"
case $st in shut*) ;; *) fail "Back didn't close the drawer ($st)" ;; esac
[ "$(lifted shut)" = no ] && pass "drawer shut: home's window back in the task area" || fail "drawer shut but home is still over the windows (sf-shut.txt)"
"$T/shot.sh" "$OUT/2-shut.png" >/dev/null 2>&1
E2=$(edges "$OUT/2-shut.png"); echo "after close: edge energy $E2" | tee -a "$OUT/log.txt"
awk -v a="$E0" -v b="$E2" 'BEGIN{exit !(b > a * 0.8)}' && pass "the window is sharp again (edge energy $E2, was $E0)" || fail "the window isn't sharp after the drawer closed (edge energy $E2, was $E0; 2-shut.png)"
[ -n "$(wframe 'PowOS window bar')" ] && pass "its title bar is back" || fail "no title bar after the drawer closed"
sh_ "logcat -t '$MARK' -s PowosPanelLift:I" | grep -q "home under the windows again" && pass "PanelLift: home under the windows again" || note "no 'home under the windows again' line in logcat (the z-order above is the check)"

# 3. The shade over the window.
sh_ "input swipe $SX 4 $SX $((H * 60 / 100)) 260"; sleep 1.8; chk shade
"$T/shot.sh" "$OUT/3-shade.png" >/dev/null 2>&1
sv=$(sh_ "dumpsys window windows" | awk '/^ *Window #/{f=($0 ~ /PowOS shade/)} f && /isVisible|mViewVisibility|isOnScreen/' | head -3 | tr -s ' ' | tr '\n' ' ')
echo "shade window: $sv" | tee -a "$OUT/log.txt"
E3=$(edges "$OUT/3-shade.png"); echo "under the shade: edge energy $E3" | tee -a "$OUT/log.txt"
awk -v a="$E0" -v b="$E3" 'BEGIN{exit !(b < a * 0.6)}' && pass "the shade is over the window and blurs it (edge energy $E0 -> $E3)" || fail "the window isn't blurred under the shade (edge energy $E0 -> $E3; 3-shade.png)"
sh_ "input keyevent BACK"; sleep 1
echo "all passed; artefacts: $OUT"
