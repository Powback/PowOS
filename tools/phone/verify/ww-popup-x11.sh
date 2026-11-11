#!/bin/bash
# lanes: phone
# screen: inner
# needs: kwin home
# ww-popup-x11.sh: an X11 app's dropdown menu shows (board task linux-app-dropdown-popup-menus-don-t-show-overri: kwin
# 0062-0064 surface override-redirect popups). ww-popups.sh proves it on Steam; this needs no Steam and no input: its
# own X11 app (ww-popup-probe.py, PySide6 over Xwayland) opens as a web window, then shows a menu with no parent (an
# override-redirect window with no WM_TRANSIENT_FOR, as Steam's) for 4 s and closes it. PASS needs, for that menu:
#   kwin    KWin's "exports popup" line (hyprland.log)       popup   "popup P N at ..." (PowosPopups), no "insane" line
#   buffer  kwin < 3.72 (N3a): "popup N buffer #..." (PopupLog's offscreen reader counts them)
#           kwin 3.72+ (N3b): KWin's "window task N live" - the layer's consumer hands its buffers to KWin, which logs
#           it once it imported them; the app never sees a frame (they go straight to the layer), so no buffer line
#   layer   with kwin 3.72+: "popup N layer up" (its own layer over home)
#   gone    "popup-gone" after it closed
# Its app is quit after; nothing of the user's is touched. Exit 0 PASS, 1 FAIL, 3 not now / a KWin without 0063.
set -uo pipefail
NAME=ww-popup-x11; . "$(dirname "$0")/wwc-lib.sh"; . "$(dirname "$0")/popup-proof.sh"
HY=/data/powos/root/run/powos-app/hyprland.log
# The probe's file is root's (copied in by sh_ below): the session user's rm left it behind on every run (11-10: still
# in the rootfs's /tmp from 06:28). Its app quits by itself 6 s after the menu, or 120 s after start (the probe's own
# clock), so a check killed before its EXIT trap still leaves nothing drawn.
wwc_extra() { ww_us "pkill -f ww-popup-probe.py; true" >/dev/null; sh_ "rm -f /data/powos/root/tmp/wwc-popup.go /data/powos/root/tmp/ww-popup-probe.py /data/powos/root/tmp/wwc-popup.log"; }
kw=$(ww_us 'pacman -Q kwin' | tail -1)
kwat() { python3 -c "import sys; r=sys.argv[1].split('-')[-1]; sys.exit(0 if tuple(map(int,r.split('.')))>=tuple(map(int,sys.argv[2].split('.'))) else 1)" "${kw:-x 0-0}" "$1" 2>/dev/null; }
kwat 3.71 || { echo "SKIP $kw has no 0063 (popups as surfaces need kwin 3.71+)"; exit 3; }
wwc_start
"$A" push "$(dirname "$0")/ww-popup-probe.py" /data/local/tmp/ww-popup-probe.py >/dev/null 2>&1
sh_ "cp /data/local/tmp/ww-popup-probe.py /data/powos/root/tmp/ && chmod 644 /data/powos/root/tmp/ww-popup-probe.py && rm /data/local/tmp/ww-popup-probe.py"
since=$("$A" shell 'date +%m-%d\ %H:%M:%S.000' | tr -d '\r'); k0=$(sh_ "wc -l < $HY" | tr -dc 0-9)
before=$(wwids l:)
wwc_ses "rm -f /tmp/wwc-popup.go; QT_QPA_PLATFORM=xcb setsid python3 /tmp/ww-popup-probe.py /tmp/wwc-popup.go >/tmp/wwc-popup.log 2>&1 </dev/null &" >/dev/null
w=$(wwnew 30 "$before" l:); w=${w%%[[:space:]]*}
[ -n "$w" ] || { bad "the probe's X11 window came as no web window in 30 s"; wwc_end; }
MINE_W="$w"; sleep 3; ww_us "touch /tmp/wwc-popup.go" >/dev/null; sleep 9
say "probe: $(ww_us 'cat /tmp/wwc-popup.log' | tr '\n' ' ' | cut -c1-200)"
pl=$("$A" shell "logcat -d -T '$since' -s PowosPopups:*" 2>/dev/null | tr -d '\r' | tee "$OUT/popups.txt" | grep -oE 'popup.*')
kl=$(sh_ "tail -n +$((${k0:-0} + 1)) $HY | grep -a \"exports popup\" | tail -1")
say "kwin: ${kl:-none}"; say "$(head -6 <<<"$pl")"
[ -n "$kl" ] || bad "kwin: no \"exports popup\" line for the menu"
grep -qE '^popup [0-9]+ [0-9]+ at ' <<<"$pl" || bad "popup: no \"popup P N at\" line (PowosPopups)"
grep -q 'insane' <<<"$pl" && bad "popup: $(grep -m1 insane <<<"$pl")"
grep -q '^popup-gone' <<<"$pl" || bad "gone: no \"popup-gone\" after the menu closed"
N=$(grep -m1 -oE 'exports popup [0-9]+' <<<"$kl" | grep -oE '[0-9]+$')
if [ -n "$N" ]; then
  kwat 3.72 && L=1 || L=0
  popup_proof "$N" "$L" "$pl" "$(sh_ "tail -n +$((${k0:-0} + 1)) $HY | grep -a \"window task $N live\"")"
fi
wwc_end "the X11 menu came through KWin as a popup surface with buffers ($kw) and went"
