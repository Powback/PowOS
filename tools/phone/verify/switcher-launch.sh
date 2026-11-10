#!/bin/bash
# lanes: phone
# needs: kwin home
# switcher-launch.sh: a launch closes the switcher and comes up in front (board task launch-closes-overview, 25d51cc8),
# on the unfolded home, through home's launch path (apps.launch, a tap's call):
#   switcher  the switcher up (KEYCODE_APP_SWITCH), Kate launched: the overview closes (.recents.open gone, the window
#             log's last "switcher up|down" is down) and Kate's web window shows its bar
#   empty     an empty PowosWindowActivity in front (started bare: what covered home on 11-07), Dolphin launched: home is
#             the top resumed activity again and Dolphin's window shows its bar
# Opens only apps the user isn't running; closes them and the empty task after. Exit 0 PASS, 1 FAIL, 3 not now.
set -uo pipefail
NAME=switcher-launch; . "$(dirname "$0")/wwc-lib.sh"
top() { sh_ "dumpsys activity activities | grep -m1 topResumedActivity"; }
swlog() { sh_ "grep -E \"switcher (up|down|closed)\" /data/data/com.powos.app/files/window-log.txt | tail -1"; }
# recents: the layer up on home's page ("true"); "false" / "" (no answer: the page hidden) otherwise. waitrec <want>:
# polled up to 6 s (the layer's spring and a loaded Mac), short CDP timeouts.
recents() { CDP_TIMEOUT_S=10 ev '!!document.querySelector(".recents.open")'; }
waitrec() { local v i; for i in 1 2 3 4; do v=$(recents); [ "$v" = "$1" ] && break; sleep 1; done; echo "$v"; }
ET=""; wwc_extra() { [ -n "$ET" ] && hcall tasks.remove "[$ET]" "()=>'ok'" >/dev/null; ET=""; }
wwc_start
a=$(wwc_pick kate dolphin) || wwc_skip "Kate and Dolphin both run (the user's)"
sh_ "input keyevent KEYCODE_APP_SWITCH"; sleep 1
if [ "$(waitrec true)" = true ]; then
  wwc_open "$a" && sleep 1
  [ "$(waitrec false)" = false ] || bad "switcher: still open after $a's window came ($(swlog))"
  case $(swlog) in *"switcher up"*) bad "switcher: the window log's last line says up: $(swlog)" ;; esac
  [ -n "$WID" ] && { [ "$(wwbar "$WID")" = true ] || bad "switcher: $a's window $WID shows no bar"; }
  say "switcher: after the launch recents=$(recents), $(swlog | cut -c1-120)"
else bad "switcher: KEYCODE_APP_SWITCH opened no .recents.open on home (page: $(recents || true), $(wwc_vis); $(top | cut -c1-120); $(swlog | cut -c1-100))"; fi
# The empty phase starts from home in front again (home-front.sh: no input).
wwc_home >/dev/null
b=$(wwc_pick dolphin kate) || wwc_skip "no second app the user isn't running"
sh_ "am start -n com.powos.app/andro.marchy.PowosWindowActivity >/dev/null"; sleep 2
t=$(top); ET=$(sed -nE 's/.* t([0-9]+)\}.*/\1/p' <<<"$t")
case $t in
  *PowosWindowActivity*)
    # Home first (adb, no page call): its page is hidden while the bare task covers it, and ww_open's wait for a web
    # window polls that page - the 11-10 03:35 run spent the rest of its budget there after Dolphin came up as a
    # window task of its own (powos-window://) instead of home's web window.
    bw=$(wwids "l:org.kde.$b"); MINE_P="$MINE_P $b"
    r=$(hcall apps.launch "['l:org.kde.$b']" "()=>'ok'"); [ "$r" = ok ] || bad "empty: apps.launch $b: $r"
    for _ in $(seq 15); do sleep 1; t=$(top); case $t in *HomeShell*) break ;; esac; done
    say "empty: front after $b's launch: $t"
    case $t in
      *HomeShell*)
        WID=$(wwnew 30 "$bw" "l:org.kde.$b" | head -1); [ -n "$WID" ] && MINE_W="$MINE_W $WID"
        if [ -z "$WID" ]; then bad "empty: home is in front but no $b web window came in 30 s"
        else [ "$(wwbar "$WID")" = true ] || bad "empty: $b's window $WID shows no bar"; fi ;;
      *) bad "empty: home isn't in front 15 s after $b's launch ($t)" ;;
    esac ;;
  *) say "empty: not judged - a bare PowosWindowActivity didn't stay in front ($t): nothing covers home" ;;
esac
wwc_end "a launch closed the switcher ($a) and came up over an empty window task ($b)"
