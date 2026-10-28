#!/bin/bash
# lanes: phone
# Home navigation: another page -> main page -> switcher. Dock drags never open panels.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
installed=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null)
if [ -z "$installed" ] || ! git -C "$here" diff --quiet "$installed" HEAD -- ":(top)targets/android/app"; then
  echo "SKIP: the Home gesture APK has not been installed yet"
  exit 3
fi
. "$here/e2e-lib.sh"
. "$here/window-lock.sh"
OUT=$HOME/.cache/powos-verify/home-repeat-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
window_lock home-repeat 120
export CDP_TIMEOUT_S=20
I0=$(irq)
oldpage=$(hpage)
[[ "$oldpage" =~ ^-?[0-9]+$ ]] || exit 1
restore() {
  sh_ 'input keyevent BACK' >/dev/null
  ev "importShim('./state.ts').then(s=>{s.page.value=$oldpage;s.dockTry.value='';return 'restored'})" >/dev/null
  sh_ 'cmd device_state state reset' >/dev/null
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
sh_ 'cmd device_state state 0; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null'
sleep 3
chk home
# AI is a real non-main page even for a home with only one populated apps page.
ev 'importShim("./state.ts").then(s=>{s.goHome();s.page.value=-1;s.dockTry.value="bottom";return "set"})' >/dev/null
sleep 1
read -r x y end <<<"$(ev '[innerWidth/2,innerHeight-3,innerHeight-220].map(n=>Math.round(n*devicePixelRatio)).join(" ")')"
sh_ "input swipe $x $y $x $end 150"
sleep 2
chk first-home
[ "$(hpage)" = 0 ] || { echo 'FAIL: Home swipe did not return to main page'; exit 1; }
[ "$(ev 'document.querySelector(".recents")?.classList.contains("open") || false')" = false ] || { echo 'FAIL: first Home swipe opened switcher instead of main page'; exit 1; }
sh_ "input swipe $x $y $x $end 150"
sleep 2
chk repeat-home
[ "$(ev 'document.querySelector(".recents")?.classList.contains("open") || false')" = true ] || {
  "$T/shot.sh" "$OUT/repeat-home-fail.png" >/dev/null 2>&1; sh_ 'dumpsys window windows' | grep -E 'mCurrentFocus|mFocusedApp' > "$OUT/focus.txt"
  echo "FAIL: repeated Home swipe did not open switcher (page $(hpage); screenshot $OUT/repeat-home-fail.png, focus $OUT/focus.txt: $(head -c 160 "$OUT/focus.txt" | tr '\n' ' '))"; exit 1; }
"$T/shot.sh" "$OUT/switcher.png" >/dev/null || exit 1
sh_ 'input keyevent BACK'
sleep 1
read -r x y <<<"$(ev '(()=>{const r=document.querySelector(".home>.dock").getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2].map(n=>Math.round(n*devicePixelRatio)).join(" ")})()')"
for offset in -250 250; do
  sh_ "input swipe $x $y $x $((y+offset)) 400"
  sleep 1
  chk bottom-dock
  [ "$(ev 'importShim("./state.ts").then(s=>String(s.drawer.value!==0||s.notif.value))')" = false ] || { echo 'FAIL: bottom dock opened launcher/shade'; exit 1; }
  if sh_ 'dumpsys window windows' | grep mCurrentFocus | grep -q 'PowOS shade'; then echo 'FAIL: bottom dock opened native shade'; exit 1; fi
done
echo "PASS: Home returns to main page then opens switcher; bottom dock gestures stay isolated. Visual: $OUT/switcher.png"
