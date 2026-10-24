#!/bin/bash
# lanes: emu phone
# shade-overpull.sh (Mac side, board "shade over-pull moves the whole panel"): opens the shade (an injected pull on
# the status bar's right half), then pulls further with a held finger (motionevents) and reads over CDP while it's
# held: what's under the control center (the notifications' header) must have moved down with the finger and more
# toggles than the row must show, the row itself in place. Let go past the threshold: the rest stays shown. Back
# closes it. Changes no setting (controls.layout is never touched). Exit 3 on a real touch.
set -u
cd "$(dirname "$0")/../../.." || exit 1
adb() { tools/phone/adb.sh "$@"; }
irq() { adb shell 'su -c "cat /proc/interrupts"' | awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}'; }
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "ABORT: real touch at $1"; adb shell input motionevent UP 1 1; adb shell input keyevent 4; exit 3; }; }
read -r W H < <(adb shell wm size | sed -nE 's/.*: ([0-9]+)x([0-9]+).*/\1 \2/p' | tail -1)
W=${W:-1116}; H=${H:-2484}
probe='JSON.stringify({v3:!!document.querySelector(".cc.v3"),whole:!!document.querySelector(".cc3-list.whole"),
peek:!!document.querySelector(".cc3-grid.cc-peek"),
under:Math.round(document.querySelector(".panel-body.together .cc ~ .notif-bar")?.getBoundingClientRect().top??-1),
row:[...document.querySelectorAll(".cc3-list .cc3-cell")].slice(0,6).map(e=>Math.round(e.getBoundingClientRect().y)).join("_"),
shown:[...document.querySelectorAll(".cc3-list .cc3-cell")].filter(e=>e.getBoundingClientRect().height>0&&+getComputedStyle(e).opacity>0.05).length})'
val() { sed -nE "s/.*\"$1\":\"?([^,\"}]*).*/\1/p" <<<"$2"; }
adb shell cmd statusbar collapse; sleep 0.3
adb shell input swipe $((W * 800 / 1000)) 8 $((W * 800 / 1000)) $((H * 600 / 1000)) 350; sleep 1.5; chk open
a=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
X=$((W / 2)); Y=$((H * 45 / 100)); S=$((H / 100))
adb shell "input motionevent DOWN $X $Y; for i in 1 2 3 4 5 6; do input motionevent MOVE $X \$(($Y + i*$S)); sleep 0.03; done"
sleep 0.4
m=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
adb shell "for i in 7 8 9 10 11 12 13 14; do input motionevent MOVE $X \$(($Y + i*$S)); sleep 0.03; done; input motionevent UP $X $(($Y + 14 * S))"
sleep 1.2; chk pull
b=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
adb shell input keyevent 4; sleep 0.5; adb shell input keyevent 4
echo "shade-overpull: open=$a held=$m after=$b"
fail=
grep -q '"v3":true' <<<"$a" || fail="$fail not-v3"
ua=$(val under "$a"); um=$(val under "$m")
[ -n "$ua" ] && [ -n "$um" ] && [ $((um - ua)) -ge 20 ] || fail="$fail under-didnt-follow($ua->$um)"
[ "$(val shown "$m")" -gt "$(val shown "$a")" ] 2>/dev/null || fail="$fail rest-not-revealing"
[ "$(val row "$a")" = "$(val row "$m")" ] || fail="$fail row-moved-while-held"
grep -q '"whole":true' <<<"$b" || fail="$fail not-shown-after-let-go"
[ "$(val row "$a")" = "$(val row "$b")" ] || fail="$fail row-moved"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: held, the notifications moved $((um - ua)) px with the finger and $(val shown "$m") toggles showed; let go, the rest stays, the row in place"
