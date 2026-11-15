#!/bin/bash
# lanes: phone
# screen: inner
# needs: home
# titlebar-autohide.sh: TB1 (the owner, 11-14: "the titlebar isnt acting like the native one, with autohide on
# fullscreen apps etc, slide to reveal"; docs/WEB_WINDOWS.md "Title bar: native parity"). On the unfolded home, Chrome
# opened in a web window and maximised, showing a page (served on phone loopback inside PowOS) that goes full screen
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
CHROME=com.android.chrome PAGE="" FORWARD=""
CHROME_OWNED=0 SERVER_OWNED=0
TOKEN=tb-$(date +%s)-$$-$RANDOM
wwc_extra() {
  # wwc_skip cleans explicitly, then EXIT cleans again. Consume ownership before each action.
  if [ "$CHROME_OWNED" = 1 ]; then CHROME_OWNED=0; sh_ "am force-stop $CHROME" >/dev/null; fi
  if [ -n "$FORWARD" ]; then local f=$FORWARD; FORWARD=""; "$A" forward --remove "tcp:$f" >/dev/null 2>&1; fi
  if [ "$SERVER_OWNED" = 1 ]; then
    SERVER_OWNED=0
    # No pkill/port kill: only this random directory's server observes its stop file.
    ww_us "touch '$PAGE/stop'; for i in 1 2 3 4 5 6 7 8; do [ -f '$PAGE/done' ] && break; sleep 0.25; done; cat '$PAGE/server.log'; if [ -f '$PAGE/done' ]; then rm -rf '$PAGE'; fi" >> "$OUT/server.log"
  fi
  return 0; }
chrome_claim() {
  local state
  # Empty adb output is NOT proof of absence. Require a complete remote pidof result;
  # rc 1 with empty output alone means absent; diagnostics or transport failure mean unknown.
  state=$(sh_ "p=\$(pidof $CHROME 2>&1); r=\$?; if [ \"\$r\" = 1 ] && [ -z \"\$p\" ]; then echo stopped; elif [ \"\$r\" = 0 ] && [ -n \"\$p\" ]; then echo running; else echo unknown; fi") || wwc_skip "Chrome running state unknown (query failed)"
  case $state in
    stopped) CHROME_OWNED=1 ;;
    running) wwc_skip "Chrome runs (the user's)" ;;
    *) wwc_skip "Chrome running state unknown ($state)" ;;
  esac; }
