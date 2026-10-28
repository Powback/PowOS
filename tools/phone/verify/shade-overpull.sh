#!/bin/bash
# lanes: emu phone
# shade-overpull.sh (Mac side, board "shade over-pull moves the whole panel"): opens the shade (an injected pull on
# the status bar's right half), then pulls further with a held finger (motionevents) and reads over CDP while it's
# held: on a narrow screen the notifications must move down with the finger; on a wide screen their separate column stays in place. More
# toggles than the row must show, the row itself in place. Let go past the threshold: the rest stays shown. Back
# closes it. Changes no setting (controls.layout is never touched). Exit 3 on a real touch.
set -u
cd "$(dirname "$0")/../../.." || exit 1
adb() { tools/phone/adb.sh "$@"; }
OUT=${OUT:-$HOME/.cache/powos-verify/shade-overpull-$(date +%m%d-%H%M%S)}
mkdir -p "$OUT"
shot() { tools/phone/shot.sh "$OUT/$1.png" >/dev/null 2>&1; }
irq() { adb shell 'su -c "cat /proc/interrupts"' | awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}'; }
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "ABORT: real touch at $1"; adb shell input motionevent UP 1 1; adb shell input keyevent 4; exit 3; }; }
read -r W H < <(adb shell wm size | sed -nE 's/.*: ([0-9]+)x([0-9]+).*/\1 \2/p' | tail -1)
W=${W:-1116}; H=${H:-2484}
probe='JSON.stringify({v3:!!document.querySelector(".cc.v3"),two:!!document.querySelector(".panel-body.two"),whole:!!document.querySelector(".cc3-list.whole"),
peek:!!document.querySelector(".cc3-grid.cc-peek"),
under:Math.round(document.querySelector(".panel-body.together .notif-own .notif-items")?.getBoundingClientRect().top??-1),
x:Math.round((document.querySelector(".cc > .notif-bar")?.getBoundingClientRect().x+document.querySelector(".cc > .notif-bar")?.getBoundingClientRect().width/2)*devicePixelRatio),
y:Math.round((document.querySelector(".cc > .notif-bar")?.getBoundingClientRect().y+document.querySelector(".cc > .notif-bar")?.getBoundingClientRect().height/2)*devicePixelRatio),
row:[...document.querySelectorAll(".cc3-list .cc3-cell")].slice(0,6).map(e=>Math.round(e.getBoundingClientRect().y)).join("_"),
shown:[...document.querySelectorAll(".cc3-list .cc3-cell")].filter(e=>e.getBoundingClientRect().height>0&&+getComputedStyle(e).opacity>0.05).length})'
val() { sed -nE "s/.*\"$1\":\"?([^,\"}]*).*/\1/p" <<<"$2"; }
adb shell cmd statusbar collapse; sleep 0.3
adb shell input swipe $((W * 800 / 1000)) 8 $((W * 800 / 1000)) $((H * 600 / 1000)) 350; sleep 1.5; chk open
shot open
a=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
# Start on the control center, not the gap between the unfolded shade's two columns.
X=$(val x "$a"); Y=$(val y "$a"); S=$((H / 100))
[[ "$X" =~ ^[0-9]+$ && "$Y" =~ ^[0-9]+$ ]] || { echo "FAIL: no control-center header: $a"; exit 1; }
adb shell "input motionevent DOWN $X $Y; for i in 1 2 3 4 5 6; do input motionevent MOVE $X \$(($Y + i*$S)); sleep 0.03; done"
sleep 0.4
shot held
m=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
adb shell "for i in 7 8 9 10 11 12 13 14; do input motionevent MOVE $X \$(($Y + i*$S)); sleep 0.03; done; input motionevent UP $X $(($Y + 14 * S))"
sleep 1.2; chk pull
shot expanded
b=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
adb shell input keyevent 4; sleep 0.5; adb shell input keyevent 4
echo "shade-overpull: open=$a held=$m after=$b; captures: $OUT"
fail=
grep -q '"v3":true' <<<"$a" || fail="$fail not-v3"
ua=$(val under "$a"); um=$(val under "$m")
if [ "$(val two "$a")" = true ]; then
  [ "${ua:--1}" -ge 0 ] && [ "$ua" = "$um" ] && [ "$ua" = "$(val under "$b")" ] || fail="$fail notifications-column-moved($ua->$um)"
else
  [ "${ua:--1}" -ge 0 ] && [ -n "$um" ] && [ $((um - ua)) -ge 20 ] || fail="$fail under-didnt-follow($ua->$um)"
fi
[ "$(val shown "$m")" -gt "$(val shown "$a")" ] 2>/dev/null || fail="$fail rest-not-revealing"
[ "$(val row "$a")" = "$(val row "$m")" ] || fail="$fail row-moved-while-held"
grep -q '"whole":true' <<<"$b" || fail="$fail not-shown-after-let-go"
[ "$(val row "$a")" = "$(val row "$b")" ] || fail="$fail row-moved"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: held, notifications moved $((um - ua)) px (two columns: $(val two "$a")) and $(val shown "$m") toggles showed; let go, the rest stays, the row in place"
