#!/bin/sh
# The phone's PowOS updates as the PowOS app runs them (docs/PHONE-UPDATES.md): the app (APK), the home screen (the
# shell bundle) and the Linux image (lib/phone-update.sh), one run the app makes. A phone's image isn't bootc, so the
# Linux side (`powos update status|now`, the desktop's update widget com.powos.updates) reads the app's state and asks
# the app for a run instead (11-14: the widget said "not a bootc deployment" on the razr):
#   status [--json]  run/powos-updates.json, written by the app (PowosUpdates.publish): versions, last check, result,
#                    what waits on a tap; --json prints it as is (the widget's source)
#   now              asks the app for its run (android-request "update now"); progress in the same file + its notification
# Exit 3: the app hasn't published its state / doesn't take "update" (an app older than this); 4: a rooted phone, which
# the ship service updates (no app run).
# POWOS_APP_RUN: the app's run dir (default: XDG_RUNTIME_DIR, the app's files/run on both kinds of phone).
RUN=${POWOS_APP_RUN:-${XDG_RUNTIME_DIR:-/run/powos-app}}
STATE=$RUN/powos-updates.json

field() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2])
print("\n".join(v) if isinstance(v,list) else ("" if v is None else str(v).lower() if isinstance(v,bool) else v))' "$STATE" "$1" 2>/dev/null; }

ago() {
  [ -n "$1" ] || { echo "never"; return; }
  s=$(( ($(date +%s) - $1 / 1000) / 60 ))
  if [ "$s" -lt 1 ]; then echo "just now"; elif [ "$s" -lt 60 ]; then echo "${s}m ago"
  elif [ "$s" -lt 2880 ]; then echo "$((s / 60))h ago"; else echo "$((s / 1440))d ago"; fi
}

status() {
  if [ ! -s "$STATE" ]; then
    echo "The PowOS app hasn't reported its update state (no $STATE) - update the app from its Settings > system updates." >&2
    return 3
  fi
  [ "${1:-}" = --json ] && { cat "$STATE"; echo; return 0; }
  core=$(pacman -Q powos-core 2>/dev/null | cut -d' ' -f2)
  echo "PowOS updates (run by the PowOS app)"
  echo "  app:          $(field app)"
  echo "  home screen:  $(field shell)"
  echo "  linux:        powos-core ${core:-not installed}"
  if [ "$(field via)" = ship ]; then
    echo "  updated by:   your PowStation's ship service (rooted phone)"
    return 0
  fi
  if [ "$(field checking)" = true ]; then echo "  now:          checking for updates..."; fi
  echo "  last check:   $(ago "$(field checked)")"
  r=$(field summary); [ -n "$r" ] && echo "  result:       $r"
  e=$(field error); [ -n "$e" ] && echo "  problem:      $e"
  field waiting | while IFS= read -r w; do [ -n "$w" ] && echo "  waiting:      $w"; done
  return 0
}

now() {
  if ! grep -qx update "$RUN/android-request.verbs" 2>/dev/null; then
    echo "This PowOS app doesn't take update requests yet - open its Settings > system updates > check for updates." >&2
    return 3
  fi
  if [ "$(field via)" = ship ]; then
    echo "This phone is rooted: your PowStation's ship service keeps it updated." >&2
    return 4
  fi
  if command -v android-request >/dev/null 2>&1; then
    android-request update now
  else # the helper writes the same file, by rename
    printf 'update now\n' > "$RUN/android-request.tmp" && mv -f "$RUN/android-request.tmp" "$RUN/android-request"
  fi || return 1
  echo "Asked the PowOS app to update (the app, the home screen, Linux) - follow it with: powos update status"
}

case "${1:-status}" in
  status) [ $# -gt 0 ] && shift; status "$@" ;;
  now|check) now ;;
  *) echo "usage: phone-app-updates.sh {status [--json]|now}" >&2; exit 2 ;;
esac
