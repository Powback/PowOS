#!/bin/bash
# lanes: phone
# tools/phone/verify/rotate-repro.sh [--only ai|home] [--hold S]: a REPRO of the user's blank shell after a rotate (11-02
# 21:55, P0 "Rotating the phone must not black out the shell": unfolded -> cover portrait with the PowOS AI page up,
# then only the status bar and a scrollbar, flat dark - they had to reboot; headless gate RT1 can't reproduce it).
# Queue it: queue.sh add rotating-the-phone-must-not-black-out-the-shell tools/phone/verify/rotate-repro.sh
# No touch at all: the screen is turned by SETTINGS on the screen that is on now (accelerometer_rotation 0, then
# user_rotation 0 1 2 3 0, HOLD s each), first on the PowOS AI page (page -1), then on home's page 0. After each turn:
#   - the screenshot (the step's, on the phone) and a raw capture judged here: FAIL when it is mostly one flat colour
#     (the user's flat dark), against the same page's unturned baseline;
#   - home's page over CDP: __powosHomeBlank (FAIL when it names a reason), viewport, window.screen, the page, the AI
#     page's and home's boxes; FAIL when innerWidth/innerHeight don't follow the turn within 2 s;
#   - NN-<step>.txt next to the screenshot: dumpsys window's rotation/focus/HomeShell lines + logcat -d -t 400 filtered
#     (chromium / WebView / HomeShell / Powos / FATAL).
# e2e-lib frame: only in a free window (the user idle), aborted on a real touch (exit 3), the rotation settings, the page
# and the app in front restored in the trap (also on an abort). Evidence: /home/powos/design-qa/e2e-rotate-repro/<round>/.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
ONLY="" HOLD=3
ARGS=()
while [ $# -gt 0 ]; do case $1 in --only) ONLY=$2; shift 2 ;; --hold) HOLD=$2; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
e2e_args "${ARGS[@]+"${ARGS[@]}"}"
e2e_init rotate-repro
e2e_setup

# The rotation settings as they were, back in every exit (e2e_abort is the frame's own EXIT trap).
AR0=$(sh_ "settings get system accelerometer_rotation"); UR0=$(sh_ "settings get system user_rotation")
log "rotation settings at the start: accelerometer_rotation=$AR0 user_rotation=$UR0"
rot_restore() {
  [ -n "${AR0:-}" ] || return 0
  local c="settings put system accelerometer_rotation ${AR0/null/1};"
  case $UR0 in ""|null) c="$c settings delete system user_rotation;" ;; *) c="$c settings put system user_rotation $UR0;" ;; esac
  sh_ "$c" >/dev/null; AR0=""; sleep 1.5
  log "rotation settings restored: accelerometer_rotation=$(sh_ "settings get system accelerometer_rotation") user_rotation=$(sh_ "settings get system user_rotation")"
}
# shellcheck disable=SC2154  # rc is set in the trap itself
trap 'rc=$?; rot_restore; (exit $rc); e2e_abort' EXIT

