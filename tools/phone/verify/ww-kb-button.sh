#!/bin/bash
# lanes: phone
# screen: inner
# needs: kwin home
# ww-kb-button.sh: a Linux window's title-bar keyboard button raises Android's keyboard and the typing reaches the X11
# text field (board task keyboard-doesn-t-open-for-text-fields-in-wine-linux, the user 11-26: the EA app's code field
# under Proton raised no keyboard - Wine keeps IBus's XIM focus on the whole window, so no per-field signal exists and
# the button is the sure path: kbfit.ts hasKeyboardButton -> webwindows.keyboard -> WebWindowSource.toggleKeyboard).
# Its own X11 app (zenity --entry, GDK_BACKEND=x11: Xwayland, as Wine), never Steam or a game. Steps:
#   button  the window's bar has a "Keyboard" button (a host with webwindows.keyboard)
#   up      a real tap on it: dumpsys input_method mInputShown=true
#   typed   text and Enter typed (input text / keyevent, into the keyboard's input): zenity prints the entry
#   down    the keyboard goes: a second tap on the button, or the entry closed by the Enter
# Its app is quit after; nothing of the user's is touched. Exit 0 PASS, 1 FAIL, 3 not now.
set -uo pipefail
# shellcheck disable=SC2034 # NAME, MINE_W: read by wwc-lib.sh (its log, wwc_clean)
NAME=ww-kb-button; . "$(dirname "$0")/wwc-lib.sh"
WORD=powoskb$RANDOM
shown() { sh_ "dumpsys input_method" | grep -m1 -oE "mInputShown=(true|false)" | cut -d= -f2; }
self() { sh_ "echo \$(( \$(date +%s) + 6 )) > /data/local/tmp/powos-selfinput; $1"; }
wwc_extra() { ww_us "pkill -f wwc-kbb-check; true" >/dev/null; ww_us "rm -f /tmp/wwc-kbb.out" >/dev/null; }
wwc_start
before=$(wwids l:)
wwc_ses "rm -f /tmp/wwc-kbb.out; GDK_BACKEND=x11 setsid zenity --entry --title wwc-kbb-check --text type-here >/tmp/wwc-kbb.out 2>/dev/null </dev/null &" >/dev/null
w=$(wwnew 30 "$before" l:); w=${w%%[[:space:]]*}
[ -n "$w" ] || { bad "the X11 entry came as no web window in 30 s"; wwc_end; }
# shellcheck disable=SC2034 # wwc_clean closes it
MINE_W="$w"; say "opened the X11 entry as $w"; sleep 3
if [ "$(shown)" = true ]; then self "input keyevent KEYCODE_BACK"; sleep 1; fi
pt=$(wwpt "$w" '.ww-button[aria-label="Keyboard"]')
[ -n "$pt" ] || { bad "button: no Keyboard button on $w's bar"; wwc_end; }
say "button at $pt"
self "input tap $pt"
up=""; for _ in 1 2 3 4 5 6 7 8; do sleep 0.5; [ "$(shown)" = true ] && { up=1; break; }; done
[ -n "$up" ] || { bad "up: the tap on the button brought no keyboard (mInputShown=$(shown))"; wwc_end; }
say "up: the keyboard shows"
self "input text $WORD"; sleep 1; self "input keyevent KEYCODE_ENTER"; sleep 2
out=$(ww_us "cat /tmp/wwc-kbb.out 2>/dev/null" | tail -1)
say "typed: zenity printed '${out}'"
[ "$out" = "$WORD" ] || bad "typed: the entry got '${out}', want '$WORD' (the text never reached the X11 field)"
# Still open (no Enter reached it): a second tap on the button puts the keyboard down. Closed: its consumer let go.
pt=$(wwpt "$w" '.ww-button[aria-label="Keyboard"]')
[ -n "$pt" ] && self "input tap $pt"
for _ in 1 2 3 4 5 6; do sleep 0.5; [ "$(shown)" = false ] && break; done
how="the window closed"; [ -n "$pt" ] && how="a second tap on the button"
[ "$(shown)" = false ] || bad "down: the keyboard stayed up ($how)"
wwc_end "the bar's keyboard button raised Android's keyboard for an X11 field and '$WORD' reached it"
