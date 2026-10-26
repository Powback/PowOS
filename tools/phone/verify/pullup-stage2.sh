#!/bin/bash
# lanes: emu phone
# Two-stage pull-up (board launcher-pull-further-up-search-keyboard, shell/ui/overpull.ts) on the phone, in a free
# window (run by queue.sh with LOCK_HELD=1). A read-only recorder on home (event listeners only: touchstart, touchend,
# focusin, the bridge's keyboard insets) times the pull's start -> focus -> keyboard -> release. Then, injected fingers:
#   1. a plain swipe up: the drawer opens, no keyboard (stage 1);
#   2. a long pull held at two heights: the content's lift follows the finger (rubber band); past the threshold, the
#      finger STILL DOWN: search focused and the keyboard up (mInputShown) - before the UP; let go: both stay;
#   3. the same pull past the threshold, then back below it, still held: the keyboard down and nothing focused; let go:
#      still no keyboard (the drawer goes the way the finger last moved);
#   4. the drawer open, its list at its end (the A-Z bar's last letter), up again: search + keyboard.
# Back closes the keyboard and the drawer after each. Nothing persistent changes.
set -u
cd "$(dirname "$0")/../../.." || exit 1
p=tools/phone
[ -n "${LOCK_HELD:-}" ] || { echo "pullup-stage2: run it through tools/phone/verify/queue.sh add"; exit 3; }
fg=$($p/adb.sh shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "pullup-stage2: home isn't in front"; exit 3; }
ev() { $p/cdp.sh eval home "$1" | tr -d '\\' | sed 's/^"//; s/"$//'; }
[ "$(ev 'fetch("ui/overpull.ts").then(r=>r.ok)')" = true ] || { echo "FAIL pullup-stage2: the phone serves no ui/overpull.ts"; exit 1; }
ev '(async () => { if (window.__pullRec2) return "had"; const r = (window.__pullRec2 = { start: 0, end: 0, focus: 0, kb: 0 }); const B = await importShim("./bridge.ts");
  document.addEventListener("touchstart", () => Object.assign(r, { start: performance.now(), end: 0, focus: 0, kb: 0 }), true);
  document.addEventListener("touchend", () => r.end || (r.end = performance.now()), true);
  document.addEventListener("focusin", () => r.focus || (r.focus = performance.now()), true);
  B.powos.on("keyboard.inset", (px) => px > 0 && !r.kb && (r.kb = performance.now()));
  B.powos.on("system.insets", (i) => i && i.keyboard > 0 && !r.kb && (r.kb = performance.now())); return "on"; })()' >/dev/null
read -r W H < <(ev 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)')
X=$((W * 3 / 4))
state='JSON.stringify({open: !!document.querySelector(".home.open"), focus: !!document.activeElement?.matches?.(".home > .bar textarea"), lift: Math.round(new DOMMatrix(getComputedStyle(document.querySelector(".launcher-inner")).transform).m42), r: window.__pullRec2})'
times='(() => { const r = window.__pullRec2, t = (v) => (v ? Math.round(v - r.start) : -1); return t(r.focus) + " " + t(r.kb) + " " + t(r.end); })()'
ime() { $p/adb.sh shell "dumpsys input_method | grep -m1 -o 'mInputShown=[a-z]*'"; }
back() { $p/adb.sh shell input keyevent 4; sleep 0.6; }
fails=()

# 1. plain swipe
$p/adb.sh shell input swipe "$X" $((H * 85 / 100)) "$X" $((H * 62 / 100)) 250
sleep 1
s1=$(ev "$state"); k1=$(ime)
grep -q '"open":true' <<<"$s1" || fails+=("plain swipe: drawer not open")
grep -q '"focus":false' <<<"$s1" && [[ "$k1" == *false* ]] || fails+=("plain swipe raised the keyboard ($k1)")
back

