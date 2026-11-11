#!/bin/bash
# lanes: phone
# screen: inner
# needs: kwin home
# ww-opens.sh: a Linux app's launch opens its window as a web window, never on the Plasma desktop (board task
# linux-app-opens-no-window-exists-in-kwin-but-nev, ccf90055: powos-open-task's "desktop" brought Plasma up over home
# and the window "stayed on the desktop", no layer). On the unfolded home, for each of Kate and Dolphin the user isn't
# running, launched through home's launch path (apps.launch, a tap's call):
#   window   a NEW web window of it, live (its app's frames, not the placeholder) within 45 s, its bar shown
#   layer    its powos-ww-<id>-linux layer in SurfaceFlinger
#   desktop  the Plasma desktop (andro.marchy.MainActivity) isn't the top resumed activity
# Closes what it opened. Exit 0 PASS, 1 FAIL, 3 not now.
set -uo pipefail
NAME=ww-opens; . "$(dirname "$0")/wwc-lib.sh"
top() { sh_ "dumpsys activity activities | grep -m1 topResumedActivity"; }
layer() { sh_ "dumpsys SurfaceFlinger --list" | grep -c "powos-ww-${1#w}-linux"; }
wwc_start
n=0
for a in kate dolphin; do
  ww_running "$a" && { say "$a: the user's $a runs - not opened over it"; continue; }
  n=$((n + 1)); wwc_open "$a" || continue; sleep 1.5
  [ "$(wwbar "$WID")" = true ] || bad "$a: window $WID shows no bar"
  [ "$(layer "$WID")" -ge 1 ] 2>/dev/null || bad "$a: window $WID has no powos-ww-${WID#w}-linux layer"
  t=$(top); case $t in *andro.marchy.MainActivity*) bad "$a: the Plasma desktop came to the front ($t)" ;; esac
  say "$a: $WID live, layer $(layer "$WID"), front: $(sed -E 's/.*\{[^ ]+ [^ ]+ ([^ ]+).*/\1/' <<<"$t")"
done
[ "$n" -gt 0 ] || wwc_skip "Kate and Dolphin both run (the user's)"
wwc_end "$n app(s) opened as live web windows with their layers, Plasma's desktop never in front"
