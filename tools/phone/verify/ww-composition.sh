#!/bin/bash
# lanes: phone
# screen: inner
# tools/phone/verify/ww-composition.sh: docs/WINDOWS_FIX_PLAN.md 1.6 - how SurfaceFlinger composes home with web windows,
# the compositor's glass blur on and off. HYPOTHESIS under test: the blur over windows forces GPU (CLIENT) composition
# (an older trace: 360 of 361 frames GPU-composited with a window open). Measures only; it changes nothing for good.
#
#   queue.sh add ww-composition tools/phone/verify/ww-composition.sh [--apps "kate dolphin konsole calc settings chrome"]
#
# For 1, 3 and 6 web windows (as many of --apps as open; one the user already runs is left out), glass on and off
# (the page's `__glass.live.native(false)`: the CSS glass, no compositor blur regions - the A/B switch, put back after):
#   rest  SAMPLES (5) `dumpsys SurfaceFlinger` HWC lists, the page still
#   drag  SAMPLES lists during a 1.6 s drag of the top window's bar (input swipe, back after)
# Each list: the active display's layers by composition (DEVICE = overlay, CLIENT = GPU-composed). Output:
# $OUT/composition.tsv (windows, glass, phase, samples, samples with any CLIENT layer, CLIENT layers, layers) and one
# "COMP" line each; the decision (pause blur while a window moves or resizes, or not) is written from these numbers
# into docs/research/window-bench.md - never applied by this script.
# Exit: 0 measured; 3 not now (re-queued); 5 ENV. Only what it opened is closed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPS="kate dolphin konsole calc settings chrome"; ARGS=()
while [ $# -gt 0 ]; do case "$1" in --apps) APPS=$2; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
. "$here/e2e-lib.sh"
e2e_args ${ARGS[@]+"${ARGS[@]}"}
E2E_APPS='com.oneplus.calculator|com.android.settings|com.android.chrome'
E2E_LINUX='kate dolphin konsole'
e2e_init ww-composition
SAMPLES=${SAMPLES:-5}
TSV=$OUT/composition.tsv; printf 'windows\tglass\tphase\tsamples\tclient_samples\tclient_layers\tlayers\n' > "$TSV"
WW="Promise.all([importShim('./ui/webwindows.tsx'),importShim('./state.ts')])"
MINE=""; USED=""   # the web windows this run opened (w-ids); the apps tried
GLASS0=""

keyof() {
  case $1 in
    kate|dolphin|konsole) echo "l:org.kde.$1" ;;
    calc) hcall apps.list "[]" "l=>(l.find(a=>/^a:com\\.oneplus\\.calculator\\//.test(a.key))||{}).key||'none'" ;;
    settings) hcall apps.list "[]" "l=>(l.find(a=>/^a:com\\.android\\.settings\\//.test(a.key))||{}).key||'none'" ;;
    chrome) hcall apps.list "[]" "l=>(l.find(a=>/^a:com\\.android\\.chrome\\//.test(a.key))||{}).key||'none'" ;;
    *) echo none ;;
  esac
}
linux() { case $1 in kate|dolphin|konsole) return 0 ;; esac; return 1; }

# hwc_counts: one HWC list of the active display -> "<client layers> <layers>" (bf-quiet.sh's parse).
hwc_counts() {
  "$A" shell "su -c 'dumpsys SurfaceFlinger'" 2>/dev/null | tr -d '\r' |
    awk '/\(active\) HWC layers/{p=1;next} p&&/^Display .*HWC layers/{p=0} p&&/\|/{split($0,c,"|"); gsub(/ /,"",c[4]); if (c[4]=="DEVICE"||c[4]=="CLIENT"||c[4]=="SOLID_COLOR"||c[4]=="CURSOR"||c[4]=="SIDEBAND") {n++; if (c[4]=="CLIENT") k++}} END{print k+0, n+0}'
}

# sample <windows> <glass> <phase>: SAMPLES lists, one TSV row and one COMP line.
sample() {
  local i s=0 cs=0 cl=0 n=0 k t
  for i in $(seq 1 "$SAMPLES"); do
    read -r k t <<<"$(hwc_counts)"; [ -n "${t:-}" ] && [ "$t" -gt 0 ] || continue
    s=$((s + 1)); n=$((n + t)); cl=$((cl + k)); [ "$k" -gt 0 ] && cs=$((cs + 1))
    sleep 0.25
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$s" "$cs" "$cl" "$n" >> "$TSV"
  log "COMP windows=$1 glass=$2 $3: $cs of $s samples GPU-composed (CLIENT layers $cl of $n)"
}

# measure <windows>: rest and drag, glass on then off, the glass put back as it was.
measure() {
  local g top p x y
  for g in on off; do
    ev "(window.__glass.live.native($([ $g = on ] && echo true || echo false)),'ok')" >/dev/null; sleep 1.5
    sample "$1" "$g" rest
    top=$(ev "$WW.then(([m])=>{const w=m.webWins.value.at(-1);return w?'w'+w.id:''})")
    p=$([ -n "$top" ] && wwpt "$top" ".webwindow-title")
    if [ -n "$p" ]; then
      read -r x y <<<"$p"
      "$A" shell "input swipe $x $y $((x - 300)) $((y + 150)) 1600" & local sw=$!
      sleep 0.2; sample "$1" "$g" drag; wait $sw
      "$A" shell "input swipe $((x - 300)) $((y + 150)) $x $y 400" >/dev/null
    else
      note "windows=$1 glass=$g: no bar on screen to drag"
    fi
  done
  restore_glass
}

restore_glass() { [ -n "$GLASS0" ] && ev "(window.__glass.live.native($GLASS0),'ok')" >/dev/null; }
RC=0
restore_comp() {
  [ $RC = 1 ] && return 0; RC=1
  local i
  restore_glass
  for i in $MINE; do ww_close "$i"; done
}

e2e_setup inner
trap 'restore_comp; e2e_abort' EXIT
ww_ready || { echo "ENV: home has no web windows here (folded, off)"; exit 5; }
GLASS0=$(ev 'String(window.__glass.live.state.native)')
[[ "$GLASS0" = true || "$GLASS0" = false ]] || { echo "ENV: cannot read the glass state ($GLASS0)"; exit 5; }
log "apk $(sh_ "dumpsys package com.powos.app | grep -m1 versionName"), glass native=$GLASS0"

n=0
for target in 1 3 6; do
  for a in $APPS; do
    [ "$n" -ge "$target" ] && break
    [[ " $USED " == *" $a "* ]] && continue
    USED="${USED:-} $a"
    if linux "$a" && [ -n "$(us "pgrep -x $a | head -1")" ]; then note "$a: the user's $a runs - left out"; continue; fi
    k=$(keyof "$a"); case $k in ""|none|ERR*) note "$a: no launch key ($k)"; continue ;; esac
    if w=$(ww_open "$k" 25); then MINE="$MINE $w"; n=$((n + 1)); log "opened $a as $w"; else note "$a: $w"; fi
  done
  [ "$n" -ge 1 ] || { echo "ENV: no window opened"; exit 5; }
  sleep 1.5
  measure "$n"
  [ "$n" -lt "$target" ] && { note "only $n windows opened: stopped at $n"; break; }
done
pass "composition measured: $TSV"
log "$(column -t < "$TSV")"
e2e_finish
