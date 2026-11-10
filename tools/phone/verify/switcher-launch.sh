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
recents() { ev '!!document.querySelector(".recents.open")'; }
ET=""; wwc_extra() { [ -n "$ET" ] && hcall tasks.remove "[$ET]" "()=>'ok'" >/dev/null; ET=""; }
wwc_start
a=$(wwc_pick kate dolphin) || wwc_skip "Kate and Dolphin both run (the user's)"
sh_ "input keyevent KEYCODE_APP_SWITCH"; sleep 2
if [ "$(recents)" = true ]; then
  wwc_open "$a" && sleep 1
  [ "$(recents)" = false ] || bad "switcher: still open after $a's window came ($(swlog))"
  case $(swlog) in *"switcher up"*) bad "switcher: the window log's last line says up: $(swlog)" ;; esac
  [ -n "$WID" ] && { [ "$(wwbar "$WID")" = true ] || bad "switcher: $a's window $WID shows no bar"; }
  say "switcher: after the launch recents=$(recents), $(swlog | cut -c1-120)"
else bad "switcher: KEYCODE_APP_SWITCH opened no .recents.open on home"; fi
b=$(wwc_pick dolphin kate) || wwc_skip "no second app the user isn't running"
sh_ "am start -n com.powos.app/andro.marchy.PowosWindowActivity >/dev/null"; sleep 2
t=$(top); ET=$(sed -nE 's/.* t([0-9]+)\}.*/\1/p' <<<"$t")
case $t in
  *PowosWindowActivity*)
    wwc_open "$b" && sleep 1
    t=$(top); say "empty: front after $b's launch: $t"
    case $t in *HomeShell*) ;; *) bad "empty: home isn't in front after $b's window came ($t)" ;; esac
    [ -n "$WID" ] && { [ "$(wwbar "$WID")" = true ] || bad "empty: $b's window $WID shows no bar"; } ;;
  *) say "empty: not judged - a bare PowosWindowActivity didn't stay in front ($t): nothing covers home" ;;
esac
wwc_end "a launch closed the switcher ($a) and came up over an empty window task ($b)"
