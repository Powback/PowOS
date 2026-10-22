#!/bin/bash
# bf-launchpaths-phone.sh: (in the PowOS session as powos; bf-launchpaths.sh pushes and runs it) Broforce launched
# (or brought up) through the drawer's path, then for the drawer (--app-id <.desktop id>) and the games widget
# (--app-id steam_app_<appid>): frozen, then resumed by that path. Steps and asserts: bf-lib.sh. "RESULT ..." last.
set -uo pipefail
. /var/tmp/powos-bf-lib.sh
echo "== $(date +%T) steam=$(steam_pid) $(pacman -Q steam) reapers: $(reapers | tr '\n' ' ')"
powos sleep never --remove steam >/dev/null 2>&1  # the check needs Steam sleepable (bf-start.sh adds it)
step_launch || { close_mine; echo "RESULT bf-launchpaths: FAIL launch"; exit 1; }
desk=$(grep -lx "Exec=steam steam://rungameid/$APP" ~/.local/share/applications/*.desktop 2>/dev/null | head -1)
desk=$(basename "${desk:-Broforce.desktop}" .desktop)
res="launch ${LAUNCH}ms;"
for path in "drawer:$desk" "widget:steam_app_$APP"; do
  if step_freeze; then
    step_resume "${path%%:*}" open_task 40 "${path#*:}"
    res="$res ${path%%:*}: freeze ${FREEZE}ms, frame ${RES}ms;"
  else res="$res ${path%%:*}: not frozen;"; fi
  sleep 3
done
close_mine
echo "RESULT bf-launchpaths: ${FAILS:+FAIL$FAILS - }$res"
[ -z "$FAILS" ]
