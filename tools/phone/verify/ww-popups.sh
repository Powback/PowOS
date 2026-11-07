#!/bin/bash
# lanes: phone
# tools/phone/verify/ww-popups.sh: N3a of docs/WEB_WINDOWS.md "Native-glued windows" on the phone - a Linux web window's
# popups are surfaces of their own (kwin 0063, pkgrel 3.71+): Steam's menus (X11 override-redirect POPUP_MENU windows, no
# WM_TRANSIENT_FOR, 0062) each come to the app as "popup <window> <popup> x y w h" with their own buffers, and go as
# "popup-gone". The app's consumer is log-only (PopupLog, logcat PowosPopups): nothing on screen changes.
# Needs Steam running as a web window on home (unfolded), no game under it, the user idle 2+ min. Queue it:
#   tools/phone/verify/queue.sh add --budget 300 native-windows tools/phone/verify/ww-popups.sh
# It never starts or closes Steam and changes none of its settings: it clicks its menu bar as X input (xdotool, Steam's
# own X window) to open a menu, reads the lines, and closes the menu with Escape.
#
# PASS needs, per menu opened (up to 2: Steam's menu bar, scanned until a new override-redirect window is viewable):
#   kwin    KWin's "exports popup N" line for it (/run/powos-app/hyprland.log)
#   popup   "popup P N at X,Y WxH" (PowosPopups): W x H = the X window's size times the window's scale (+-3 px), X,Y = its
#           place against Steam's window times the same scale (+-6 px); no "popup N insane" line
#   buffer  "popup N buffer #1" (its buffers arrived on the app's consumer)
#   gone    "popup-gone P N" within 5 s of the Escape
# Exit: 0 PASS; 1 FAIL; 3 SKIP (not now / no Steam web window / a KWin without 0063).
set -uo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
. "$T/verify/ww-lib.sh"
adb="$T/adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/ww-popups-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
fail=0
say() { echo "$*" | tee -a "$OUT/log.txt"; }
bad() { say "FAIL $*"; fail=1; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
X='export DISPLAY=:0 XAUTHORITY=$(pgrep -a Xwayland | grep -o -- "-auth [^ ]*" | head -1 | cut -d" " -f2)'

"$T/idle.sh" --wait 120 1800 >/dev/null || { echo "SKIP phone busy (not idle 2 min within 30 min)"; exit 3; }
read -r screen < <("$T/idle.sh")
case "$screen" in *screen=Awake*) ;; *) echo "SKIP screen not on ($screen)"; exit 3 ;; esac
kw=$(us 'pacman -Q kwin' | tail -1)
python3 -c "import sys; r=sys.argv[1].split('-')[-1]; sys.exit(0 if tuple(map(int,r.split('.')))>=(3,71) else 1)" "${kw:-x 0-0}" 2>/dev/null ||
  { echo "SKIP $kw has no 0063 (popups as surfaces need kwin 3.71+)"; exit 3; }
[ "$(us "pgrep -fc 'SteamLaunch AppId='" | tail -1)" = 0 ] || { echo "SKIP a game runs under Steam (the user's): not now"; exit 3; }
sw=$(hcall webwindows.list "[]" "l=>{const w=l.find(w=>/steam/i.test(String(w.key))&&!/steam_app_/i.test(String(w.key)));return w?'w'+w.id:'none'}")
case $sw in w[0-9]*) ;; *) echo "SKIP Steam isn't a web window on home ($sw)"; exit 3 ;; esac
# Steam's main X window "<id> <x> <y> <w> <h>" (as steam-tap.sh finds it), and the override-redirect windows viewable now.
steamwin() { us "$X; xwininfo -root -tree 2>/dev/null | awk '/\"Steam\": \\(\"steamwebhelper\" \"steam\"\\)/{print \$1}' | while read -r w; do xwininfo -id \$w 2>/dev/null | awk -v w=\$w '/Map State/{m=\$3} /Absolute upper-left X/{ax=\$4} /Absolute upper-left Y/{ay=\$4} /Width:/{x=\$2} /Height:/{y=\$2} END{if(m==\"IsViewable\"&&x>=400&&y>=300)print w, ax, ay, x, y}'; done | head -1" | tail -1; }
menus() { us "$X; xwininfo -root -children 2>/dev/null | awk '/\\(\"steamwebhelper\" \"steam\"\\)/ && /has no name/{print \$1}' | while read -r w; do xwininfo -id \$w 2>/dev/null | awk -v w=\$w '/Map State/{m=\$3} /Override Redirect State/{o=\$4} /Absolute upper-left X/{ax=\$4} /Absolute upper-left Y/{ay=\$4} /Width:/{x=\$2} /Height:/{y=\$2} END{if(m==\"IsViewable\"&&o==\"yes\")print w, ax, ay, x, y}'; done" | grep .; }
read -r SW SX SY SWW SWH <<<"$(steamwin)"
[ -n "${SW:-}" ] || { echo "SKIP no viewable Steam main window"; exit 3; }
open0=$(menus)
[ -z "$open0" ] || { say "a Steam menu is open already ($open0): Escape first"; us "$X; xdotool key Escape" >/dev/null; sleep 1; }
# The window's scale: its web window body (device px) against the X window's width.
body=$(wwbody "$sw")
scale=$(python3 -c "import sys; l,t,r,b=map(float,sys.argv[1].split()); print('%.4f' % ((r-l)/float(sys.argv[2])))" "$body" "$SWW" 2>/dev/null || echo 1)
say "Steam: web window $sw body ${body:-?}, X window $SW at $SX,$SY ${SWW}x$SWH, scale ~$scale; $kw"
# A menu this opened never stays open: Escape on the way out (whatever ended the run).
trap '[ "${opened:-0}" -gt 0 ] && us "$X; xdotool key Escape" >/dev/null 2>&1' EXIT