# Home's page now, one JSON line (works without the new homeState too: everything read here).
STATE="importShim('./state.ts').then(m=>{const b=q=>{const e=document.querySelector(q);if(!e)return 'none';const r=e.getBoundingClientRect();return [r.left,r.top,r.right,r.bottom].map(Math.round).join(',')};return JSON.stringify({blank:window.__powosHomeBlank?window.__powosHomeBlank():'n/a',w:innerWidth,h:innerHeight,sw:screen.width,sh:screen.height,o:(screen.orientation||{}).type||'',page:m.page.value,hidden:document.hidden,ai:b('.ai-screen'),home:b('.home')})})"
jget() { python3 -c 'import json,sys
try: v=json.loads(sys.argv[1]).get(sys.argv[2],"")
except Exception: v=""
print(v)' "$1" "$2"; }
# flat: the share (0..1) of the screen in its most common colour (4 bits a channel, every 97th pixel of a raw capture
# of the display that is ON), or "" when it couldn't be read.
FLAT_PY='import gzip,struct,sys,collections
try:
    d=gzip.open(sys.argv[1]).read()
    w,h=struct.unpack("<II",d[:8]); px=d[16:16+w*h*4]
    c=collections.Counter((px[i]>>4,px[i+1]>>4,px[i+2]>>4) for i in range(0,len(px)-3,97*4))
    print("%.3f %dx%d" % (c.most_common(1)[0][1]/max(1,sum(c.values())),w,h))
except Exception as e:
    print("")'
RAW_SH=/data/local/tmp/powos-rotate-raw.sh
flat() {
  local f=$OUT/raw.gz
  [ -n "${RAW_UP:-}" ] || { ash <<'EOF'
cat > /data/local/tmp/powos-rotate-raw.sh <<'S'
id=$(dumpsys display | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)".* state ON,.*/\1/p' | head -1)
screencap -d "$id" | gzip -1
S
EOF
    RAW_UP=1; }
  "$A" exec-out "su -c 'sh $RAW_SH'" > "$f" 2>/dev/null
  python3 -I -c "$FLAT_PY" "$f"
}
# evidence <rotation>: the step's dumpsys + filtered logcat into NN-<step>.txt on the phone; the window lines printed.
evidence() {
  local f=$PDIR/${CUR%.png}.txt
  ash <<EOF
{ echo "rotation step: user_rotation=$1 accelerometer_rotation=\$(settings get system accelerometer_rotation)"
  echo "== dumpsys window"; dumpsys window | grep -E 'mCurrentRotation|mFocusedApp|HomeShell'
  echo "== logcat -d -t 400 (chromium|WebView|HomeShell|Powos|FATAL)"; logcat -d -v time -t 400 | grep -iE 'chromium|WebView|HomeShell|Powos|FATAL'
} > $f 2>&1; chmod a+r $f
grep -m3 -E 'mCurrentRotation|mFocusedApp' $f | tr -s ' ' | tr '\n' ';'
EOF
}

# One variant: on page <pg> (-1 the PowOS AI page, 0 home), the baseline then each turn.
variant() {
  local name=$1 pg=$2 r s st w h sw sh blank base fl o0 dir ok
  setpage "$pg"; sleep 1.5; chk "$name page"
  sh_ "settings put system accelerometer_rotation 0; settings put system user_rotation 0"; sleep "$HOLD"; chk "$name rotation 0"
  step "$name-base" "$name: on page $pg, rotation 0 by settings (no touch) - the baseline"
  st=$(ev "$STATE"); base=$(flat); base=${base%% *}
  w=$(jget "$st" w); h=$(jget "$st" h)
  [ "$w" -gt 0 ] 2>/dev/null && [ "$h" -gt 0 ] 2>/dev/null || { fail "$name: home's page unreadable over CDP at the baseline: $st"; return; }
  o0=$([ "$w" -gt "$h" ] && echo wide || echo tall)
  note "$name baseline: $st, flat ${base:-?}, window $(evidence 0)"
  for r in 1 2 3 0; do
    sh_ "settings put system user_rotation $r"
    # Follows the turn within 2 s: an odd turn flips wide/tall against rotation 0, an even one keeps it.
    ok=0; for _ in 1 2 3 4; do sleep 0.5; st=$(ev "$STATE"); w=$(jget "$st" w); h=$(jget "$st" h)
      [ "$w" -gt 0 ] 2>/dev/null && [ "$h" -gt 0 ] 2>/dev/null || continue
      dir=$([ "$w" -gt "$h" ] && echo wide || echo tall)
      if [ $((r % 2)) = 1 ]; then [ "$dir" != "$o0" ] && { ok=1; break; }; else [ "$dir" = "$o0" ] && { ok=1; break; }; fi
    done
    sleep "$HOLD"; chk "$name rotation $r"
    step "$name-rot$r" "$name: user_rotation $r by settings, $HOLD s later"
    st=$(ev "$STATE"); s=$(flat); fl=${s%% *}
    w=$(jget "$st" w); h=$(jget "$st" h); sw=$(jget "$st" sw); sh=$(jget "$st" sh); blank=$(jget "$st" blank)
    note "$name rotation $r: $st, flat ${s:-unread}, window $(evidence "$r")"
    [ $ok = 1 ] && pass "$name rotation $r: the viewport followed within 2 s (${w}x${h}, screen ${sw}x${sh})" \
      || fail "$name rotation $r: the viewport did NOT follow the turn within 2 s (now ${w:-?}x${h:-?}, screen ${sw:-?}x${sh:-?}, rotation 0 was $o0)"
    if [ -z "$st" ]; then fail "$name rotation $r: home's page gave no answer over CDP"
    elif [ "$blank" = n/a ]; then note "$name rotation $r: this build has no blank check (__powosHomeBlank)"
    elif [ -z "$blank" ]; then pass "$name rotation $r: home's blank check is clean"
    else fail "$name rotation $r: home reports blank: $blank"; fi
    if [ -n "$fl" ]; then
      if python3 -c "import sys; f,b=float(sys.argv[1]),float(sys.argv[2] or 0); sys.exit(0 if f>=0.985 or (f>=0.93 and f>=b+0.08) else 1)" "$fl" "${base:-0}"; then
        fail "$name rotation $r: the screen is mostly ONE flat colour ($fl of it; the baseline was ${base:-?}) - the user's blank"
      else pass "$name rotation $r: the screen is drawn (flat share $fl, baseline ${base:-?})"; fi
    else note "$name rotation $r: the raw capture couldn't be read (screen off?)"; fi
  done
}

[ "$ONLY" = home ] || variant ai -1
[ "$ONLY" = ai ] || variant home 0
rot_restore
sh_ "rm -f $RAW_SH" >/dev/null
e2e_finish
[ $NFAIL = 0 ] || exit 1
