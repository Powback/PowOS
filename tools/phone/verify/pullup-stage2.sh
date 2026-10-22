#!/bin/bash
# Two-stage pull-up (board launcher-pull-further-up-search-keyboard, shell/ui/overpull.ts) on the phone, in a free
# window (run by queue.sh with LOCK_HELD=1). A read-only recorder on home (event listeners only: touchend, focusin,
# the bridge's keyboard insets) times release -> focus -> keyboard. Then, with injected fingers:
#   1. a plain swipe up: the drawer opens, no keyboard (stage 1);
#   2. a long pull held at two heights: the content's lift follows the finger (rubber band), let go: search focused,
#      keyboard up; release -> focus and release -> first keyboard inset measured;
#   3. the drawer open, its list flung to the end, up again: search + keyboard the same way.
# Back closes the keyboard and the drawer after each. Nothing persistent changes.
set -u
cd "$(dirname "$0")/../../.." || exit 1
p=tools/phone
[ -n "${LOCK_HELD:-}" ] || { echo "pullup-stage2: run it through tools/phone/verify/queue.sh add"; exit 3; }
fg=$($p/adb.sh shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "pullup-stage2: home isn't in front"; exit 3; }
ev() { $p/cdp.sh eval home "$1" | tr -d '\\' | sed 's/^"//; s/"$//'; }
[ "$(ev 'fetch("ui/overpull.ts").then(r=>r.ok)')" = true ] || { echo "FAIL pullup-stage2: the phone serves no ui/overpull.ts"; exit 1; }
ev '(async () => { if (window.__pullRec) return "had"; const r = (window.__pullRec = { end: 0, focus: 0, kb: 0 }); const B = await importShim("./bridge.ts");
  document.addEventListener("touchend", () => Object.assign(r, { end: performance.now(), focus: 0, kb: 0 }), true);
  document.addEventListener("focusin", () => r.focus || (r.focus = performance.now()), true);
  B.powos.on("keyboard.inset", (px) => px > 0 && !r.kb && (r.kb = performance.now()));
  B.powos.on("system.insets", (i) => i && i.keyboard > 0 && !r.kb && (r.kb = performance.now())); return "on"; })()' >/dev/null
read -r W H < <(ev 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)')
X=$((W * 3 / 4))
state='JSON.stringify({open: !!document.querySelector(".home.open"), focus: !!document.activeElement?.matches?.(".home > .bar textarea"), lift: Math.round(new DOMMatrix(getComputedStyle(document.querySelector(".launcher-inner")).transform).m42), r: window.__pullRec})'
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

# 2. long pull, held at two heights
$p/adb.sh shell input motionevent DOWN "$X" $((H * 88 / 100))
for f in 80 72 64 56 48; do $p/adb.sh shell input motionevent MOVE "$X" $((H * f / 100)); done
a=$(ev "$state")
for f in 40 32 26; do $p/adb.sh shell input motionevent MOVE "$X" $((H * f / 100)); done
b=$(ev "$state")
$p/adb.sh shell input motionevent UP "$X" $((H * 26 / 100))
sleep 1
s2=$(ev "$state"); k2=$(ime)
shot=$HOME/.cache/pullup-stage2/device-stage2.png; mkdir -p "$(dirname "$shot")"
$p/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
la=$(sed -n 's/.*"lift":\(-*[0-9]*\).*/\1/p' <<<"$a"); lb=$(sed -n 's/.*"lift":\(-*[0-9]*\).*/\1/p' <<<"$b")
[ "${la:-0}" -lt 0 ] && [ "${lb:-0}" -lt "${la:-0}" ] || fails+=("rubber band doesn't follow the finger (lift $la then $lb px)")
grep -q '"focus":true' <<<"$s2" && [[ "$k2" == *true* ]] || fails+=("long pull: no search + keyboard ($k2)")
t2=$(ev '(() => { const r = window.__pullRec; return Math.round(r.focus - r.end) + " " + (r.kb ? Math.round(r.kb - r.end) : -1); })()')
back; back

# 3. open, list flung to its end, up again
$p/adb.sh shell input swipe "$X" $((H * 85 / 100)) "$X" $((H * 62 / 100)) 250
sleep 0.8
for _ in 1 2 3 4; do $p/adb.sh shell input swipe "$X" $((H * 75 / 100)) "$X" $((H * 25 / 100)) 80; done
sleep 1.5
end=$(ev '(() => { const l = document.querySelector(".drawer-list"); return l ? (l.scrollTop + l.clientHeight >= l.scrollHeight - 1) : "none"; })()')
$p/adb.sh shell input motionevent DOWN "$X" $((H * 70 / 100))
for f in 62 54 46 38 30; do $p/adb.sh shell input motionevent MOVE "$X" $((H * f / 100)); done
$p/adb.sh shell input motionevent UP "$X" $((H * 30 / 100))
sleep 1
s3=$(ev "$state"); k3=$(ime)
t3=$(ev '(() => { const r = window.__pullRec; return Math.round(r.focus - r.end) + " " + (r.kb ? Math.round(r.kb - r.end) : -1); })()')
[ "$end" = true ] || fails+=("couldn't fling the list to its end ($end)")
grep -q '"focus":true' <<<"$s3" && [[ "$k3" == *true* ]] || fails+=("up at the list's end: no search + keyboard ($k3)")
back; back

echo "pullup-stage2: plain=$s1 $k1 | held=$a then $b | long=$s2 $k2 release->focus,keyboard ms: $t2 | end=$end $s3 $k3 ms: $t3 | shot=$shot"
if [ ${#fails[@]} -eq 0 ]; then
  echo "PASS pullup-stage2: plain swipe no keyboard; pull further: lift ${la}->${lb}px, search+keyboard (release->focus,inset ms: $t2; at list end: $t3)"
else
  echo "FAIL pullup-stage2: ${fails[*]}"
fi
