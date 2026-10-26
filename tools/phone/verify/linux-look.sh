#!/bin/bash
# lanes: phone
# linux-look.sh [OUT]: Linux apps on the phone are the size of Android apps and dark like PowOS (board: e2e round 3,
# "Linux apps render TINY" + "Linux apps use the LIGHT Breeze theme"). Runs on the Mac, queued:
#   queue.sh add [--close] <task> tools/phone/verify/linux-look.sh
#   1. Size (read-only): Android's px per dp in a window (0.8 x `wm density` / 160, AppWindows.windowDpi) against
#      KWin's output scale (Wayland apps), Xwayland's Xft.dpi/96 and Qt's X11 dpr (X11 apps) and GTK's X11 scale x
#      xft dpi (GTK under Xwayland): each within 15%. Prints the menu text size both ways (Qt's 10 pt font vs 14 sp).
#   2. Colours (read-only): Qt and GTK started in the environment the PowOS drawer starts apps in (powos-run.sh's,
#      WAYLAND_DISPLAY as RootedGuest adds it) - Breeze, not Fusion, and a dark window colour (luminance < 0.3), Qt's
#      the session's colour scheme's Window colour.
#   3. Kate from home's launch path (apps.launch l:org.kde.kate, as a tap): its process has the KDE environment and
#      its window on a screencap is dark (mean grey < 90/255; the light one was ~235). Screencap -> OUT/kate.png
#      (+ the review image on the board). Kate closed after if this started it; home back; `device_state` reset.
#   FACTS_ONLY=1: parts 1-2 only (read-only, no window needed - fine outside the queue).
# Exit: 0 passed (a ^FAIL line = FAIL); 1 FAIL; 3 a real touch / no window / screen not on (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/linux-look-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
FAILS=0
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
kv() { sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p" <<<"$2" | head -1; }
# within A B: A within 15% of B
within() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(b > 0 && a / b > 0.85 && a / b < 1.15) }'; }
lum() { python3 -c "import sys; h=sys.argv[1].lstrip('#'); r,g,b=(int(h[i:i+2],16)/255 for i in (0,2,4)); print('%.2f' % (0.2126*r+0.7152*g+0.0722*b))" "$1" 2>/dev/null || echo 1; }

# The probe, in PowOS's /tmp (readable by the session user).
"$A" push "$here/linux-look-probe.py" /data/local/tmp/linux-look-probe.py >/dev/null 2>&1
sh_ "cp /data/local/tmp/linux-look-probe.py /data/powos/root/tmp/linux-look-probe.py && chmod 644 /data/powos/root/tmp/linux-look-probe.py && rm /data/local/tmp/linux-look-probe.py"

