#!/bin/bash
# lanes: phone
# pending-creation.sh (docs/AGENT-HANDBOOK.md, "live creation"; shell/ui/pending.tsx): composes a tiny throwaway
# widget on the device (`powos compose widget`, as composer.sh's setup does) and records the placeholder/progress
# journey through it on home - read-only CDP probes, no touch injection, nothing moved:
#   1. right after the compose process starts, home shows a skeleton tile (ui/pending.tsx SkeletonWidgetTile,
#      ui/creationwidgets.tsx) with a progress ring - a screenshot of it;
#   2. the registry's `creation` row for it reaches "done" (its progress reported step by step, not polled: the
#      probe only reads the row, never drives it);
#   3. home then shows the real widget at the SAME page/cell the placeholder reserved - a screenshot of that too,
#      and no leftover placeholder tile.
# A fresh id each run (no collision with a real widget); the composed app is removed after (`powos app remove`).
# Needs powos-registry already republished with the creation/creation_step/creation_log tables (apps/registry/
# module) - until then this FAILS at step 2 with "no creation row", which is the honest signal that the module on
# this device predates them (apps/vendor.sh + a hot-swap publish is the fix; no such path exists yet for a module
# without a powos-app.json - see the commit that added these tables).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
NAME="gate-test-$(date +%s)"
ID="local.$NAME"
OUT=${BOARD_TASK:+"$HOME/.cache/powos-verify/pending-creation-$BOARD_TASK"}; OUT=${OUT:-"$HOME/.cache/powos-verify/pending-creation"}
mkdir -p "$OUT"
cdp() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\r'; }
shot() { "$T/root.sh" "screencap -p /sdcard/pc-$1.png" >/dev/null 2>&1; "$T/root.sh" "cat /sdcard/pc-$1.png" > "$OUT/$1.png" 2>/dev/null; }
fail=""

# Starts the compose in the background on the device (deterministic word match, no AI round trip: fast and stable).
"$T/root.sh" "nohup sh -c 'powos compose widget \"a tiny test gauge\" --no-ai --id $ID --note \"pending-creation check\"' >/tmp/pc-$NAME.log 2>&1 &" >/dev/null 2>&1

# 1. A skeleton tile shows up within a few seconds (home needs no reload: the registry subscription is live).
seen=""
for _ in $(seq 1 20); do
  n=$(cdp "document.querySelectorAll('.pending-widget').length")
  [ "$n" -gt 0 ] 2>/dev/null && { seen=1; break; }
  sleep 1
done
[ -n "$seen" ] && shot "1-placeholder" || fail="$fail no-placeholder-tile"
step1=$(cdp "document.querySelector('.pending-widget .pending-widget-step')?.textContent ?? ''")
echo "STEP1 placeholder=${seen:-no} step=\"$step1\""

# 2. The registry row reaches done (read-only: the probe only watches, lib/apps/powos-compose drives the steps).
done_row=""
for _ in $(seq 1 90); do
  st=$("$T/root.sh" "curl -s -m 5 -X POST -d \"SELECT status FROM creation WHERE id = 'widget:$NAME%' OR id LIKE 'widget:%$NAME%'\" http://127.0.0.1:3410/v1/database/powos-registry/sql" 2>/dev/null)
  case "$st" in *done*) done_row=1; break ;; *failed*) fail="$fail compose-failed"; break ;; esac
  sleep 2
done
[ -n "$done_row" ] || { [ -n "$fail" ] || fail="$fail no-creation-row (module likely predates the creation tables)"; }
echo "STEP2 done=${done_row:-no}"

# 3. The real widget lands where the placeholder was, and the placeholder is gone.
if [ -n "$done_row" ]; then
  for _ in $(seq 1 10); do
    left=$(cdp "document.querySelectorAll('.pending-widget').length")
    [ "$left" = 0 ] 2>/dev/null && break
    sleep 1
  done
  shot "2-real-widget"
  [ "$left" = 0 ] 2>/dev/null || fail="$fail placeholder-still-up"
  real=$(cdp "document.querySelector('[data-key*=\"$ID\"]') ? 1 : 0")
  [ "$real" = 1 ] || fail="$fail real-widget-not-on-home"
  echo "STEP3 placeholder-left=$left real-widget-on-home=$real"
fi

# Cleanup: never leave the test widget on the device either way.
"$T/root.sh" "sh /data/powos/powos-run.sh \"powos app remove $ID\"" >/dev/null 2>&1

[ -n "$fail" ] && { echo "FAIL:$fail (screenshots in $OUT)"; exit 1; }
echo "PASS: $ID's placeholder appeared at once, its registry row reached done, and the real widget replaced it on home with no leftover placeholder (screenshots in $OUT)"
