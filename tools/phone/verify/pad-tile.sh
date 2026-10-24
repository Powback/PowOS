#!/bin/bash
# lanes: phone
# pad-tile.sh [OUT] (Mac side; board "control centre: Controller overlay tile on/off"): the Controller tile in the
# control centre (shell/ui/padtile.ts, under the tools group of control.tsx) toggles the touch-controller overlay.
# Records pad.state(); opens the control centre (the shade's pull, as cc-toprow.sh does); asserts the tile is shown
# (the tools group is opened if it is folded); taps it: within 1 s pad.state() has flipped, timed from the tap's
# pointerdown in the page to the host's answer; taps again: back to the start. Closes the shade. The overlay ends in
# the state it started (restored in a trap). Changes no other setting.
# Exit 1 + "FAIL:" on a miss, 3 on a real touch (restored) or no window, 5 + "ENV:" when it can't run (screen off,
# no pad host, no shell page).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/pad-tile-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
q() { "$T/cdp.sh" eval shade "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
state() { q 'window.powos.pad.state().then(String, () => "err")'; }
flip() { [ "$1" = true ] && echo false || echo true; }
. "$here/window-lock.sh"; window_lock pad-tile 120 "${MAX_WAIT:-10800}"
restore() {
  if [ -n "${S0:-}" ] && [ "$(state)" != "$S0" ]; then q "window.powos.pad.overlay($S0).then(String)" >/dev/null; fi
  sh_ "cmd statusbar collapse; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
}
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0; S0=""; NEW=""
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; "$A" shell input motionevent CANCEL 1 1 >/dev/null 2>&1; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
f() { echo "$1" | awk -v i="$2" '{print $i}'; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "ENV: the screen is $s - not woken (rule); nothing done"; exit 5; }
sh_ "cmd statusbar collapse; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
S0=$(state)
case "$S0" in true | false) ;; *) echo "ENV: no pad host here (pad.state gave '$S0') - nothing to check"; exit 5 ;; esac
log "pad.state at start: $S0"
read -r W H < <(sh_ "wm size" | sed -nE 's/.*: ([0-9]+)x([0-9]+).*/\1 \2/p' | tail -1)
W=${W:-1116}; H=${H:-2484}

# The control centre: the shade's pull on the status bar's right half, then a pull on the page (cc-toprow.sh's gesture).
"$A" shell "cmd statusbar collapse" >/dev/null; sleep 0.3
"$A" shell input swipe $((W * 800 / 1000)) 8 $((W * 800 / 1000)) $((H * 600 / 1000)) 350; sleep 1.5; chk open
"$A" shell input swipe $((W / 2)) $((H * 450 / 1000)) $((W / 2)) $((H * 750 / 1000)) 300; sleep 1.5; chk pull

# The tile: its button (data-key powos.pad) and its label "controller: on|off", in device px.
TILE='(()=>{const e=document.querySelector("[data-key=\"powos.pad\"] button");if(!e)return "";const r=e.getBoundingClientRect();if(r.height<=0)return "";const d=devicePixelRatio;return [Math.round((r.left+r.width/2)*d),Math.round((r.top+r.height/2)*d),e.getAttribute("aria-label")].join(" ")})()'
GROUP='(()=>{const e=document.querySelector("[data-key=\"tools\"] .cc-more");if(!e)return "";const r=e.getBoundingClientRect(),d=devicePixelRatio;return [Math.round((r.left+r.width/2)*d),Math.round((r.top+r.height/2)*d)].join(" ")})()'
t=$(q "$TILE")
if [ -z "$t" ]; then
  g=$(q "$GROUP")
  if [ -n "$g" ]; then "$A" shell "input tap $g" >/dev/null; sleep 1.2; chk open-tools; fi
  t=$(q "$TILE")
fi
if [ -z "$t" ]; then
  fail "the Controller tile isn't shown in the control centre (control centre open: $(q 'document.querySelector(".cc")?"yes":"no"'))"
  exit 1
fi
label=$(echo "$t" | cut -d' ' -f3-)
log "tile shown: $label"
case "$label" in "controller: on") tl=true ;; "controller: off") tl=false ;; *) fail "the tile's label isn't controller: on|off ($label)"; tl="" ;; esac
[ -z "$tl" ] || [ "$tl" = "$S0" ] || fail "the tile says $tl, pad.state() says $S0"

# Arm the page: a pointerdown on the tile stamps the tap; a watcher polls pad.state() until it changes.
arm() {
  q "(()=>{const w=window;if(w.__padH)document.removeEventListener('pointerdown',w.__padH,true);w.__padW={tap:null,flip:null,v:null};w.__padH=e=>{if(w.__padW.tap==null&&e.target.closest&&e.target.closest('[data-key=\"powos.pad\"]'))w.__padW.tap=performance.now()};document.addEventListener('pointerdown',w.__padH,true);const from=String($1);(async()=>{const t0=performance.now();while(performance.now()-t0<4000&&w.__padW.flip==null){const v=await w.powos.pad.state();if(String(v)!==from){w.__padW.flip=performance.now();w.__padW.v=String(v);break}await new Promise(r=>setTimeout(r,15))}})();return 'armed'})()" >/dev/null
}
res() { q "[String(window.__padW.tap),String(window.__padW.flip),String(window.__padW.v)].join(' ')"; }
# tap_tile FROM: taps the tile once; sets NEW to the state it reached, logs the tap-to-change time.
tap_tile() {
  local from=$1 tt r tp fl ms
  NEW=""
  t=$(q "$TILE"); [ -n "$t" ] || { fail "the tile is gone before the tap"; return; }
  arm "$from"
  "$A" shell "input tap $(f "$t" 1) $(f "$t" 2)" >/dev/null; sleep 1.5; chk tap
  r=$(res); tp=$(f "$r" 1); fl=$(f "$r" 2)
  if [ "$tp" = null ]; then fail "the tap didn't reach the tile (no pointerdown on it)"; return; fi
  if [ "$fl" = null ]; then fail "tapped: pad.state() still $from after 4 s"; return; fi
  ms=$(awk -v a="$fl" -v b="$tp" 'BEGIN{printf "%d", a-b}')
  NEW=$(f "$r" 3)
  log "tap -> pad.state() $NEW in ${ms} ms"
  [ "$ms" -le 1000 ] || fail "tap -> state change took ${ms} ms (over 1 s)"
}

tap_tile "$S0"; A1=$NEW
[ "$A1" = "$(flip "$S0")" ] || fail "the tap didn't flip the overlay: $S0 -> ${A1:-nothing}"
sleep 0.8
tap_tile "$A1"; B1=$NEW
[ "$B1" = "$S0" ] || fail "tapped again, pad.state() is ${B1:-nothing}, not back to $S0"

# Leave the overlay as it was (restore is a no-op when the taps did it), then close the shade.
[ "$(state)" = "$S0" ] || { q "window.powos.pad.overlay($S0).then(String)" >/dev/null; sleep 0.5; }
log "pad.state at end: $(state)"
[ "$(state)" = "$S0" ] || fail "the overlay isn't back to its start state ($S0)"
sh_ "cmd statusbar collapse; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1; chk close

restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: the Controller tile in the control centre toggles the overlay (pad.state flips within 1 s, both ways)" ||
  { echo "FAIL: $FAILS step(s)"; exit 1; }
