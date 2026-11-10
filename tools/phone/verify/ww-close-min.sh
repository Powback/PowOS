#!/bin/bash
# lanes: phone
# needs: kwin home
# ww-close-min.sh: a Linux web window's minimise and close work by touch (board task
# regression-linux-window-close-minimise-stopped-w: the close button and the dock tap stopped working). On the unfolded
# home, Kate (or Dolphin) opened through home's launch path, then real taps (Android `input tap`, never page events):
#   min      its bar's Minimise: the host lists it minimised and none of its frame shows within 3 s
#   dock     its dock cell: it shows again (floating) within 3 s (no cell for it on the dock: noted, not judged)
#   close    its bar's close (.ww-close): the host's list drops it within 5 s and the app's process ends within 10 s
# Opens only an app the user isn't running (and ends it after, whatever happened). Exit 0 PASS, 1 FAIL, 3 not now.
set -uo pipefail
NAME=ww-close-min; . "$(dirname "$0")/wwc-lib.sh"
dockel() { echo "[...document.querySelectorAll('.home .dock .app[data-key]')].find(a=>a.dataset.key.startsWith('$1'))"; }
dockpt() { ev "(()=>{const e=$(dockel "$1");if(!e)return '';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width/2)*d)+' '+Math.round((r.y+r.height/2)*d)})()"; }
until_() { local i; for i in $(seq 1 "$1"); do sleep 1; eval "$2" && return 0; done; return 1; }
wwc_start
a=$(wwc_pick kate dolphin) || wwc_skip "Kate and Dolphin both run (the user's)"
wwc_open "$a" || wwc_end; sleep 1
p=$(wwpt "$WID" ".ww-button[aria-label=Minimise]")
if [ -n "$p" ]; then sh_ "input tap $p"; say "min: tapped Minimise at $p"
  until_ 3 '[ "$(wwhost "$WID" state)" = minimised ] && [ -z "$(wwrect "$WID")" ]' ||
    bad "min: $WID still $(wwhost "$WID" state), frame '$(wwrect "$WID")' 3 s after its Minimise tap"
else bad "min: $WID has no Minimise button on screen"; fi
d=$(dockpt "l:org.kde.$a")
if [ -z "$d" ]; then say "dock: no dock cell for l:org.kde.$a - not judged"
else sh_ "input tap $d"; say "dock: tapped $a's cell at $d"
  until_ 3 '[ "$(wwhost "$WID" state)" = floating ] && [ -n "$(wwrect "$WID")" ]' ||
    bad "dock: $WID still $(wwhost "$WID" state) 3 s after its dock tap"; fi
# The close needs its bar on screen: still minimised (no dock cell, or the dock FAILed) -> shown by the page's own state.
[ -n "$(wwrect "$WID")" ] || { ev "importShim('./ui/webwindows.tsx').then(m=>{m.webWins.value=m.webWins.value.map(w=>w.id===${WID#w}?{...w,minimised:false}:w);return 'ok'})" >/dev/null; sleep 1.5; }
p=$(wwpt "$WID" .ww-close)
if [ -n "$p" ]; then sh_ "input tap $p"; say "close: tapped close at $p"
  until_ 5 '[ "$(wwhost "$WID" gone)" = true ]' || bad "close: $WID still listed ($(wwhost "$WID" state)) 5 s after its close tap"
  until_ 10 '! ww_running "$a"' || bad "close: $a still runs 10 s after its window's close"
else bad "close: $WID has no close button on screen"; fi
wwc_end "$a minimised by its button, back by its dock cell, closed by its button (window and process gone)"