# 1 + 2: read-only facts of the session and the drawer's environment.
dens=$(sh_ "wm density" | sed -nE 's/.*(Override|Physical) density: ([0-9]+).*/\2/p' | tail -1)
TGT=$(awk -v d="${dens:-0}" 'BEGIN { printf "%.3f", 0.8 * d / 160 }')
F=$(us 'export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}; cd /tmp
echo "scale=$(kscreen-doctor -j 2>/dev/null | jq -r ".outputs[0].scale")"
echo "xwl=$(sed -n "/^\[Xwayland\]/,/^\[/s/^Scale=//p" ~/.config/kwinrc | head -1)"
echo "xft=$(xrdb -query 2>/dev/null | sed -n "s/^Xft.dpi:\s*//p")"
echo "scheme=$(kreadconfig6 --group General --key ColorScheme 2>/dev/null) schemebg=$(kreadconfig6 --group Colors:Window --key BackgroundNormal 2>/dev/null)"
echo "qtwl: $(timeout 15 python3 /tmp/linux-look-probe.py qt 2>/dev/null | tail -1)"
echo "qtx11: $(QT_QPA_PLATFORM=xcb timeout 15 python3 /tmp/linux-look-probe.py qt 2>/dev/null | tail -1)"
echo "gtkwl: $(timeout 15 python3 /tmp/linux-look-probe.py gtk 2>/dev/null | tail -1)"
echo "gtkx11: $(GDK_BACKEND=x11 timeout 15 python3 /tmp/linux-look-probe.py gtk 2>/dev/null | tail -1)"
echo "env: XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP KDE_FULL_SESSION=$KDE_FULL_SESSION"')
printf '%s\n' "$F" > "$OUT/facts.txt"; log "android density ${dens:-?} -> ${TGT} px/dp in a window"; log "$F"
line() { grep -m1 "^$1" <<<"$F"; }
SC=$(kv scale "$(line scale=)"); XFT=$(line xft= | cut -d= -f2); QW=$(line qtwl:); QX=$(line qtx11:); GW=$(line gtkwl:); GX=$(line gtkx11:)
[ "${dens:-0}" -gt 0 ] || { echo "ENV: no Android density (wm density)"; exit 5; }

# Size.
within "${SC:-0}" "$TGT" && pass "KWin output scale ${SC} matches Android's window ${TGT} px/dp (Wayland apps)" ||
  fail "KWin output scale ${SC:-?}, Android's window is ${TGT} px/dp: Linux apps the wrong size"
xs=$(awk -v x="${XFT:-0}" 'BEGIN { printf "%.3f", x / 96 }')
within "$xs" "$TGT" && pass "Xwayland Xft.dpi ${XFT} = ${xs}x (X11 apps)" || fail "Xwayland Xft.dpi ${XFT:-?} = ${xs}x, want ~${TGT}x"
qx=$(awk -v d="$(kv dpr "$QX")" -v l="$(kv ldpi "$QX")" 'BEGIN { printf "%.3f", d * l / 96 }')
within "$qx" "$TGT" && pass "Qt X11 app: ${qx}x (dpr $(kv dpr "$QX"), $(kv ldpi "$QX") dpi)" || fail "Qt X11 app at ${qx}x, want ~${TGT}x ($QX)"
gx=$(awk -v s="$(kv scale "$GX")" -v x="$(kv xftdpi "$GX")" 'BEGIN { printf "%.3f", s * x / 96 }')
within "$gx" "$TGT" && pass "GTK X11 app: ${gx}x (scale $(kv scale "$GX"), $(kv xftdpi "$GX") dpi)" || fail "GTK X11 app at ${gx}x, want ~${TGT}x ($GX)"
log "menu text: Qt $(kv pt "$QW") pt at ${SC}x = $(awk -v p="$(kv pt "$QW")" -v s="${SC:-1}" 'BEGIN { printf "%.0f", p * 96 / 72 * s }') px; Android 14 sp in a window = $(awk -v t="$TGT" 'BEGIN { printf "%.0f", 14 * t }') px"

# Colours, in the drawer's environment.
qbg=$(kv bg "$QW"); qst=$(kv style "$QW"); ql=$(lum "${qbg:-#ffffff}")
sbg=$(line scheme= | sed -nE 's/.*schemebg=([0-9]+),([0-9]+),([0-9]+).*/\1 \2 \3/p' | awk '{ printf "#%02x%02x%02x", $1, $2, $3 }')
[ "$qst" = breeze ] && awk -v l="$ql" 'BEGIN { exit !(l < 0.3) }' && pass "Qt from the drawer: Breeze, dark window $qbg (lum $ql)" ||
  fail "Qt from the drawer: style ${qst:-?}, window ${qbg:-?} (lum $ql) - not the dark PowOS scheme"
[ -n "$sbg" ] && [ "$qbg" = "$sbg" ] && pass "Qt's window colour is the session scheme's ($(kv scheme "$(line scheme=)") $sbg)" ||
  fail "Qt's window $qbg, the scheme's $sbg ($(line scheme=))"
gbg=$(kv bg "$GW"); gl=$(lum "${gbg:-#ffffff}")
awk -v l="$gl" 'BEGIN { exit !(l < 0.3) }' && pass "GTK from the drawer: dark window $gbg ($(kv theme "$GW"), Wayland)" || fail "GTK from the drawer: window ${gbg:-?} (lum $gl): light"
gbx=$(kv bg "$GX"); awk -v l="$(lum "${gbx:-#ffffff}")" 'BEGIN { exit !(l < 0.3) }' && pass "GTK X11: dark window $gbx" || fail "GTK X11: window ${gbx:-?}: light"

# 3. Kate from home, on the screen (FACTS_ONLY=1: stop here - read-only, fine outside the queue).
[ "${FACTS_ONLY:-0}" = 1 ] && { [ $FAILS = 0 ] && echo "facts passed; artefacts: $OUT" || { echo "$FAILS failed; artefacts: $OUT"; exit 1; }; exit 0; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { log "the screen is $s - not woken (rule); Kate's screencap skipped"; [ $FAILS = 0 ] || exit 1; exit 3; }
KATE_MINE=0
restore() {
  [ $KATE_MINE = 1 ] && us "pkill -x kate"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  echo "restored"
}
. "$here/window-lock.sh"
window_lock linux-look.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
lin() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
bounds() { sh_ "am stack list | grep -E \"taskId=$1:\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?)"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
[ "$(us 'pgrep -xc kate' | tail -1)" = 0 ] && KATE_MINE=1 || log "Kate was already running (started before this check: its look is its start's)"
before=$(lin)
r=$(hcall apps.launch "['l:org.kde.kate']" "()=>'ok'"); [ "$r" = ok ] || { fail "apps.launch l:org.kde.kate: $r"; exit 1; }
KT=""; for _ in $(seq 30); do sleep 1; KT=$(comm -13 <(echo "$before") <(lin) | tail -1); [ -n "$KT" ] && break; done; chk kate
[ -n "$KT" ] || KT=$(lin | tail -1)
[ -n "$KT" ] || { fail "no window task for Kate within 30 s"; exit 1; }
sleep 4
ke=$(us 'k=$(pgrep -xn kate); tr "\0" "\n" < /proc/$k/environ | grep -E "^(XDG_CURRENT_DESKTOP|KDE_FULL_SESSION)=" | tr "\n" " "')
[[ $ke == *XDG_CURRENT_DESKTOP=KDE* ]] && pass "Kate runs with the KDE environment ($ke)" || fail "Kate's environment lacks the KDE desktop: '$ke'"
read -r b1 b2 b3 b4 <<<"$(bounds "$KT")"
"$T/shot.sh" "$OUT/kate.png" >/dev/null 2>&1 || { fail "no screencap (shot.sh)"; exit 1; }
g=$(ffmpeg -v error -i "$OUT/kate.png" -vf "crop=$((b3 - b1 - 40)):$((b4 - b2 - 40)):$((b1 + 20)):$((b2 + 20)),scale=200:-1,format=gray" \
    -f rawvideo - 2>/dev/null | python3 -c 'import sys; d=sys.stdin.buffer.read(); print(sum(d) // max(len(d), 1))')
log "Kate: task $KT at $b1,$b2 $b3,$b4 ($((b3 - b1)) px wide = $(awk -v w=$((b3 - b1)) -v s="${SC:-1}" 'BEGIN { printf "%.0f", w / s }') units at ${SC}x), mean grey ${g:-?}/255 - $OUT/kate.png"
[ "${g:-255}" -lt 90 ] && pass "Kate's window is dark on the screen (mean grey $g)" || fail "Kate's window is light (mean grey ${g:-?}) - $OUT/kate.png"
"$T/review-image.sh" "$OUT/kate.png" >/dev/null 2>&1 || true
[ $FAILS = 0 ] && echo "all passed; artefacts: $OUT" || { echo "$FAILS failed; artefacts: $OUT"; exit 1; }
