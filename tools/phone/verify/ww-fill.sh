#!/bin/bash
# lanes: phone
# screen: inner
# tools/phone/verify/ww-fill.sh: every Android web window's app fills its window's body - read-only (no input, nothing
# opened or closed). Board "Hosted app window content is offset inside its frame": with freeform support on
# (global enable_freeform_support=1) a task launched onto a web window's display got its freeform launch bounds -
# centred, a status bar's height down - so PowTerm's content sat +188,+116 device px inside the body and was cut at
# the frame's right and bottom. WebWindowLaunch.fillDisplay launches full screen; WebWindows.fillDisplay corrects a
# task that kept its freeform mode.
#
#   ww-fill.sh   PASS: every root task on a powos-ww-* display is mode=fullscreen
#                FAIL: one is freeform / any other mode (its bounds printed)
#                SKIP (exit 3): no web window display open now
set -uo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
adb="$T/adb.sh"

displays=$("$adb" shell 'dumpsys display' | tr -d '\r' | grep -oE 'mBaseDisplayInfo=DisplayInfo\{"powos-ww-[^"]*", displayId [0-9]+' | grep -oE '[0-9]+$' | sort -u)
[ -n "$displays" ] || { echo "SKIP no web window display (powos-ww-*) open now"; exit 3; }

tasks=$("$adb" shell 'dumpsys activity activities' | tr -d '\r')
fail=0 n=0
for d in $displays; do
  # The display's block: from "Display #d" to the next "Display #" header; its root tasks are the "  * Task{" lines.
  block=$(printf '%s\n' "$tasks" | awk -v h="Display #$d " 'index($0,h)==1{on=1;next} /^Display #/{on=0} on')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    id=$(printf '%s' "$line" | grep -oE '#[0-9]+' | head -1)
    mode=$(printf '%s' "$line" | grep -oE 'mode=[a-z-]+' | cut -d= -f2)
    pkg=$(printf '%s' "$line" | grep -oE 'A=[0-9]+:[^ ]+' | cut -d: -f2)
    if [ "$mode" = fullscreen ]; then
      echo "ok   display $d task $id ($pkg): fullscreen"
    else
      echo "FAIL display $d task $id ($pkg): mode=$mode - its content is offset inside the window's body"
      fail=1
    fi
  done < <(printf '%s\n' "$block" | grep -E '^  \* Task\{')
done
[ "$n" -gt 0 ] || { echo "SKIP web window displays ($displays) hold no task now"; exit 3; }
[ "$fail" = 0 ] && echo "PASS every task on a web window display fills it ($n)" || exit 1
