#!/bin/bash
# lanes: emu phone
# cc-toprow.sh (Mac side, board control-center-top-row-stays-put-on-expand-one-o): the control center on the phone -
# opens the shade (injected pull on the status bar's right half), reads the first six toggles' boxes over CDP, pulls
# further, reads again. PASS = v3, no section headings, the first six don't move (the saved order is printed
# from shell-data/controls.layout.json, read only). Back closes it. Changes no setting. Exit 3 on a real touch.
set -u
cd "$(dirname "$0")/../../.." || exit 1
adb() { tools/phone/adb.sh "$@"; }
irq() { adb shell 'su -c "cat /proc/interrupts"' | awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}'; }
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "ABORT: real touch at $1"; adb shell input keyevent 4; exit 3; }; }
read -r W H < <(adb shell wm size | sed -nE 's/.*: ([0-9]+)x([0-9]+).*/\1 \2/p' | tail -1)
W=${W:-1116}; H=${H:-2484}
probe='JSON.stringify({v3:!!document.querySelector(".cc.v3"),whole:!!document.querySelector(".cc3-list.whole"),
heads:document.querySelectorAll(".cc h3,.cc-sec,.cc-section,.cc3-head").length,
row:[...document.querySelectorAll(".cc3-list .cc3-cell")].slice(0,6).map(e=>{const r=e.getBoundingClientRect();return [e.querySelector("[aria-label]")?.getAttribute("aria-label")?.split(":")[0],Math.round(r.x),Math.round(r.y)]}),
shown:[...document.querySelectorAll(".cc3-list .cc3-cell")].filter(e=>e.getBoundingClientRect().height>0).length})'
adb shell cmd statusbar collapse; sleep 0.3
adb shell input swipe $((W * 800 / 1000)) 8 $((W * 800 / 1000)) $((H * 600 / 1000)) 350; sleep 1.5; chk open
a=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
adb shell input swipe $((W / 2)) $((H * 450 / 1000)) $((W / 2)) $((H * 750 / 1000)) 300; sleep 1.5; chk pull
b=$(tools/phone/cdp.sh eval shade "$probe" 2>&1 | tr -d '\\' | tail -1)
shot=$HOME/.cache/cc-toprow/device-cc.png; mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
adb shell input keyevent 4; sleep 0.5; adb shell input keyevent 4
saved=$(adb shell 'su -c "cat /data/data/com.powos.app/files/shell-data/controls.layout.json"' | tr -d '\r\\')
rowA=$(sed -nE 's/.*"row":(\[.*\]\]),.*/\1/p' <<<"$a"); rowB=$(sed -nE 's/.*"row":(\[.*\]\]),.*/\1/p' <<<"$b")
echo "cc-toprow: first=$a further=$b saved=${saved:0:80}... shot=$shot"
fail=
grep -q '"v3":true' <<<"$a" || fail="$fail not-v3"
grep -q '"heads":0' <<<"$b" || fail="$fail headings"
grep -q '"whole":true' <<<"$b" || fail="$fail no-further-pull"
[ -n "$rowA" ] && [ "$rowA" = "$rowB" ] || fail="$fail row-moved"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: v3, no headings, the top row in place on the further pull ($rowA)"
