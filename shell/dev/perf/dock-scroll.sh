#!/bin/bash
# The dock's recent apps scroll with the finger, on the phone, in ONE free window: a sideways swipe on the dock's
# row, the scroll read before and after, the apps' widths against the dock's, a screencap (into $HOME/.cache/powos-gate),
# then a swipe back. Takes the verify lock (one injected-touch test at a time); temporary UI closed first with Back.
#   shell/dev/perf/dock-scroll.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
phone=$(cd "$here/../../../tools/phone" && pwd)
L=$HOME/.cache/powos-verify.lock; n=0
until mkdir "$L" 2>/dev/null; do
  [ $n -ge 120 ] && { echo "dock-scroll: verify lock busy for an hour"; exit 4; }
  n=$((n + 1)); sleep 30
done
echo "dock-scroll $(date +%T) (pid $$)" > "$L/who"; trap 'rm -rf "$L"' EXIT
AWAKE_ONLY=1 "$phone/idle.sh" --wait 120 7200 || { echo "dock-scroll: no free window"; exit 3; }
fg=$("$phone/adb.sh" shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "dock-scroll: home isn't in front"; exit 3; }
ready='(() => { const h = document.querySelector(".home"); return h.classList.contains("editing") ? "edit mode" : h.classList.contains("open") ? "drawer open" : document.querySelector(".menu, .folder-panel, .sheet:not(.pop)") ? "a menu, folder or sheet" : "ok"; })()'
for _ in 1 2 3 4; do
  state=$("$phone/cdp.sh" eval home "$ready" | tr -d '"')
  [ "$state" = ok ] && break
  "$phone/adb.sh" shell input keyevent 4; sleep 0.8
done
read_state='(() => { const d = document.querySelector(".dock-pages"); const a = document.querySelector(".dock-recent .app"); const b = d.getBoundingClientRect(); return [Math.round(d.scrollLeft), d.scrollWidth, d.clientWidth, Math.round(a.getBoundingClientRect().width), Math.round((b.top + b.height / 2) * devicePixelRatio), Math.round(b.width * devicePixelRatio)].join(" "); })()'
read -r s0 sw cw appw y w < <("$phone/cdp.sh" eval home "$read_state" | tr -d '"')
echo "dock: scrollWidth $sw > clientWidth $cw: $([ "$sw" -gt "$cw" ] && echo yes || echo NO); a recent app ${appw}px (a sixth of the dock: $(( (cw - 28) / 6 ))px); scrollLeft $s0"
"$phone/adb.sh" shell input swipe $((w * 85 / 100)) "$y" $((w * 15 / 100)) "$y" 250
sleep 1.2
read -r s1 _ < <("$phone/cdp.sh" eval home "$read_state" | tr -d '"')
echo "after a swipe left: scrollLeft $s1 ($([ "$s1" -gt "$s0" ] && echo scrolled || echo "did NOT scroll"))"
shot=$HOME/.cache/powos-gate/dock-scroll-$(date +%H%M%S).png
# Two displays (folded/unfolded): screencap warns first on stdout - the PNG is what follows its signature.
"$phone/adb.sh" exec-out screencap -p | python3 -c 'import sys; d = sys.stdin.buffer.read(); sys.stdout.buffer.write(d[d.find(b"\x89PNG"):])' > "$shot" && echo "screencap: $shot"
"$phone/adb.sh" shell input swipe $((w * 15 / 100)) "$y" $((w * 85 / 100)) "$y" 250
"$phone/adb.sh" shell input swipe $((w * 15 / 100)) "$y" $((w * 85 / 100)) "$y" 250
