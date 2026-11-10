#!/bin/bash
# lanes: phone
# tools/phone/verify/ww-popups.sh: N3 of docs/WEB_WINDOWS.md "Native-glued windows" on the phone - a Linux web window's
# popups are surfaces of their own (kwin 0063, pkgrel 3.71+): Steam's menus (X11 override-redirect POPUP_MENU windows, no
# WM_TRANSIENT_FOR, 0062) each come to the app as "popup <window> <popup> x y w h" with their own buffers, and go as
# "popup-gone". kwin 3.71 (N3a): the app's consumer is log-only (PopupLog). kwin 3.72+ (N3b, 0064): each is a layer of
# its own over home (WebWindowPopups), not cut at the window's edge, and touches on it are its window's.
# Needs home unfolded, no game under Steam (a game is the user's: SKIP), the user idle 2+ min. Queue it:
#   tools/phone/verify/queue.sh add --budget 300 native-windows tools/phone/verify/ww-popups.sh
# With no Steam main window on home it opens Steam itself through home's launch path (apps.launch l:steam, as a tap on
# its dock cell), up to STEAM_WAIT_S (150) for its main window, and leaves Steam as it found it: a Steam this started is
# closed after (powos game stop --steam); a Steam that was running keeps running, only the web window this brought up is
# closed (its bar's close: Steam goes back to the tray). It changes none of Steam's settings: it taps its menu bar as the
# user does (Android `input tap` at the X point through the web window's body) to open a menu, reads the lines, and
# closes the menu with a tap on an empty spot of the page (else its header again). No X input: xdotool's XTEST makes
# KWin's Remote Control prompt take the focus (11-08, docs/research/broforce-fps.md).
#   ww-popups.sh --dry-run   read-only: what the run would open / test / close now (no input, nothing opened)
#
# PASS needs, per menu opened (up to 2: Steam's menu bar, scanned until a new override-redirect window is viewable):
#   kwin    KWin's "exports popup N" line for it (/run/powos-app/hyprland.log)
#   popup   "popup P N at X,Y WxH" (PowosPopups): W x H = the X window's size times the window's scale (+-3 px), X,Y = its
#           place against Steam's window times the same scale (+-6 px); no "popup N insane" line
#   buffer  "popup N buffer #1" (its buffers arrived on the app's consumer)
#   gone    "popup-gone P N" within 5 s of the dismiss (a tap on the page)
# and with kwin 3.72+ (layers):
#   layer   "popup N layer up" (its layer's consumer) and KWin's "window task N live" (its buffers drawn into)
#   long    Steam's window made short (an edge drag of its frame, put back after) so a menu is taller than it: the
#           menu's part below the window shows (the screen there changed when it opened), a finger on that part goes
#           to the menu (host "a touch on its popup"; the swipe ends far off the menu, so no item is chosen), and a tap
#           on an empty spot of the page closes it ("dismiss", then "popup-gone")
# Exit: 0 PASS; 1 FAIL; 3 SKIP (not now / no Steam web window / a KWin without 0063).
set -uo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
. "$T/verify/ww-lib.sh"
. "$T/verify/popup-proof.sh"
adb="$T/adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/ww-popups-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
fail=0
# Its own clock: a verdict (with the step it stopped at) before the queue's budget kill (300 s; 11-08 16:46 the menu-bar
# scan ran ~11 s a tap, two X reads each, and was killed mid-scan with no verdict). WWP_BUDGET_S: the whole run.
DEADLINE=${WWP_BUDGET_S:-270}
late() { [ "$SECONDS" -ge "$DEADLINE" ]; }
say() { echo "$*" | tee -a "$OUT/log.txt"; }
bad() { say "FAIL $*"; fail=1; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
X='export DISPLAY=:0 XAUTHORITY=$(pgrep -a Xwayland | grep -o -- "-auth [^ ]*" | head -1 | cut -d" " -f2)'

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
if [ $DRY = 0 ]; then
  "$T/idle.sh" --wait 120 1800 >/dev/null || { echo "SKIP phone busy (not idle 2 min within 30 min)"; exit 3; }
fi
read -r screen < <("$T/idle.sh")
[ $DRY = 1 ] && say "phone: $screen"
case "$screen" in *screen=Awake*) ;; *) [ $DRY = 1 ] || { echo "SKIP screen not on ($screen)"; exit 3; } ;; esac
kw=$(us 'pacman -Q kwin' | tail -1)
kwat() { python3 -c "import sys; r=sys.argv[1].split('-')[-1]; sys.exit(0 if tuple(map(int,r.split('.')))>=tuple(map(int,sys.argv[2].split('.'))) else 1)" "${kw:-x 0-0}" "$1" 2>/dev/null; }
kwat 3.71 || { echo "SKIP $kw has no 0063 (popups as surfaces need kwin 3.71+)"; exit 3; }
LAYERS=0; kwat 3.72 && LAYERS=1
GAME_GATE_PREFIX="SKIP "; . "$(dirname "$0")/game-lib.sh"; game_gate   # one test for every check (game-lib.sh)
steamww() { hcall webwindows.list "[]" "l=>{const w=l.filter(w=>/steam/i.test(String(w.key))&&!/steam_app_/i.test(String(w.key))).at(-1);return w?'w'+w.id:'none'}"; }
sw=$(steamww)
# Steam's main X window "<id> <x> <y> <w> <h>" (as steam-tap.sh finds it), and the override-redirect windows viewable now.
# Its main window carries no name at times (11-07 16:25: every Steam window "has no name" after a frozen stretch):
# then the viewable, managed one KWin may resize (dialogs and menus may not) is it.
STEAMWIN_SH=$(cat <<'EOF'
xwininfo -root -tree 2>/dev/null | awk '/"Steam": \("steamwebhelper" "steam"\)/{print $1, "named"} /\(has no name\): \("steamwebhelper" "steam"\)/{print $1, "nameless"}' \
 | while read -r w k; do
  g=$(xwininfo -id $w 2>/dev/null | awk -v w=$w '/Map State/{m=$3} /Override Redirect State/{o=$4} /Absolute upper-left X/{ax=$4} /Absolute upper-left Y/{ay=$4} /Width:/{x=$2} /Height:/{y=$2} END{if(m=="IsViewable"&&o!="yes"&&x>=400&&y>=300)print w, ax, ay, x, y}')
  [ -n "$g" ] || continue
  [ $k = named ] && { echo "0 $g"; continue; }
  xprop -id $w _NET_WM_ALLOWED_ACTIONS 2>/dev/null | grep -q _NET_WM_ACTION_RESIZE && echo "1 $g"
 done | sort -n | head -1 | cut -d" " -f2-
EOF
)
steamwin() { us "$X; $STEAMWIN_SH" | tail -1; }
# Every viewable override-redirect steamwebhelper window, named or not (a named menu was never counted before 11-08).
menus() { us "$X; xwininfo -root -children 2>/dev/null | awk '/\\(\"steamwebhelper\" \"steam\"\\)/{print \$1}' | while read -r w; do xwininfo -id \$w 2>/dev/null | awk -v w=\$w '/Map State/{m=\$3} /Override Redirect State/{o=\$4} /Absolute upper-left X/{ax=\$4} /Absolute upper-left Y/{ay=\$4} /Width:/{x=\$2} /Height:/{y=\$2} END{if(m==\"IsViewable\"&&o==\"yes\")print w, ax, ay, x, y}'; done" | grep .; }
read -r SW SX SY SWW SWH <<<"$(steamwin)"
# Self-setup: no Steam web window, or no viewable main window in it -> Steam opened as a tap would (apps.launch l:steam:
# starts it, or brings a running one's main window up), then up to STEAM_WAIT_S for its main window. Put back on exit.
STEAM_BEFORE="" STEAM_NEW="" b0=""
restore_steam() {
  if [ -z "$STEAM_BEFORE" ] && [ -n "${STEAM_STARTED:-}" ]; then
    ww_us 'export XDG_RUNTIME_DIR=/run/powos-app DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus; timeout 35 powos game 274190 stop --steam' >/dev/null
    say "Steam closed: this check started it"
  else
    local w; [ -n "${STEAM_STARTED:-}" ] && STEAM_NEW=$(comm -13 <(echo "$b0") <(wwids l:steam)); STEAM_NEW=${STEAM_NEW//$'\n'/ }  # (no `| xargs`: killed mid-pipe it printed "xargs: /bin/echo: terminated with signal 13" as the verdict) also after a failed wait
    for w in $STEAM_NEW; do ww_close "$w"; say "Steam's web window $w closed: this check brought it up (Steam keeps running, as before)"; done
  fi; STEAM_STARTED="" STEAM_NEW=""; }
if [ -z "${SW:-}" ] || [ "$sw" = none ]; then
  STEAM_BEFORE=$(ww_us "pgrep -x steam | head -1")
  ww_ready || { echo "SKIP home has no web windows here (folded, off): Steam can't open as one"; exit 3; }
  if [ $DRY = 1 ]; then
    say "dry-run: no Steam main window on home (web window $sw); would open it via apps.launch l:steam ($([ -n "$STEAM_BEFORE" ] && echo "Steam runs: only the window it brings up is closed after" || echo "Steam not running: closed after")), then click up to 2 menus"
    exit 0
  fi
  b0=$(wwids l:steam)
  say "no viewable Steam main window (web window $sw, Steam $([ -n "$STEAM_BEFORE" ] && echo running || echo "not running")): opening it through home's launch path"
  STEAM_STARTED=1; trap 'restore_steam' EXIT
  r=$(hcall apps.launch "['l:steam']" "()=>'ok'"); [ "$r" = ok ] || { echo "FAIL setup: apps.launch l:steam: $r"; exit 1; }
  t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "${STEAM_WAIT_S:-150}" ]; do
    sleep 3
    read -r SW SX SY SWW SWH <<<"$(steamwin)"; sw=$(steamww)
    [ -n "${SW:-}" ] && [ "$sw" != none ] && [ "$(wwel "$sw" "e=>e.querySelector('.webwindow-body.live')?'live':'no'")" = live ] && break
    SW=""
  done
  STEAM_NEW=$(comm -13 <(echo "$b0") <(wwids l:steam)); STEAM_NEW=${STEAM_NEW//$'\n'/ }
  [ -n "${SW:-}" ] || { echo "FAIL setup: no viewable Steam main window $((SECONDS - t0)) s after apps.launch l:steam (web window $sw)"; exit 1; }
  say "Steam's main window up $((SECONDS - t0)) s after the launch (web window $sw, new: ${STEAM_NEW:-none})"; sleep 2
elif [ $DRY = 1 ]; then
  say "dry-run: Steam's main window $SW is up in web window $sw: would click up to 2 menus, nothing opened or closed"; exit 0
fi
# The window's scale: its web window body (device px) against the X window's width.
body=$(wwbody "$sw")
scale=$(python3 -c "import sys; l,t,r,b=map(float,sys.argv[1].split()); print('%.4f' % ((r-l)/float(sys.argv[2])))" "$body" "$SWW" 2>/dev/null || echo 1)
say "Steam: web window $sw body ${body:-?}, X window $SW at $SX,$SY ${SWW}x$SWH, scale ~$scale; $kw"
# wtap <x> <y>: a real tap (Android input, the user's path: home -> KWin touch -> Xwayland) at Steam's X window point
# x,y (window px) = its web window's body on screen + x,y times the scale.
wtap() { local l t _r _b; read -r l t _r _b <<<"$(wwbody "$sw")"; [ -n "${_b:-}" ] || return 1
  "$adb" shell "input tap $(python3 -c "print(round($l + $1 * $scale), round($t + $2 * $scale))")"; }
# menu_close "<MW MX MY MWW MWH>" [hx hy]: a menu closed as the user would - a tap on an empty spot of the page, off
# Steam's window and off the menu (its X place on screen; a menu is a layer of its own, not in the page's DOM); with no
# such spot, its menu-bar header (hx,hy) tapped again. Prints how.
menu_close() {
  local mx my mww mwh l t r b x0 y0 x1 y1 spot; read -r _ mx my mww mwh <<<"$1"; read -r l t r b <<<"$(wwbody "$sw")"
  [ -n "${b:-}" ] && [ -n "${mwh:-}" ] || { echo "nothing (no window/menu geometry)"; return 1; }
  read -r x0 y0 x1 y1 <<<"$(python3 -c "s=$scale; print(round($l+($mx-$SX)*s), round($t+($my-$SY)*s), round($l+($mx-$SX+$mww)*s), round($t+($my-$SY+$mwh)*s))")"
  spot=$(ev "(()=>{const d=devicePixelRatio;for(let y=innerHeight*0.15;y<=innerHeight*0.85;y+=14)for(let x=innerWidth*0.95;x>=innerWidth*0.05;x-=14){const e=document.elementFromPoint(x,y);if(e&&e.closest('.page-track')&&!e.closest('.webwindow,.tile,.home-tile,.app,.panel,.widget,.island,button,a,input,textarea,.bar,.dock,[data-key]')){const X=x*d,Y=y*d;if(!(X>=$x0-20&&X<=$x1+20&&Y>=$y0-20&&Y<=$y1+20)&&!(X>=$l&&X<=$r&&Y>=$t&&Y<=$b))return Math.round(X)+' '+Math.round(Y)}}return ''})()")
  if [ -n "$spot" ]; then "$adb" shell "input tap $spot"; echo "a tap on the page at $spot"
  elif [ -n "${2:-}" ]; then wtap "$2" "$3"; echo "its header ($2,$3) tapped again"
  else echo "nothing (no empty spot on the page)"; return 1; fi; }
# xover: the viewable X windows stacked over Steam's main window at its menu bar (window px 110,40), "" when none.
# Xwayland gives a touch to the X window on top at its root point (plain sprite trace, xwl_xy_to_window), so any such
# window - KWin's root-sized InputOnly guard over a Kept (hidden-preview) task window was kwin 0022's bug - takes the
# taps. xwininfo -children prints top first (XQueryTree's list reversed): the ones above Steam's come before it.
# (11-10: an earlier version of this read the list bottom first and blamed the guard, which sits below Steam's.)
xover() { us "$X; xwininfo -root -children 2>/dev/null | sed -n '/children:/,\$p' | tail -n +2 | awk '{print \$1}' | sed '/^$SW\$/,\$d' | while read -r w; do xwininfo -id \$w 2>/dev/null | awk -v w=\$w '/Map State/{m=\$3} /Class:/{c=\$2} /Override Redirect State/{o=\$4} /Absolute upper-left X/{ax=\$4} /Absolute upper-left Y/{ay=\$4} /Width:/{x=\$2} /Height:/{y=\$2} END{if(m==\"IsViewable\"&&ax<=$SX+110&&ay<=$SY+40&&ax+x>$SX+110&&ay+y>$SY+40)print w\" \"c\" or=\"o\" \"ax\",\"ay\" \"x\"x\"y}'; done" | grep . | tr '\n' ';'; }
# Before any tap: an X window over Steam's menu bar (an InputOnly one above all) is a FAIL of its own - no tap can reach it.
over0=$(xover); [ -z "$over0" ] || bad "X stacking: window(s) over Steam's main window $SW at its menu bar: $over0 (Xwayland would give them the taps)"
open0=$(menus)
[ -z "$open0" ] || { say "a Steam menu is open already ($open0): closed first ($(menu_close "$(echo "$open0" | head -1)"))"; sleep 1; }
# A menu this opened never stays open: closed on the way out (whatever ended the run).
trap 'm=$(menus | head -1); [ "${opened:-0}" -gt 0 ] && [ -n "$m" ] && menu_close "$m" >/dev/null 2>&1; us "pkill -f ww-xiw.py; rm -f /tmp/ww-xiw.py /tmp/ww-xiw.log" >/dev/null; restore_steam' EXIT

# A passive X input log for the scan (x-input-watch.py: XI2 raw events on the root, Enter/Focus on Steam's window, the
# X focus at each press; it sends and grabs nothing): which hop drops a tap that home gave KWin - KWin -> Xwayland (no
# RawTouchBegin), Xwayland's touch -> pointer emulation (raw touches, no RawButtonPress / EnterNotify), or Steam itself.
us "$X; base64 -d > /tmp/ww-xiw.py <<'B64'
$(base64 < "$(dirname "$0")/x-input-watch.py")
B64
setsid python3 /tmp/ww-xiw.py $SW $((DEADLINE - SECONDS + 5)) > /tmp/ww-xiw.log 2>&1 < /dev/null &" >/dev/null
xiw() { us "cat /tmp/ww-xiw.log 2>/dev/null"; }
since=$("$adb" shell 'date +%m-%d\ %H:%M:%S.000' | tr -d '\r')
klog0=$(rs 'wc -l < /run/powos-app/hyprland.log' | tail -1)
opened=0
# Steam's menu bar (Steam, View, Friends, Games, Help) along the top of its window, window px (the 11-07 screenshot,
# steam-one-window: labels centred at y ~40, x ~110/220/330/450/550 at scale 1): scanned left to right until a tap
# opens a menu (a new viewable override-redirect window), then the next one further right. One X read per tap (the
# last read is the next tap's "before"; ~4 s each over user.sh), and the run's clock checked before every tap.
taps=0 kpop=0 scan_stop=""
popn() { "$adb" shell "logcat -d -T '$since' -s PowosPopups:I" 2>/dev/null | tr -d '\r' | grep -cE 'popup [0-9]+ [0-9]+ at '; }
cur=$(menus)
for y in 40 28 52; do
  for x in 110 220 330 450 550; do
    [ $opened -ge 2 ] && break 2
    late && { scan_stop="the run's ${DEADLINE}s clock ran out at the tap at $x,$y ($taps taps, $opened menus)"; break 2; }
    before=$cur
    wtap "$x" "$y" || { scan_stop="Steam's window body isn't on screen (tap at $x,$y)"; break 2; }
    taps=$((taps + 1))
    sleep 1.2
    cur=$(menus)
    new=$(comm -13 <(echo "$before" | sort) <(echo "$cur" | sort) | grep . | head -1)
    [ -n "$new" ] || continue
    read -r MW MX MY MWW MWH <<<"$new"
    opened=$((opened + 1))
    [ -n "${CX:-}" ] || { CX=$x; CY=$y; }
    say "menu $opened: a tap at $x,$y opened X window $MW at $MX,$MY ${MWW}x$MWH"
    sleep 1.5
    lines=$("$adb" shell "logcat -d -T '$since' -s PowosPopups:I" 2>/dev/null | tr -d '\r' | grep -oE 'popup.*')
    exp=$(python3 -c "import sys; s=float(sys.argv[1]); a=list(map(int,sys.argv[2:])); print(round(a[0]*s), round(a[1]*s), round((a[2]-a[4])*s), round((a[3]-a[5])*s))" "$scale" "$MWW" "$MWH" "$MX" "$MY" "$SX" "$SY")
    read -r ew eh ex ey <<<"$exp"
    # The popup line whose size matches this menu's (the newest such).
    hit=$(echo "$lines" | awk -v ew="$ew" -v eh="$eh" '$1=="popup" && $4=="at" { split($6,s,"x"); if ((s[1]-ew)^2 <= 9 && (s[2]-eh)^2 <= 9) l=$0 } END { print l }')
    if [ -z "$hit" ]; then
      bad "popup: no \"popup\" line ${ew}x$eh (+-3) for menu $opened; lines: $(echo "$lines" | grep '^popup [0-9]* [0-9]* at' | tail -4 | tr '\n' ';')"
    else
      say "popup: $hit (expected ~$ex,$ey ${ew}x$eh)"
      read -r _ P N _ at _ <<<"$hit"
      ax=${at%,*}; ay=${at#*,}
      [ $(( (ax - ex) * (ax - ex) )) -le 36 ] && [ $(( (ay - ey) * (ay - ey) )) -le 36 ] ||
        bad "popup $N at $ax,$ay, want ~$ex,$ey (its X place against Steam's window x $scale, +-6 px)"
      echo "$lines" | grep -q "^popup $N insane" && bad "popup $N: $(echo "$lines" | grep "^popup $N insane" | tail -1)"
      popup_proof "$N" "$LAYERS" "$lines" "$(rs "tail -n +$((klog0 + 1)) /run/powos-app/hyprland.log | grep -a 'window task $N live'")"
      rs "tail -n +$((klog0 + 1)) /run/powos-app/hyprland.log | grep -a 'exports popup $N '" | tail -1 | grep -q . &&
        say "kwin: $(rs "tail -n +$((klog0 + 1)) /run/powos-app/hyprland.log | grep -a 'exports popup $N '" | tail -1 | cut -c1-200)" ||
        bad "kwin: no \"exports popup $N\" line in KWin's log"
    fi
    how=$(menu_close "$new" "$x" "$y")
    gone=""
    for _ in 1 2 3 4 5; do
      sleep 1
      [ -n "${N:-}" ] || break
      gone=$("$adb" shell "logcat -d -T '$since' -s PowosPopups:I" 2>/dev/null | tr -d '\r' | grep -oE "popup-gone $P $N:.*" | tail -1)
      [ -n "$gone" ] && break
    done
    [ -n "${N:-}" ] && { [ -n "$gone" ] && say "gone: $gone" || bad "gone: no \"popup-gone ... $N\" 5 s after closing it ($how)"; }
    cur=$(menus)
    [ -z "$(comm -13 <(echo "$before" | sort) <(echo "$cur" | sort) | grep .)" ] || say "note: the menu is still viewable after closing it ($how)"
    N=""
  done
done
[ -n "$scan_stop" ] && bad "scan stopped: $scan_stop"
# The X input log always (11-10 09:21: a menu opened, so it was only read in the no-menu branch and never kept).
xl=$(xiw); printf '%s\n' "$xl" > "$OUT/x-input.txt"
[ -n "$xl" ] || say "note: the X input watcher logged nothing (did ww-xiw.py start? /tmp/ww-xiw.log empty)"
if [ $opened -lt 1 ]; then
  # Which side failed: the taps never reached KWin, KWin exported a popup the X read missed, or Steam opened nothing.
  # Home's side: each tap's DOWN on the body logs "gesture to KWin window N" (WebWindows.linuxClaim). KWin's own "touch
  # at" line is only for a touch that goes to a popup/dialog or lands outside the window's input region - a plain touch
  # on the window logs nothing there, so its count is no proof the taps missed KWin (11-10 07:32 said so wrongly: home
  # had logged all 15 gestures to KWin window 47).
  hg=$("$adb" shell "logcat -d -T '$since' -s PowosWebWindows:I" 2>/dev/null | tr -d '\r' | grep -c "gesture to KWin window")
  kt=$(rs "tail -n +$((klog0 + 1)) /run/powos-app/hyprland.log | grep -ac 'touch at'" | tail -1)
  kpop=$(popn)
  # screencap with several displays prints a warning before the PNG on stdout: only the PNG is kept.
  "$adb" exec-out screencap -p 2>/dev/null | python3 -c "import sys; d=sys.stdin.buffer.read(); i=d.find(b'\x89PNG'); sys.stdout.buffer.write(d[max(i,0):])" > "$OUT/no-menu.png"
  why="taps reached KWin, Steam opened no X menu"
  [ "${kpop:-0}" -gt 0 ] && why="KWin exported popups the X read didn't see"
  over=$(xover)
  [ -n "$over" ] && why="taps reached KWin, but X window(s) over Steam's at the menu bar took them (Xwayland picks by X stacking): $over"
  [ "${hg:-0}" = 0 ] && why="home sent no gesture to KWin (the taps missed Steam's web window body, or something above it in the page took them)"
  rt=$(grep -c ' raw RawTouchBegin' <<<"$xl"); rb=$(grep -c ' raw RawButtonPress' <<<"$xl"); en=$(grep -c ' window EnterNotify' <<<"$xl")
  fo=$(grep -oE 'raw Raw(TouchBegin|ButtonPress) focus 0x[0-9a-f]+' <<<"$xl" | awk '{print $4}' | sort | uniq -c | tr '\n' ' ')
  xs="X: raw touch begins $rt, raw button presses $rb, EnterNotify on Steam's window $en, X focus at them: ${fo:-?} (Steam's $SW; $OUT/x-input.txt)"
  if [ "${hg:-0}" != 0 ] && [ -z "$over" ] && [ "${kpop:-0}" = 0 ] && grep -q ' start ' <<<"$xl"; then
    if [ "$rt" = 0 ]; then why="taps reached KWin but no touch reached Xwayland (no XI2 RawTouchBegin): KWin's task touch -> wl_touch hop drops them"
    elif [ "$rb" = 0 ]; then why="Xwayland got the touches but emulated no pointer press (Steam's CEF wants pointer events)"
    else why="Xwayland gave Steam touches and pointer presses, Steam opened no menu (X focus: ${fo:-?})"; fi
  fi
  bad "no tap on Steam's menu bar opened a menu ($taps taps; home gestures to KWin ${hg:-?}, KWin touch-at lines ${kt:-?}, app popup lines ${kpop:-?}; screen $OUT/no-menu.png): $why; $xs"
fi

# N3b: a menu taller than its window shows whole and takes touches (kwin 3.72+).
# region <save|cmp> l t r b: the screen's pixels there (every 6th) saved, or the share (%) that differ from the saved ones.
region() { "$adb" shell "su -c 'screencap /data/powos/root/var/tmp/wwp.raw'" >/dev/null 2>&1
  rs "python3 - $* <<'REGION' 2>/dev/null || echo 0
import struct, sys
mode = sys.argv[1]; l, t, r, b = map(int, sys.argv[2:6]); d = open('/var/tmp/wwp.raw', 'rb').read(); w, h = struct.unpack('<II', d[:8])
off = len(d) - w * h * 4; px = []
for y in range(max(t, 0), min(b, h), 6):
    for x in range(max(l, 0), min(r, w), 6):
        p = off + (y * w + x) * 4; px.append(d[p:p + 3])
if mode == 'save':
    open('/var/tmp/wwp.saved', 'wb').write(b''.join(px)); print(len(px))
else:
    s = open('/var/tmp/wwp.saved', 'rb').read(); old = [s[i:i + 3] for i in range(0, len(s), 3)]
    n = min(len(old), len(px)); print(round(100.0 * sum(1 for a, c in zip(old, px) if sum(abs(i - j) for i, j in zip(a, c)) > 24) / max(n, 1)))
REGION
rm -f /var/tmp/wwp.raw" | tail -1; }
# py <expr>: a number from python (the geometry below).
py() { python3 -c "print(round($1))"; }
long_menu() {
  local fl ft fr fb bl bt br bb nb l2 t2 r2 bb2 hit at ax ay pw ph sx0 sx1 sy1 lines spot gone s t0 k0 diff mx my how
  read -r fl ft fr fb <<<"$(wwrect "$sw")"; read -r bl bt br bb <<<"$(wwbody "$sw")"
  [ -n "${fb:-}" ] && [ -n "${bb:-}" ] || { bad "long: Steam's frame/body not on screen"; return; }
  nb=$((bt + 360))
  say "long: Steam's body $bl $bt $br $bb (frame $fl $ft $fr $fb): its bottom edge dragged up to $nb (put back after)"
  "$adb" shell "input swipe $((fr - 4)) $((fb - 4)) $((fr - 4)) $((nb + fb - bb - 4)) 900"; sleep 2.5
  RESTORE="$((fr - 4)) $((nb + fb - bb - 4)) $((fr - 4)) $((fb - 4))"
  read -r l2 t2 r2 bb2 <<<"$(wwbody "$sw")"
  [ "${bb2:-$bb}" -lt "$bb" ] || { bad "long: the edge drag didn't make Steam's window shorter ($bb -> ${bb2:-?})"; return; }
  region save "$bl" "$bb2" "$br" "$((bb2 + 600))" >/dev/null
  read -r SW SX SY SWW SWH <<<"$(steamwin)"
  t0=$("$adb" shell 'date +%m-%d\ %H:%M:%S.000' | tr -d '\r'); k0=$(rs 'wc -l < /run/powos-app/hyprland.log' | tail -1)
  wtap "$CX" "$CY"; sleep 2
  lines=$("$adb" shell "logcat -d -T '$t0' -s PowosPopups:I" 2>/dev/null | tr -d '\r' | grep -oE 'popup.*')
  hit=$(echo "$lines" | grep -E '^popup [0-9]+ [0-9]+ at' | tail -1)
  [ -n "$hit" ] || { bad "long: no popup line after the tap at $CX,$CY"; return; }
  read -r _ P N _ at pw _ <<<"$hit"; ax=${at%,*}; ay=${at#*,}; ph=${pw#*x}; pw=${pw%x*}
  s=$(python3 -c "import sys; print('%.4f' % ((float(sys.argv[2]) - float(sys.argv[1])) / float(sys.argv[3])))" "$l2" "$r2" "$SWW")
  # Its part below the window on screen (device px): the window's body bottom .. the menu's bottom.
  sy1=$(py "$t2 + ($ay + $ph) * $s"); sx0=$(py "$l2 + $ax * $s"); sx1=$(py "$l2 + ($ax + $pw) * $s")
  say "long: $hit, window body $l2 $t2 $r2 $bb2 x$s: the menu reaches $sy1 (the window's bottom $bb2)"
  [ "$sy1" -gt $((bb2 + 40)) ] || { bad "long: the menu isn't taller than the window ($sy1 vs $bb2): nothing to show"; return; }
  diff=$(region cmp "$sx0" "$((bb2 + 4))" "$sx1" "$((sy1 - 4))")
  say "long: ${diff}% of the screen below the window (the menu's part outside it) changed when it opened"
  [ "${diff:-0}" -ge 40 ] || bad "long: the menu's part below its window isn't on screen (${diff}% changed, want >= 40)"
  # A finger on that part, the swipe ending far off the menu: the menu takes the touch, no item is chosen.
  my=$(( (bb2 + sy1) / 2 )); mx=$(( (sx0 + sx1) / 2 ))
  "$adb" shell "input swipe $mx $my $(( mx > 1200 ? mx - 900 : mx + 900 )) $my 400"; sleep 1.5
  if "$adb" shell "logcat -d -T '$t0' -s PowosWebWindows:I" 2>/dev/null | awk '/a touch on its popup/{f=1} END{exit !f}'; then
    say "long: the host gave the touch on the menu's outside part to its window"
  else bad "long: the touch on the menu's outside part wasn't its window's"; fi
  rs "tail -n +$((k0 + 1)) /run/powos-app/hyprland.log | grep -a 'touch at' | tail -1" | cut -c1-200 | sed 's/^/long: KWin: /' | tee -a "$OUT/log.txt"
  # Dismiss: a tap on an empty spot of the page, off the window and the menu (else its header again).
  spot=$(ev "(()=>{const d=devicePixelRatio;for(let y=innerHeight*0.15;y<=innerHeight*0.85;y+=14)for(let x=innerWidth*0.95;x>=innerWidth*0.05;x-=14){const e=document.elementFromPoint(x,y);if(e&&e.closest('.page-track')&&!e.closest('.webwindow,.tile,.home-tile,.app,.panel,.widget,.island,button,a,input,textarea,.bar,.dock,[data-key]')){const X=x*d,Y=y*d;if(!(X>=$sx0-20&&X<=$sx1+20&&Y>=$t2-20&&Y<=$sy1+20)&&!(X>=$l2&&X<=$r2&&Y>=$t2&&Y<=$bb2))return Math.round(X)+' '+Math.round(Y)}}return ''})()")
  if [ -z "$spot" ]; then how="its header tapped again"; wtap "$CX" "$CY"
  else how="a tap on the page at $spot"; "$adb" shell "input tap $spot"; fi
  gone=""; for _ in 1 2 3 4; do sleep 1; gone=$("$adb" shell "logcat -d -T '$t0' -s PowosPopups:I" 2>/dev/null | tr -d '\r' | grep -oE "popup-gone $P $N:.*" | tail -1); [ -n "$gone" ] && break; done
  if [ -n "$gone" ]; then say "long: $how closed it: $gone"; else bad "long: popup $N still open 4 s after $how"; fi
}
RESTORE=""
if [ $LAYERS = 1 ] && [ -n "${CX:-}" ]; then
  if [ $((SECONDS + 60)) -ge "$DEADLINE" ]; then bad "long: not run - $((DEADLINE - SECONDS)) s left of the run's ${DEADLINE}s clock (it needs ~60)"; else long_menu; fi
fi
if [ -n "$RESTORE" ]; then "$adb" shell "input swipe $RESTORE 900"; sleep 1.5; say "long: Steam's window size put back ($(wwbody "$sw"))"; fi
"$adb" shell "logcat -d -T '$since' -s PowosPopups:*" 2>/dev/null > "$OUT/popups.txt"
[ "$fail" = 0 ] && say "PASS $opened Steam menus came as popup surfaces with sane geometry$([ $LAYERS = 1 ] && echo ", shown as layers of their own past the window's edge, touchable, dismissed from the page" || echo " and buffers")"
exit "$fail"
