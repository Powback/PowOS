#!/bin/bash
# lanes: phone
# screen: inner
# needs: home
# titlebar-autohide.sh: TB1 (the owner, 11-14: "the titlebar isnt acting like the native one, with autohide on
# fullscreen apps etc, slide to reveal"; docs/WEB_WINDOWS.md "Title bar: native parity"). On the unfolded home, Chrome
# opened in a web window and maximised, showing a page (served from the Mac over `adb reverse`) that goes full screen
# on a tap (requestFullscreen: Chrome hides the system bars - an immersive app). Real input only (`input tap/swipe`):
#   control  maximised, not immersive: its bar laid out above the body
#   hide     tapped full screen: within 2 s the bar auto-hides, the body takes the frame's top, and the host logs
#            "its app hides its status bar" + "TB1: status bar hidden"
#   reveal   a swipe down from the screen's top edge over the window: the bar slides in (.ww-bar-shown) within 1 s and
#            the body's rect is unchanged (it overlays the app)
#   idle     4 s later the bar is hidden again (BAR_REVEAL 2250 ms)
#   leave    tapped again (exitFullscreen): within 2 s the bar is laid out again, "TB1: status bar back"
# Opens Chrome only when the user isn't running it (stopped after). Exit 0 PASS, 1 FAIL, 3 not now.
set -uo pipefail
NAME=titlebar-autohide; . "$(dirname "$0")/wwc-lib.sh"
PORT=8765 CHROME=com.android.chrome SRV="" PAGE=$(mktemp -d "${TMPDIR:-/tmp}/tb-page.XXXXXX")
wwc_extra() {
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
  "$A" reverse --remove "tcp:$PORT" >/dev/null 2>&1
  sh_ "am force-stop $CHROME" >/dev/null
  rm -rf "$PAGE"; }
until_() { local i; for i in $(seq 1 "$1"); do sleep 0.5; eval "$2" && return 0; done; return 1; }
# The window's bar / body rects (CSS px "top bottom") and whether its bar is slid in.
part() { wwel "$WID" "e=>{const b=e.querySelector(':scope > $1');if(!b)return '';const r=b.getBoundingClientRect(),f=e.getBoundingClientRect();return [r.top-f.top,r.bottom-f.top,r.height].map(Math.round).join(' ')}"; }
laid() { local b; b=$(part .webwindow-title); [ "$(part .webwindow-body | cut -d' ' -f1)" = "$(echo "$b" | cut -d' ' -f2)" ] && [ "${b%% *}" -ge 0 ]; }
hid() { [ "$(part .webwindow-body | cut -d' ' -f1)" = 0 ] && [ "$(part .webwindow-title | cut -d' ' -f2)" -le 0 ]; }
shown() { [ "$(wwel "$WID" "e=>e.classList.contains('ww-bar-shown')")" = true ]; }
logged() { "$A" shell "logcat -d -T '$SINCE' -s PowosWebWindows:I" 2>/dev/null | tr -d '\r' | awk -v p="$1" 'index($0, p) {f=1} END {exit !f}'; }

wwc_start
[ -n "$(sh_ "pidof $CHROME")" ] && wwc_skip "Chrome runs (the user's)"
cat > "$PAGE/tb.html" <<'HTML'
<!doctype html><meta name="viewport" content="width=device-width">
<body style="margin:0;height:100vh;background:#203040;color:#fff;font:24px sans-serif;display:grid;place-items:center"
 onclick="document.fullscreenElement?document.exitFullscreen():document.documentElement.requestFullscreen()">tap: full screen</body>
HTML
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$PAGE" >/dev/null 2>&1 & SRV=$!
"$A" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null || wwc_skip "adb reverse failed"
WID=$(ww_open "a:$CHROME" 40) || { bad "open Chrome: $WID"; wwc_end; }
MINE_W="$MINE_W $WID"; say "opened Chrome as $WID"
D=$(wwhost "$WID" display)
sh_ "am start --display $D -a android.intent.action.VIEW -d http://127.0.0.1:$PORT/tb.html -p $CHROME" >/dev/null
ev "importShim('./ui/webwindows.tsx').then(m=>{const w=m.webWins.value.find(w=>w.id===${WID#w});if(w&&!w.restore)m.toggleMaximise(w.id);return 'ok'})" >/dev/null
sleep 4
laid || bad "control: maximised, not immersive - its bar isn't laid out (bar '$(part .webwindow-title)', body '$(part .webwindow-body)')"
SINCE=$(sh_ "date '+%m-%d %H:%M:%S.000'")
c=$(wwbody "$WID"); set -- $c; cx=$(( ($1 + $3) / 2 )) cy=$(( ($2 + $4) / 2 ))
sh_ "input tap $cx $cy"; say "tapped the page at $cx $cy (full screen)"
until_ 4 hid || bad "hide: 2 s after the app went full screen its bar isn't auto-hidden (bar '$(part .webwindow-title)', body '$(part .webwindow-body)')"
logged "hides its status bar (immersive)" || bad "hide: the host never logged the app's immersive request"
logged "TB1: status bar hidden" || bad "hide: the host never hid the status bar"
before=$(part .webwindow-body)
sh_ "input swipe $cx 4 $cx 260 250"; say "swiped down from the top edge at x $cx"
until_ 2 shown || bad "reveal: a swipe from the top didn't slide the bar in"
[ "$(part .webwindow-body)" = "$before" ] || bad "reveal: the body moved ('$before' -> '$(part .webwindow-body)'): the bar relaid the app out"
sleep 4
shown && bad "idle: the slid-in bar still shows 4 s later"
sh_ "input tap $cx $cy"; say "tapped the page again (leave full screen)"
until_ 4 laid || bad "leave: 2 s after the app left full screen its bar isn't back (bar '$(part .webwindow-title)')"
until_ 4 'logged "TB1: status bar back"' || bad "leave: the host never showed the status bar again"
wwc_end "maximised Chrome: bar auto-hid on its full screen, a top swipe slid it in over the app, it hid again, back on leaving"
