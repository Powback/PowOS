#!/bin/bash
# lanes: phone
# screen: inner
# tools/phone/verify/ww-shadow.sh [OUT]: SH1 (the user, 11-23: "The shadow is not positioned correctly when I'm
# resizing a window"; docs/WEB_WINDOWS.md SH1). A Calculator web window opened through home's launch path, then real
# resize drags (input swipe, 700 ms a way, there and back): top edge up into the status strip's reach, bottom edge down
# into the dock's, left edge out, bottom-right corner in, top-left corner out. Through each drag a sampler in home's
# page (ww-shadow.js) reads, EVERY display frame, the window's drop shadow against its frame (the whole shadow's caster,
# or each 9-slice piece's box and the caster edges it shows; 1 CSS px slack). The bottom-edge drag is also screen-
# recorded (OUT/s.mp4 + a frame sheet OUT/s-sheet.png) as the picture of it.
# FAIL: any frame whose shadow is off its frame, or a drag that didn't resize the window. Needs the phone unfolded and
# idle (the runner's window). Exit: 0 PASS; 1 FAIL; 3 not now (a real touch, folded, a full-screen window up).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/ww-shadow-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
CALC=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
fail=0
bad() { log "FAIL $*"; fail=1; }
WW_DEADLINE=250
export CDP_TIMEOUT_S=${CDP_TIMEOUT_S:-20}
. "$here/ww-lib.sh"
MINE="" CALC_MINE=0
restore() {
  [ "${RESTORED:-0}" = 1 ] && return 0; RESTORED=1
  WW_DEADLINE=$((SECONDS + 40))
  CDP_TIMEOUT_S=8 ev "globalThis.__wwShadow?.stop()" >/dev/null 2>&1
  for w in $MINE; do ww_close "$w"; done
  [ "$CALC_MINE" = 1 ] && sh_ "am force-stop $CALC"
  true
}
. "$here/window-lock.sh"
window_lock ww-shadow.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
trap 'exit 1' TERM INT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { log "STOP: a real touch at $1 - restoring"; exit 3; }; }

sh_ "dumpsys device_state" | awk '/mCommittedState=.*OPENED/{f=1} END{exit !f}' || { log "SKIP folded (needs the inner screen)"; exit 3; }
sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME" >/dev/null
for i in $(seq 1 10); do
  full=$(hcall webwindows.list "[]" "l=>'ok '+l.filter(w=>w.state==='full').map(w=>w.key).join(' ')")
  case $full in ok*) break ;; esac; sleep 2
done
case $full in ok*) full=${full#ok} full=${full# } ;; *) log "SKIP home's bridge: $full"; exit 3 ;; esac
[ -z "$full" ] || { log "SKIP a full-screen window is up ($full) - not touched"; exit 3; }
r=$(ev "$(cat "$here/ww-shadow.js")")
[ "$r" = ok ] || { bad "sampler not installed: $r"; exit 1; }

key=$(ev "importShim('./state.ts').then(m=>(m.apps.value.find(a=>String(a.key).startsWith('a:$CALC'))||{}).key||'')")
[ -n "$key" ] || { log "SKIP no drawer key for $CALC"; exit 3; }
[ -z "$(sh_ "pidof $CALC")" ] && CALC_MINE=1
before=$(wwids)
r=$(ev "importShim('./state.ts').then(m=>m.launch('$key')).then(()=>'ok',e=>'ERR '+e)"); [ "$r" = ok ] || { bad "launch $key: $r"; exit 1; }
id=$(wwnew 30 "$before" | tail -1)
[ -n "$id" ] || { bad "no new web window for $key within 30 s"; exit 1; }
MINE=$id
for i in $(seq 1 15); do [ "$(wwel "$id" "e=>e.querySelector('.webwindow-body.live')?'live':'no'")" = live ] && break; sleep 1; done
# The window at half the work area, its bottom right (ww-resize.sh's wwclear): room to grow up and left, near the dock.
place() { ev "importShim('./ui/webwindows.tsx').then(m=>{const a=m.workArea(),W=Math.round((a.right-a.left)*0.5),H=Math.round((a.bottom-a.top)*0.5);m.placeWindow(${id#w},{x:a.right-W-56,y:a.bottom-H-64,w:W,h:H});return 'ok'},e=>'ERR '+e)"; }
SW=$(sh_ "wm size" | grep -oE '[0-9]+x[0-9]+' | tail -1)
sheet() { ffmpeg -v error -y -i "$OUT/$1.mp4" -vf "fps=10,scale=360:-1,tile=6x4" -frames:v 1 "$OUT/$1-sheet.png" 2>/dev/null; }

# gesture <name> <zone> <dx> <dy> [rec]: one drag there and back on that zone, the sampler over both ways.
gesture() {
  local name=$1 zone=$2 dx=$3 dy=$4 rec=${5:-} px py qx qy f0 f1 rp="" res
  [ "$SECONDS" -lt "$WW_DEADLINE" ] || { bad "$name: not run - the deadline"; return; }
  r=$(place); [ "$r" = ok ] || { bad "$name: placing $id: $r"; return; }
  sleep 0.8
  read -r px py <<<"$(wwpt "$id" ".ww-edge-$zone")"
  [ -n "${py:-}" ] || { bad "$name: no .ww-edge-$zone on screen"; return; }
  f0=$(wwrect "$id")
  if [ -n "$rec" ]; then
    sh_ "rm -f /data/local/tmp/wwsh.mp4"
    "$A" shell "su -c 'screenrecord --bit-rate 8000000 --time-limit 3 /data/local/tmp/wwsh.mp4'" >/dev/null 2>&1 & rp=$!
    sleep 0.6
  fi
  ev "__wwShadow.start(${id#w})" >/dev/null
  sh_ "input swipe $px $py $((px + dx)) $((py + dy)) 700"
  f1=$(wwrect "$id")
  read -r qx qy <<<"$(wwpt "$id" ".ww-edge-$zone")"
  sh_ "input swipe ${qx:-$((px + dx))} ${qy:-$((py + dy))} $px $py 700"
  sleep 0.3
  res=$(ev "__wwShadow.stop()")
  if [ -n "$rp" ]; then
    wait "$rp"
    "$A" exec-out "su -c 'cat /data/local/tmp/wwsh.mp4; rm -f /data/local/tmp/wwsh.mp4'" > "$OUT/$name.mp4" 2>/dev/null
    [ -s "$OUT/$name.mp4" ] && sheet "$name"
  fi
  log "$name ($zone $dx,$dy): frame $f0 -> $f1; shadow $res"
  [ "$f0" != "$f1" ] || bad "$name: the drag didn't resize the window (frame $f0 both times)"
  case $res in "frames "*" bad 0"*) ;; *) bad "$name: shadow off its frame: $res" ;; esac
  chk "$name"
}

log "window $id ($key), screen $SW"
gesture n n 0 -600
gesture s s 0 600 rec
gesture w w -400 0
gesture se se -300 -200
gesture nw nw -300 -300
[ "$fail" = 0 ] && log "PASS the shadow followed the frame on every frame of every drag"
exit "$fail"
