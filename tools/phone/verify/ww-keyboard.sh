#!/bin/bash
# lanes: emu phone
# screen: inner
# needs: home
# ww-keyboard.sh: typing in a web window, the app's content ends above the keyboard (board task
# keyboard-resizes-the-window-but-not-the-content, the user 11-23: "it doesn't resize the content so I don't see where
# I'm typing"; KB1, shell/ui/kbfit.ts). On the unfolded home a chat-shaped app is opened through home's launch path,
# pinned to the right half (webwindows tile "right"), and a REAL tap on its text field brings the keyboard up. Then:
#   - the app's content bottom - the body's top on screen + its display's height (what the app lays out in: an Android
#     app on its virtual display gets no IME insets, so the display itself must end at the keyboard) - is at or above
#     the keyboard's top (the IME window's frame, dumpsys window; home's keyboard inset if that has none);
#   - the app relayouted: its display is shorter than before the keyboard;
#   - the keyboard down (Back), the window's body is its old size again.
# Emulator: the test window client's chat (tools/emu/testwin Chat: messages + a field pinned to the bottom), installed
# here when the emulator's copy is older; it also logs where it put its field (PowosTestChat), checked against the
# keyboard's top. Phone: Google Messages (KB_APP / KB_TAP override: the app key and the tap as body fractions "fx fy").
# Opens only an app the user isn't running; closes it after. Exit 0 PASS, 1 FAIL, 3 not now.
#   queue.sh add --dev auto --close keyboard-resizes-the-window-but-not-the-content tools/phone/verify/ww-keyboard.sh
set -uo pipefail
NAME=ww-keyboard; . "$(dirname "$0")/wwc-lib.sh"
if [ "${POWOS_DEVICE:-phone}" = emu ]; then
  APP=${KB_APP:-a:com.oneplus.calculator/com.oneplus.calculator.Chat}; TAP=${KB_TAP:-0.5 0.96}; PKG=com.oneplus.calculator
  if ! "$A" shell dumpsys package com.oneplus.calculator 2>/dev/null | awk '/versionName=emu-testwin-[2-9]/{f=1} END{exit !f}'; then
    apk=$("$T/../emu/testwin/build.sh") && "$A" install -r "$apk" >/dev/null && say "test window client installed (its chat)"; fi
else
  APP=${KB_APP:-a:com.google.android.apps.messaging}; TAP=${KB_TAP:-0.5 0.08}; PKG=${APP#a:}; PKG=${PKG%%/*}
fi
# ime_top: the keyboard's top on screen (device px), empty when no keyboard shows.
ime_top() { local f t
  [ "$(sh_ "dumpsys input_method" | grep -m1 -oE "mInputShown=(true|false)")" = mInputShown=true ] || return 0
  f=$(sh_ "dumpsys window InputMethod" | grep -m1 -oE "mFrame=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]")
  t=$(sed -E 's/mFrame=\[[0-9]+,([0-9]+)\].*/\1/' <<<"$f")
  if [ -z "$t" ] || [ "$t" = 0 ]; then
    t=$(ev "(()=>{const k=parseFloat(document.documentElement.style.getPropertyValue('--inset-keyboard'))||0;return k>0?String(Math.round((innerHeight-k)*devicePixelRatio)):''})()"); fi
  echo "$t"; }
# vd_h <display>: the app's display height (device px).
vd_h() { sh_ "wm size -d $1" | grep -m1 -oE "[0-9]+x[0-9]+" | cut -dx -f2; }
body_of() { wwbody "$WID"; }

wwc_start
[ "$(sh_ "pidof $PKG")" = "" ] || [ "${POWOS_DEVICE:-phone}" = emu ] || wwc_skip "$PKG runs already (the user's)"
WID=$(ww_open "$APP" 45) || { bad "open $APP: $WID"; wwc_end; }
MINE_W="$WID"; [ "${POWOS_DEVICE:-phone}" = emu ] || MINE_P=""
say "opened $APP as $WID"
r=$(ev "importShim('./ui/webwindows.tsx').then(m=>(m.tile(${WID#w},'right'),'ok')).catch(e=>'ERR '+e)"); say "pinned to the right half: $r"
sleep 2
disp=$(hcall webwindows.list "[]" "l=>String(l.find(w=>w.id===${WID#w})?.display??'')")
read -r bl bt br bb <<<"$(body_of)"
h0=$(vd_h "$disp")
say "before: body $bl $bt $br $bb, display $disp ${h0:-?} px high"
[ -n "${bt:-}" ] && [ -n "${h0:-}" ] || { bad "no body rect or display size ($disp)"; wwc_end; }
read -r fx fy <<<"$TAP"
tx=$(awk -v l="$bl" -v r="$br" -v f="$fx" 'BEGIN{printf "%d", l+(r-l)*f}'); ty=$(awk -v t="$bt" -v b="$bb" -v f="$fy" 'BEGIN{printf "%d", t+(b-t)*f}')
"$A" logcat -c 2>/dev/null
sh_ "echo \$(( \$(date +%s) + 6 )) > /data/local/tmp/powos-selfinput; input tap $tx $ty"
say "tapped the field at $tx,$ty"
top=""; for _ in 1 2 3 4 5 6 7 8; do sleep 0.5; top=$(ime_top); [ -n "$top" ] && break; done
[ -n "$top" ] || { say "no keyboard came up for the tap (the field wasn't hit?) - not judged"; touched && wwc_end; wwc_skip "no keyboard"; }
sleep 1.5
top=$(ime_top)
read -r _ bt1 _ bb1 <<<"$(body_of)"
h1=$(vd_h "$disp")
bottom=$((bt1 + h1))
say "keyboard up: its top at $top; body $bt1..$bb1, display ${h1} px high -> the app's content ends at $bottom"
[ "$bottom" -le $((top + 2)) ] || bad "the app's content ends at $bottom, under the keyboard's top $top ($((bottom - top)) px hidden): the display wasn't fitted above the keyboard"
[ "$h1" -lt "$h0" ] || bad "the app's display stayed $h1 px high (was $h0): the app never relayouted for the keyboard"
if [ "${POWOS_DEVICE:-phone}" = emu ]; then
  f=$("$A" logcat -d -s PowosTestChat:I 2>/dev/null | grep -oE "field [0-9-]+ [0-9-]+ [0-9]+ [0-9]+ root [0-9]+" | tail -1)
  read -r _ _ fyy _ fh _ _ <<<"$f"
  if [ -n "${fyy:-}" ]; then fb=$((bt1 + fyy + fh)); say "the chat's field: $f -> its bottom on screen at $fb"
    [ "$fb" -le $((top + 2)) ] || bad "the chat's text field ends at $fb, under the keyboard's top $top"; fi
fi
sh_ "echo \$(( \$(date +%s) + 4 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_BACK"
for _ in 1 2 3 4 5 6; do sleep 0.5; [ -z "$(ime_top)" ] && break; done
sleep 1
read -r _ _ _ bb2 <<<"$(body_of)"
say "keyboard down: body ends at $bb2 (was $bb)"
[ "${bb2:-0}" -ge $((bb - 2)) ] || bad "keyboard down, the window still ends at $bb2 (want its own $bb back)"
wwc_end "typing in a right-pinned $APP window: content ends at $bottom, the keyboard's top at $top; its size back after"