until_() { local i; for i in $(seq 1 "$1"); do sleep 0.5; eval "$2" && return 0; done; return 1; }
# The window's bar / body rects (CSS px "top bottom") and whether its bar is slid in.
part() { wwel "$WID" "e=>{const b=e.querySelector(':scope > $1');if(!b)return '';const r=b.getBoundingClientRect(),f=e.getBoundingClientRect();return [r.top-f.top,r.bottom-f.top,r.height].map(Math.round).join(' ')}"; }
laid() { local b; b=$(part .webwindow-title); [ "$(part .webwindow-body | cut -d' ' -f1)" = "$(echo "$b" | cut -d' ' -f2)" ] && [ "${b%% *}" -ge 0 ]; }
hid() { [ "$(part .webwindow-body | cut -d' ' -f1)" = 0 ] && [ "$(part .webwindow-title | cut -d' ' -f2)" -le 0 ]; }
shown() { [ "$(wwel "$WID" "e=>e.classList.contains('ww-bar-shown')")" = true ]; }
# Date is not privileged. Do not nest its quotes in sh_'s su -c single quotes.
mark_native() {
  local stamp
  stamp=$("$A" shell "date '+%m-%d %H:%M:%S.000'" 2>> "$OUT/native-errors.log") || return 1
  stamp=$(printf '%s' "$stamp" | tr -d '\r')
  [[ "$stamp" =~ ^[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.000$ ]] || return 1
  SINCE=$stamp
  printf '%s\n' "$SINCE" > "$OUT/native-since.txt"
}
native_snapshot() {
  [ -n "${SINCE:-}" ] || return 1
  "$A" shell "logcat -d -T '$SINCE' -s PowosWebWindows:I" > "$OUT/native-latest.log" 2>> "$OUT/native-errors.log" || return 1
  # Append, rather than overwrite, so an earlier interval survives logcat rotation.
  cat "$OUT/native-latest.log" >> "$OUT/native.log"
}
logged() { native_snapshot && awk -v p="$1" 'index($0, p) {f=1} END {exit !f}' "$OUT/native-latest.log"; }
# Read-only: retain the original tap coordinates, compare with CURRENT body geometry,
# DOM hit stack and native input windows. No synthetic click or guessed coordinate fix.
tap_diagnostics() {
  local label=$1
  {
    echo "$label tap physical=$cx,$cy display=$D"
    wwel "$WID" "e=>{const b=e.querySelector('.webwindow-body'),r=b?.getBoundingClientRect(),s=b&&getComputedStyle(b),x=$cx/devicePixelRatio,y=$cy/devicePixelRatio;return JSON.stringify({visible:document.visibilityState,dpr:devicePixelRatio,viewport:[innerWidth,innerHeight],frame:e.className,body:r&&{x:r.x,y:r.y,width:r.width,height:r.height},style:s&&{visibility:s.visibility,display:s.display,pointerEvents:s.pointerEvents},tapCSS:[x,y],inside:!!r&&x>=r.left&&x<r.right&&y>=r.top&&y<r.bottom,hits:document.elementsFromPoint(x,y).slice(0,8).map(n=>({tag:n.tagName,id:n.id,cls:n.className}))})}"
    wwbody "$WID"
    wwhost "$WID" display
  } >> "$OUT/tap-diagnostics.log" 2>&1
  "$A" shell dumpsys input > "$OUT/input-$label.txt" 2>> "$OUT/native-errors.log"
  native_snapshot || true
}

# Chrome has its own devtools socket. Never read fullscreen state from home's WebView.
chrome_cdp() {
  CDP_TIMEOUT_S=8 cdp_warm_run "$FORWARD" "$@"
}
page_ready() {
  local result rc=0
  result=$(chrome_cdp eval "$URL" "typeof tbProbe === 'function' ? tbProbe('$1', '$TOKEN') : {ok:false,href:location.href,state:document.readyState,error:'fixture missing'}") || rc=$?
  printf '%s\n' "$result" >> "$OUT/navigation.log"
  [ "$rc" = 0 ] || return 1
  printf '%s' "$result" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,dict) and d.get("ok") is True else 1)' 2>/dev/null
}
require_page() {
  until_ 8 "page_ready $1" && { say "Chrome document confirmed: $1 ($URL)"; return; }
  native_snapshot || true
  chrome_cdp pages >> "$OUT/navigation.log" 2>&1 || true
  ww_us "cat '$PAGE/server.log'" >> "$OUT/server.log"
  bad "precondition $1: Chrome document not ready/fullscreen transition unconfirmed; see navigation.log and server.log (no native verdict)"
  wwc_end
}
wwc_start
. "$T/cdp-warm.sh"
# Like window-max.sh: Python in the PowOS chroot shares Android's loopback.
# adb reverse terminates in powos-vadb's namespace, NOT the Mac's localhost.
PAGE=$(ww_us "mktemp -d /tmp/titlebar-$TOKEN.XXXXXX")
case "$PAGE" in /tmp/titlebar-"$TOKEN".*) ;; *) bad "delivery: no owned phone directory ($PAGE)"; wwc_end ;; esac
SERVER_OWNED=1
HTML=$(base64 < "$T/verify/titlebar-page.html" | tr -d '\n')
SERVER=$(base64 < "$T/verify/titlebar-server.py" | tr -d '\n')
ww_us "mkdir '$PAGE/$TOKEN'; printf %s '$HTML' | base64 -d > '$PAGE/$TOKEN/tb.html'; printf %s '$SERVER' | base64 -d > '$PAGE/server.py'; setsid -f timeout 245 python3 -u '$PAGE/server.py' '$PAGE' >'$PAGE/server.log' 2>&1 </dev/null; for i in 1 2 3 4 5 6 7 8; do [ -s '$PAGE/port' ] && break; sleep 0.25; done; cat '$PAGE/port'" > "$OUT/server-start.txt"
PORT=$(tail -1 "$OUT/server-start.txt")
case "$PORT" in ''|*[!0-9]*) bad "delivery: phone server failed (see server-start.txt)"; wwc_end ;; esac
URL=http://127.0.0.1:$PORT/$TOKEN/tb.html
say "delivery: phone-local server $URL ($PAGE, bounded 240 s)"
chrome_claim   # parent shell, immediately before launch; ownership survives ww_open's command substitution
WID=$(ww_open "a:$CHROME" 40) || { bad "open Chrome: $WID"; wwc_end; }
MINE_W="$MINE_W $WID"; say "opened Chrome as $WID"
D=$(wwhost "$WID" display)
sh_ "am start --display $D -a android.intent.action.VIEW -d $URL -p $CHROME" > "$OUT/navigation-start.txt"
FORWARD=$("$A" forward tcp:0 localabstract:chrome_devtools_remote | tr -d '\r')
case "$FORWARD" in ''|*[!0-9]*) FORWARD=""; bad "delivery: Chrome CDP forward failed"; wwc_end ;; esac
require_page load
ev "importShim('./ui/webwindows.tsx').then(m=>{const w=m.webWins.value.find(w=>w.id===${WID#w});if(w&&!w.restore)m.toggleMaximise(w.id);return 'ok'})" >/dev/null
require_page load
until_ 8 laid || bad "control: maximised, not immersive - its bar isn't laid out (bar '$(part .webwindow-title)', body '$(part .webwindow-body)')"
mark_native || { bad "precondition native timestamp: invalid/failed device date (see native-errors.log); no native verdict"; wwc_end; }
c=$(wwbody "$WID"); set -- $c; cx=$(( ($1 + $3) / 2 )) cy=$(( ($2 + $4) / 2 ))
sh_ "input tap $cx $cy"; say "tapped the page at $cx $cy (full screen)"
require_page enter
until_ 4 hid || bad "hide: 2 s after the app went full screen its bar isn't auto-hidden (bar '$(part .webwindow-title)', body '$(part .webwindow-body)')"
logged "hides its status bar (immersive)" || bad "hide: the host never logged the app's immersive request"
logged "TB1: status bar hidden" || bad "hide: the host never hid the status bar"
before=$(part .webwindow-body)
sh_ "input swipe $cx 4 $cx 260 250"; say "swiped down from the top edge at x $cx"
until_ 2 shown || bad "reveal: a swipe from the top didn't slide the bar in"
native_snapshot || bad "evidence: native reveal log capture failed (see native-errors.log)"
[ "$(part .webwindow-body)" = "$before" ] || bad "reveal: the body moved ('$before' -> '$(part .webwindow-body)'): the bar relaid the app out"
sleep 4
shown && bad "idle: the slid-in bar still shows 4 s later"
require_page enter
tap_diagnostics before-exit
sh_ "input tap $cx $cy"; say "tapped the page again (leave full screen)"
tap_diagnostics after-exit
require_page exit
until_ 4 laid || bad "leave: 2 s after the app left full screen its bar isn't back (bar '$(part .webwindow-title)')"
until_ 4 'logged "TB1: status bar back"' || bad "leave: the host never showed the status bar again"
wwc_end "maximised Chrome: bar auto-hid on its full screen, a top swipe slid it in over the app, it hid again, back on leaving"