since=$("$adb" shell 'date +%m-%d\ %H:%M:%S.000' | tr -d '\r')
klog0=$(rs 'wc -l < /run/powos-app/hyprland.log' | tail -1)
opened=0
# Steam's menu bar (Steam, View, Friends, Games, Help) along the top of its window, window px: scanned left to right
# until a click opens a menu (a new viewable override-redirect window), then the next one further right.
for y in 50 58 40 66; do
  for x in 40 110 190 280 360 430; do
    [ $opened -ge 2 ] && break 2
    before=$(menus)
    us "$X; xdotool mousemove --window $SW $x $y click 1" >/dev/null
    sleep 1.2
    new=$(comm -13 <(echo "$before" | sort) <(menus | sort) | head -1)
    [ -n "$new" ] || continue
    read -r MW MX MY MWW MWH <<<"$new"
    opened=$((opened + 1))
    say "menu $opened: a click at $x,$y opened X window $MW at $MX,$MY ${MWW}x$MWH"
    sleep 1.5
    lines=$("$adb" shell "logcat -d -T '$since' -s PowosPopups:I PowosPopups:W" 2>/dev/null | tr -d '\r' | grep -oE 'popup.*')
    exp=$(python3 -c "import sys; s=float(sys.argv[1]); a=list(map(int,sys.argv[2:])); print(round(a[2]*s), round(a[3]*s), round((a[0]-a[4])*s), round((a[1]-a[5])*s))" "$scale" "$MWW" "$MWH" "$MX" "$MY" "$SX" "$SY")
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
      echo "$lines" | grep -q "^popup $N buffer #1 " && say "buffer: $(echo "$lines" | grep "^popup $N buffer #1 " | tail -1)" ||
        bad "buffer: no buffer of popup $N reached the app's consumer"
      rs "tail -n +$((klog0 + 1)) /run/powos-app/hyprland.log | grep -a 'exports popup $N '" | tail -1 | grep -q . &&
        say "kwin: $(rs "tail -n +$((klog0 + 1)) /run/powos-app/hyprland.log | grep -a 'exports popup $N '" | tail -1 | cut -c1-200)" ||
        bad "kwin: no \"exports popup $N\" line in KWin's log"
    fi
    us "$X; xdotool key Escape" >/dev/null
    gone=""
    for _ in 1 2 3 4 5; do
      sleep 1
      [ -n "${N:-}" ] || break
      gone=$("$adb" shell "logcat -d -T '$since' -s PowosPopups:I" 2>/dev/null | tr -d '\r' | grep -oE "popup-gone $P $N:.*" | tail -1)
      [ -n "$gone" ] && break
    done
    [ -n "${N:-}" ] && { [ -n "$gone" ] && say "gone: $gone" || bad "gone: no \"popup-gone ... $N\" 5 s after the Escape"; }
    [ -z "$(comm -13 <(echo "$before" | sort) <(menus | sort))" ] || say "note: the menu is still viewable after the Escape"
    N=""
  done
done
[ $opened -ge 1 ] || bad "no click on Steam's menu bar opened a menu (no new override-redirect window): the scan's points, or Steam"
"$adb" shell "logcat -d -T '$since' -s PowosPopups:*" 2>/dev/null > "$OUT/popups.txt"
[ "$fail" = 0 ] && say "PASS $opened Steam menus came as popup surfaces with sane geometry and buffers"
exit "$fail"