# 2. long pull, held at two heights. It starts from a spot that is always free (footpt.js: a gap in the dock's or the
# bottom bar's row, right half, never an icon or the pill) - with windows open home has no empty spot above (e2e
# 15:11), and a DOWN on an icon held until the next adb call is its long press. The DOWN and its first moves go in ONE
# phone call; each later call is a burst of moves, the holds between them the finger held at a height.
read -r X Y0 < <(ev "$(cat tools/phone/verify/footpt.js)")
[ "${Y0:-0}" -gt 0 ] 2>/dev/null || { echo "pullup-stage2: no free spot in the dock's or the bar's row ($X)"; exit 3; }
mv() { local c="" f; for f in "$@"; do c+="input motionevent MOVE $X $((Y0 - H * f / 100)); "; done; $p/adb.sh shell "$c"; }
$p/adb.sh shell "input motionevent DOWN $X $Y0; input motionevent MOVE $X $((Y0 - H * 3 / 100))"
mv 8 14 20 26 32
a=$(ev "$state")
mv 38 44 48
sleep 0.8
b=$(ev "$state"); kb=$(ime)
$p/adb.sh shell input motionevent UP "$X" $((Y0 - H * 48 / 100))
sleep 1
s2=$(ev "$state"); k2=$(ime)
shot=$HOME/.cache/pullup-stage2/device-stage2.png; mkdir -p "$(dirname "$shot")"
$p/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
la=$(sed -n 's/.*"lift":\(-*[0-9]*\).*/\1/p' <<<"$a"); lb=$(sed -n 's/.*"lift":\(-*[0-9]*\).*/\1/p' <<<"$b")
[ "${la:-0}" -lt 0 ] && [ "${lb:-0}" -lt "${la:-0}" ] || fails+=("rubber band doesn't follow the finger (lift $la then $lb px)")
grep -q '"focus":true' <<<"$b" && [[ "$kb" == *true* ]] || fails+=("held past the threshold: no search + keyboard before the release ($kb)")
grep -q '"focus":true' <<<"$s2" && [[ "$k2" == *true* ]] || fails+=("long pull: no search + keyboard after the release ($k2)")
t2=$(ev "$times")
back; back

# 3. past the threshold, then back below it before letting go: cancelled (keyboard down, nothing focused), stage 1.
$p/adb.sh shell "input motionevent DOWN $X $Y0; input motionevent MOVE $X $((Y0 - H * 3 / 100))"
mv 10 20 30 40 48
sleep 0.8
c1=$(ev "$state"); kc1=$(ime)
mv 40 30 20
sleep 0.8
c2=$(ev "$state"); kc2=$(ime)
$p/adb.sh shell input motionevent UP "$X" $((Y0 - H * 20 / 100))
sleep 1
c3=$(ev "$state"); kc3=$(ime)
[[ "$kc1" == *true* ]] || fails+=("cancel: the keyboard wasn't up past the threshold ($kc1)")
grep -q '"focus":false' <<<"$c2" && [[ "$kc2" == *false* ]] || fails+=("cancel: back below the threshold, still focused or keyboard up ($kc2)")
# Let go after moving back down: the drawer follows that last motion (open or shut, gesture.ts's flick), never a keyboard.
grep -q '"focus":false' <<<"$c3" && [[ "$kc3" == *false* ]] || fails+=("cancel: let go, the search focused or the keyboard up ($kc3)")
back

# 4. open, the list at its end, up again
$p/adb.sh shell input swipe "$X" $((H * 85 / 100)) "$X" $((H * 62 / 100)) 250
sleep 0.8
# The list's end by its A-Z bar's last letter (a tap: jump() scrolls at once, clamped at the end). Not flings: each
# fling that starts at the end is itself the over-pull (search + keyboard) and the keyboard relaid the list (end=false,
# 2026-10-23).
lp=$(ev '(() => { const s = [...document.querySelectorAll(".drawer .letter-bar span")].pop(); if (!s) return "none"; const r = s.getBoundingClientRect(), d = devicePixelRatio; return Math.round((r.left + r.width / 2) * d) + " " + Math.round((r.top + r.height / 2) * d); })()')
[ "$lp" != none ] && $p/adb.sh shell input tap $lp
sleep 1.5
end=$(ev '(() => { const l = document.querySelector(".drawer-list"); return l ? (l.scrollTop + l.clientHeight >= l.scrollHeight - 1) : "none"; })()')
# One call: a DOWN on an app cell held until the next adb call would be its long press (menu / drag).
c="input motionevent DOWN $X $((H * 70 / 100)); "; for f in 62 54 46 38 30; do c+="input motionevent MOVE $X $((H * f / 100)); "; done
$p/adb.sh shell "$c input motionevent UP $X $((H * 30 / 100))"
sleep 1
s3=$(ev "$state"); k3=$(ime)
t3=$(ev "$times")
[ "$end" = true ] || fails+=("the list didn't reach its end ($end)")
grep -q '"focus":true' <<<"$s3" && [[ "$k3" == *true* ]] || fails+=("up at the list's end: no search + keyboard ($k3)")
back; back

echo "pullup-stage2: plain=$s1 $k1 | held=$a then $b $kb | long=$s2 $k2 start->focus,keyboard,release ms: $t2 | cancel=$kc1 / $c2 $kc2 / $c3 $kc3 | end=$end $s3 $k3 ms: $t3 | shot=$shot"
if [ ${#fails[@]} -eq 0 ]; then
  echo "PASS pullup-stage2: plain swipe no keyboard; held past the threshold: lift ${la}->${lb}px, search+keyboard before the release (start->focus,inset,release ms: $t2); back below it: cancelled; at list end: $t3"
else
  echo "FAIL pullup-stage2: ${fails[*]}"
fi
