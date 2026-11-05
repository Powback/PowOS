#!/bin/bash
# lanes: phone
# direct-scanout-on.sh <check> [args...]: (Mac; queue it: queue.sh add <task> tools/phone/verify/direct-scanout-on.sh
# bf-quiet.sh 600) runs a tools/phone/verify check with window-task direct scanout ON (docs/research/window-task-
# direct-scanout.md step 5): `setprop debug.powos.direct_scanout 1` before, its previous value back on ANY exit (never
# left on - the default stays the composited path). The app reads the property at each window-task connect, so it
# only counts for a game the check starts itself (bf-quiet/bf-pacing/bf-checker cold-start Broforce; a Broforce
# already running when this starts is still composited - said so, not counted as evidence).
# Needs kwin 3.66+ (0058: KWin sends direct frames) and an APK with direct_scanout.c (agent/direct-scanout-1).
# After the check, from KWin's session log since the start: the "direct scanout offered/refused" lines, the sum of
# the "direct sent N" counts over the "draw:" lines vs the frames drawn, and the app's "direct:" logcat lines
# (self-test, refusals). Last line: "direct <sent>/<frames> frames sent direct" + the check's own result line.
# Exit: the check's exit code; 1 (FAIL) when the check passed but no frame went direct (the A/B measured nothing).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A=$T/adb.sh
[ $# -ge 1 ] || { echo "usage: direct-scanout-on.sh <check> [args...]"; exit 2; }
chk=$1; shift
case $chk in /*) ;; */*) chk=$here/../../../$chk ;; *) chk=$here/$chk ;; esac
[ -x "$chk" ] || { echo "ENV: no check $chk"; exit 5; }
LOG=/data/powos/root/run/powos-app/hyprland.log
prev=$("$A" shell getprop debug.powos.direct_scanout | tr -d '\r')
reset() { "$A" shell "setprop debug.powos.direct_scanout '${prev:-0}'" >/dev/null 2>&1
  echo "debug.powos.direct_scanout back to '$("$A" shell getprop debug.powos.direct_scanout | tr -d '\r')'"; }
trap reset EXIT
"$A" shell "setprop debug.powos.direct_scanout 1" || { echo "ENV: setprop failed"; exit 5; }
k0=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
lt=$("$A" shell "date '+%m-%d %H:%M:%S.000'" | tr -d '\r')
echo "direct scanout ON (was '${prev}'), running $(basename "$chk") $*"
"$chk" "$@"; rc=$?
k1=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
klog=$("$A" shell "su -c 'sed -n \"$((${k0:-0} + 1)),${k1:-0}p\" $LOG'" | tr -d '\r')
echo "$klog" | grep -E 'direct scanout (offered|refused)' | sed 's/^/kwin /' | tail -5
"$A" shell "logcat -d -T '$lt'" | tr -d '\r' | grep -E 'direct: |direct scanout' | sed 's/^/app /' | tail -8
sum=$(echo "$klog" | grep -E 'window task .* draw:' | sed -nE 's/.*direct-eligible [0-9]+\/([0-9]+).*direct sent ([0-9]+).*/\1 \2/p' |
  awk '{f+=$1; s+=$2} END{printf "%d %d", s, f}')
sent=${sum% *}; frames=${sum#* }
echo "direct ${sent:-0}/${frames:-0} frames sent direct (check rc=$rc)"
if [ "$rc" = 0 ] && [ "${sent:-0}" -eq 0 ]; then
  echo "FAIL no frame went direct (kwin < 3.66, an APK without direct_scanout.c, or a game already running before)"
  exit 1
fi
exit "$rc"
