# shellcheck shell=bash
# tools/phone/verify/e2e-lib.sh (sourced by e2e-desktop.sh, e2e-appapi.sh): "use the phone like a user" journeys as
# queue jobs. Real injected taps and swipes at spots read over read-only CDP; one screenshot per step on the phone
# (/home/powos/design-qa/e2e-<journey>/<round>/NN-<step>.png) with a steps.txt line each (file, what was done,
# PASS/FAIL); the manager looks at them as a user. Rules kept here so both journeys keep them:
#   - NEVER a touch on the verify status pill (VerifyRun.kt "PowOS verify status", top centre): every DOWN is checked
#     against its window frame (+48 px) right before it is made, and refused (a FAIL line, no touch) inside it;
#   - only while the user is idle (manager rule): e2e_idle_gate before each journey (part) - the last user input > 120 s
#     ago and the screen Awake, else "journey <name>: skipped - user active N s ago"; a touch during it (a hardware
#     touch-down on a panel's evdev node, which injected input never goes through - e2e_touchwatch/touched(), at every
#     chk and step) stops it at once: "journey <name>: aborted - the user touched the phone", the restore runs. Both
#     exit 3 (the runner re-queues it; not a FAIL) and land in the round's skipped.txt, which the last part's mail names;
#   - only what the journey opened is closed (new tasks of its apps, Linux apps it started); the page, the screen state
#     and the app in front it started from come back; the layout (home.get + home.wide) must be the same at the end;
#   - a step's FAIL doesn't end the journey (more screenshots for the manager): exit 0 with FAIL lines = a FAIL.
# A journey longer than its queue budget (e2e-queue.sh: 450 s) runs as parts (--part K of LAST): each part is its own job, numbers
# its steps from (K-1)*25+1, replaces only its own files and steps.txt lines; the last part mails the manager.
#   e2e_args "$@"; e2e_init <journey>; e2e_setup [inner]; ... step/pass/fail ...; e2e_finish
here=${here:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}; T=$here/..; A="$T/adb.sh"
E2E_UID=10359   # the PowOS session user (review-image.sh)
L=$HOME/.cache/powos-verify.lock
# TEST_APP (f107): the one window-checks test app, instead of 15+ checks each hard-coding com.oneplus.calculator.
# Same default on the phone and the emulator: tools/emu/testwin is built AS this package id, so --dev emu needs no
# override; a check that doesn't source e2e-lib.sh still falls back to the same default (${TEST_APP:-...}).
TEST_APP=${TEST_APP:-com.oneplus.calculator}

# Command-only calls must not drain a surrounding read loop (cleanup must visit every task).
sh_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
# ash: a script on stdin as Android root (any quoting inside).
ash() { "$A" shell "su -c 'sh -s'" 2>/dev/null | tr -d '\r'; }
# device_state_set <state>: set fold state; on emu, state 3 (inner) is a no-op, state 0 (cover) prints SKIP.
device_state_set() {
  case "${POWOS_DEVICE:-phone}" in
    emu) case $1 in 3|inner|unfolded) ;; 0|cover|folded) echo "SKIP emu has no cover screen" ;; *) ;; esac ;;
    *) sh_ "cmd device_state state $1" ;;
  esac
}
# device_state_reset: reset fold state to hinge; on emu, a no-op.
device_state_reset() {
  case "${POWOS_DEVICE:-phone}" in emu) ;; *) sh_ "cmd device_state state reset" ;; esac
}
# us: a script text inside PowOS as the session user (user.sh).
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
# --- the user's idle time and their touches (manager rule: a journey runs only while the user is idle) ----------------
# A REAL finger only, told by the touch panels' own evdev nodes: `input tap/swipe/motionevent` goes into InputDispatcher
# and never through /dev/input, so the journey's injected input can't look like the user. The two old signals both
# gave false aborts (round 190, 2026-11-01: every part aborted 3-20 s in, nobody at the phone):
#   - dumpsys power's lastUserActivityTime moves on injected input, app launches, window changes and the setup's wake;
#   - the touch IRQs (touch-00 / touch-01 in /proc/interrupts) move on a panel's power-up: "touch seen at unfold:
#     irq=967 (irq at start 963)" with no finger.
# e2e_touchwatch: one root watcher on the phone (kept across jobs; restarted when gone) runs getevent (it takes one
# device or all: all, filtered to the panels) and keeps every panel that has ABS_MT_POSITION_X ("touchpanel" event8 inner + "touchpanel1" event11 cover on the Open) and counts each
# BTN_TOUCH DOWN into $E2E_TW: "<downs> <boot s of the last down, 0 = none> <boot s the watch started>".
E2E_TW=/data/local/tmp/powos-e2e-touch
e2e_touchwatch() {
  [ "${POWOS_DEVICE:-phone}" = emu ] && return 0
  ash <<EOF
p=\$(cat $E2E_TW.pid 2>/dev/null)
[ -n "\$p" ] && kill -0 "\$p" 2>/dev/null && grep -q getevent /proc/\$p/cmdline 2>/dev/null && exit 0
d=\$(getevent -pl 2>/dev/null | awk '/^add device/{n=\$4} /ABS_MT_POSITION_X/{print n}' | tr '\n' ' ')
[ -n "\$d" ] || { echo "touchwatch: no touch panel found"; exit 1; }
read u r < /proc/uptime; echo "0 0 \$u" > $E2E_TW; chmod a+r $E2E_TW
nohup setsid sh -c "echo \\\$\\\$ > $E2E_TW.pid; getevent -lq | awk -v F=$E2E_TW -v S=\$u -v D='\$d' 'BEGIN{split(D,x,\" \"); for(k in x) P[x[k] \":\"]=1} (\\\$1 in P) && /BTN_TOUCH/ && /DOWN/{getline t < \"/proc/uptime\"; close(\"/proc/uptime\"); split(t,a,\" \"); n++; print n, a[1], S > F; close(F)}'" </dev/null >/dev/null 2>&1 &
sleep 0.3; echo "touchwatch: started on \$d"
EOF
}
# irq: the hardware touch-down count ("" on the emulator, -1 when the watcher isn't running).
irq() { useract | sed -nE 's/.*irq=(-?[0-9]*).*/\1/p'; }
# useract: one read-only call -> "idle=<s> wake=<Awake|Dozing|..> hw=<s> irq=<n>". hw: seconds since the last hardware
# touch-down (or since the watch started, when none since). idle = the larger of hw and the power idle (seconds since
# dumpsys power's newest lastUserActivityTime*, "now" in that clock = mLastWakeTime + its "ms ago"): a real touch
# moves both, so each is a lower bound of the user's real idle time; injected input/wakes only pull the power one down.
# irq: the watcher's touch-down count (-1: no watcher). Unreadable -> idle=-1 (not idle). Never wakes the screen.
useract() {
  [ "${POWOS_DEVICE:-phone}" = emu ] && { echo "idle=86400 wake=Awake hw= irq="; return; }
  sh_ "read b r < /proc/uptime; echo B \$b; p=\$(cat $E2E_TW.pid 2>/dev/null); [ -n \"\$p\" ] && kill -0 \$p 2>/dev/null && grep -q getevent /proc/\$p/cmdline 2>/dev/null && echo H \$(cat $E2E_TW); dumpsys power | grep -E \"mWakefulness=|mLastWakeTime=|astUserActivityTime\"" | awk '
    /^B /{b=$2} /^H /{hn=$2; ht=($3>0?$3:$4); h=1}
    /mWakefulness=/ && w==""{sub(/.*mWakefulness=/,""); w=$1}
    /mLastWakeTime=/{split($0,a,/[=( ]+/); for(k in a) if(a[k]=="mLastWakeTime") t=a[k+1]; if(match($0,/\(([0-9]+) ms ago/)) now=t+substr($0,RSTART+1,RLENGTH-8)}
    /astUserActivityTime/{v=$0; sub(/^[^=]*=/,"",v); v=v+0; if(v>last) last=v}
    END{ idle=-1; if(now>0 && last>0) idle=int((now-last)/1000)
      hw=""; if(h && b>0){ hw=int(b-ht); if(hw>idle) idle=hw }
      printf "idle=%s wake=%s hw=%s irq=%s\n", idle, (w==""?"?":w), hw, (h?hn:-1) }'
}
# e2e_idle_gate: before the journey - the user idle > E2E_IDLE_S (120) s and the screen Awake (asleep()'s rule: the
# check never wakes it). Not idle: "journey <name>: skipped - user active N s ago" in the log, steps.txt and the round's
# skipped.txt, and exit 3 - the runner puts it back for the next window (not a FAIL).
e2e_jname() { echo "e2e-$JOURNEY part $PART/$LAST"; }
e2e_idle_gate() {
  e2e_touchwatch | while read -r l; do log "$l"; done
  local r idle wake why=; r=$(useract); idle=$(sed -nE 's/.*idle=(-?[0-9]+).*/\1/p' <<<"$r"); wake=$(sed -nE 's/.*wake=([^ ]*).*/\1/p' <<<"$r")
  log "idle check: $r (need idle > ${E2E_IDLE_S:-120} s, Awake)"
  if [ "${wake:-?}" != Awake ] && [ "$wake" != "?" ]; then why="the screen is $wake (not woken - rule)"
  elif [ "${idle:--1}" -lt 0 ]; then why="user activity unreadable ($r)"
  elif [ "$idle" -le "${E2E_IDLE_S:-120}" ]; then why="user active $idle s ago"; fi
  [ -z "$why" ] && return 0
  e2e_skip "journey $(e2e_jname): skipped - $why"
}
# e2e_skip <line>: a journey that didn't run / stopped for the user - logged, a SKIP line in steps.txt and the round's
# skipped.txt on the phone (e2e_finish reports it), exit 3 (re-queued; not a FAIL). e2e_abort restores and publishes.
e2e_skip() {
  log "$1"; _res SKIP "$1"
  [ -n "${PDIR:-}" ] && printf '%s\n' "$(date +%H:%M:%S) $1" | "$A" shell "su -c 'mkdir -p $PDIR; cat >> $PDIR/skipped.txt; chmod a+r $PDIR/skipped.txt'" >/dev/null 2>&1
  echo "SKIP: $1"; exit 3
}
# touched [where]: the user touched the phone during the journey - the hardware touch-down count (e2e_touchwatch) moved
# from I0, its value at the start. Injected input, wakes, unfolds and app launches don't move it. Checked by chk and
# before every step. Then: no more input, the journey's own put-away (e2e_abort -> e2e_restore), exit 3. The watcher
# gone (-1): restarted and counted from there (logged), not taken as a touch.
touched() {
  local r q; r=$(useract); q=$(sed -nE 's/.*irq=(-?[0-9]+).*/\1/p' <<<"$r")
  if [ "$q" = -1 ] && [ -n "${I0:-}" ]; then e2e_touchwatch >/dev/null; I0=$(irq); log "touch watch was gone at ${1:-a step} - restarted (count $I0)"; return 0; fi
  if [ -n "$q" ] && [ -n "${I0:-}" ] && [ "$q" != "$I0" ]; then
    sh_ "input motionevent CANCEL 1 1" >/dev/null 2>&1
    log "touch seen at ${1:-a step}: $r (touch-downs at start ${I0:-?})"
    e2e_skip "journey $(e2e_jname): aborted - the user touched the phone"
  fi
}
chk() { touched "$1"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }

. "$here/ww-lib.sh"  # ev, hcall, and the web-window helpers (WWRECTS, wwel, wwrect, wwhost)
hemit() { ev "(window.__powosHost.emit('$1', $2), 'ok')" >/dev/null; sleep 1.2; }
# Home's state: the page (state.ts page: -1 = PowOS AI's), the drawer, edit mode.
hpage() { ev 'importShim("./state.ts").then(m=>String(m.page.value))'; }
setpage() { ev "importShim('./state.ts').then(m=>{m.page.value=$1;return 'ok'})" >/dev/null; sleep 1; }
isopen() { ev '!!document.querySelector(".home.open")'; }
isediting() { ev '!!document.querySelector(".home.editing")'; }
ime() { sh_ "dumpsys input_method | grep -m1 -o mInputShown=[a-z]*"; }
layout() { { hcall home.get "[]" "h=>JSON.stringify(h)"; hcall store.get "['home.wide']" "w=>JSON.stringify(w)"; } | cksum | cut -d' ' -f1; }

# The status pill's window (left top right bottom), "" when it isn't up.
pillrect() { sh_ "dumpsys window windows" | awk '/^ *Window #/{f=(index($0,"PowOS verify status")>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' '; }
# offpill <x> <y> <what>: 0 when the spot is clear of the pill (48 px around it); else a FAIL line and 1 - no touch.
offpill() {
  local r; r=$(pillrect); [ -n "$(echo $r)" ] || return 0
  set -- "$1" "$2" "$3" $r
  if [ "$1" -lt $(($4 - 48)) ] || [ "$1" -gt $(($6 + 48)) ] || [ "$2" -lt $(($5 - 48)) ] || [ "$2" -gt $(($7 + 48)) ]; then return 0; fi
  fail "not touched: $3 at $1,$2 is under the verify status pill ($4,$5 $6,$7)"; return 1
}
tap() { offpill "$1" "$2" "$3" || return 1; log "tap $3 at $1,$2"; sh_ "input tap $1 $2"; }
swipe() { offpill "$1" "$2" "$6" || return 1; log "swipe $6 $1,$2 -> $3,$4 ($5 ms)"; sh_ "input swipe $1 $2 $3 $4 $5"; }
press() { offpill "$1" "$2" "$4" || return 1; log "hold $4 at $1,$2 ($3 ms)"; sh_ "input swipe $1 $2 $1 $2 $3"; }
mdown() { offpill "$1" "$2" "$3" || return 1; sh_ "input motionevent DOWN $1 $2"; }
mmove() { sh_ "input motionevent MOVE $1 $2"; }
mup() { sh_ "input motionevent UP $1 $2"; }
# mpath <x0> <y0> <x1> <y1> <n>: n MOVEs from (x0,y0) towards (x1,y1), in one adb call (a finger, not a crawl).
mpath() { local i c=""; for i in $(seq 1 "$5"); do c="$c input motionevent MOVE $(($1 + ($3 - $1) * i / $5)) $(($2 + ($4 - $2) * i / $5));"; done; sh_ "$c"; }
back() { sh_ "input keyevent 4"; sleep "${1:-0.8}"; }

# pt <js expression of an element>: its centre in device px "x y", "none" (no element) or "off" (off screen / hidden).
pt() { ev "(()=>{const e=($1);if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;if(r.width<2||r.height<2||r.bottom<1||r.top>innerHeight-1||r.right<1||r.left>innerWidth-1)return 'off';return Math.round((r.x+r.width/2)*d)+' '+Math.round((r.y+r.height/2)*d)})()"; }
# Home's search, by the current rules (26e5c496/a481983d SW1): a bar on home (unfolded by default) is tapped in its
# field; a search docked as the dock's button (folded by default) is tapped and opens the launcher with the bar
# focused. searchpt: "x y" of what to tap, or none/off. SEARCHED: the field the keyboard is in after it.
SEARCHPT="(document.querySelector('.home > .bar textarea')&&document.querySelector('.home > .bar').getBoundingClientRect().height>2?document.querySelector('.home > .bar textarea'):document.querySelector('.home .dock .app.dock-search'))"
SEARCHED="document.activeElement&&document.activeElement.matches('.bar textarea')?'yes':'no'"
# homefocused: home (com.powos.app) holds the input focus on ANY display. Never `grep -m1 mCurrentFocus`: dumpsys lists a
# web window's or KWin's virtual display first (its mCurrentFocus=null), so a focused search read as unfocused (e2e
# round 193, appapi 01/02 folded: the page had the focus and asked for the keyboard).
homefocused() { sh_ "dumpsys window | grep mCurrentFocus" | grep -q com.powos.app; }
searchpt() { pt "$SEARCHPT"; }
# searchresult <app key>: "x y" of that app in the launcher's search results, or none/off. The results are buttons
# [data-search-result="app:<key>"] (drawer.tsx SearchResults, since e7766370) - the old `.app[data-key]` probe found
# nothing there and failed Kate/App API/Lights though they were on screen (E2E 194). Scrolled into view first: a long
# list can hold it past the panel's edge.
searchresult() { pt "(e=>(e&&e.scrollIntoView({block:'nearest'}),e))(document.querySelector('.drawer-list.results [data-search-result=\"app:$1\"]'))"; }
# A dock cell by its key prefix (read only).
dockel() { echo "[...document.querySelectorAll('.home .dock .app[data-key]')].find(a=>a.dataset.key.startsWith('$1'))"; }
# winrects: every window on screen now (windows.list: not minimised, not on another page), "l t r b,l t r b" in device px.
# Both window models: the old floating tasks (windows.list) and the web windows (W1: .webwindow elements of home's page,
# docs/WEB_WINDOWS.md) - round 189 read only windows.list, saw [] with Chrome open as a web window, and pulled/held on it.
winrects() { local v w; v=$(hcall windows.list "[]" "l=>l.filter(w=>!w.minimised&&!w.away&&w.bounds).map(w=>w.bounds.join(' ')).join(',')"); case $v in ERR*) v="" ;; esac
  w=$(ev "$WWRECTS"); case $w in none|ERR*|"") ;; *) v=${v:+$v,}$w ;; esac; echo "$v"; }
# freept <window bounds or ""> <way -1|1|0> <length> [min x, 0..1] [min y, 0..1]: an empty spot on home's page (no tile,
# app, bar, dock; outside the window) with room for a sideways swipe that long (float-touch.sh's: a short swipe doesn't
# turn a page). Never under ANY window on screen: elementFromPoint sees only home's page, so a spot under a floating
# window (Chrome left up, a stray Kate) read as empty and the touch went to that window (the drawer's stages, rounds 1-3).
freept() {
  # Besides the 4% grid, the columns just outside each window's sides are tried: a window grown to 1800 of 2268 px
  # left its only roomy spot (2086-2116, between it and the side dock) between grid columns, so a 116 px swipe from
  # the left gap was all the check did and the page "didn't change" (e2e-desktop 1029-1430 [36-page2]).
  local ws; ws=$(winrects)
  ev "(()=>{const b='$1'.split(' ').filter(Boolean).map(Number),ws='$ws'.split(',').filter(Boolean).map(s=>s.split(' ').map(Number)),r=devicePixelRatio,d=${2:-0},len=${3:-0},W=innerWidth*r;let best=null,room=-1;const x0=innerWidth*${4:-.06},xs=[];for(let x=${4:-.06};x<=.94;x+=.04)xs.push(innerWidth*x);for(const w of [b,...ws])if(w.length===4)for(const e of [(w[2]+61)/r,(w[0]-61)/r])if(e>=x0&&e<innerWidth)xs.push(e);for(let y=${5:-.2};y<=.75;y+=.05)for(const cx of xs){const cy=innerHeight*y,px=cx*r,py=cy*r;if(b.length===4&&px>=b[0]-60&&px<=b[2]+60&&py>=b[1]-120&&py<=b[3]+60)continue;if(ws.some(w=>px>=w[0]-40&&px<=w[2]+40&&py>=w[1]-140&&py<=w[3]+40))continue;const e=document.elementFromPoint(cx,cy);if(!e||!e.closest('.page-track'))continue;if(e.closest('.webwindow,.tile,.home-tile,.app,.panel,.widget,.island,.owl,button,a,input,textarea,.bar,.dock,[data-key]'))continue;const m=d<0?px-20:d>0?W-20-px:len;if(m>=len)return Math.round(px)+' '+Math.round(py);if(m>room){room=m;best=Math.round(px)+' '+Math.round(py)}}return best||'none'})()"
}

# Tasks and windows.
tasks() { sh_ "am stack list" | grep -E 'taskId=[0-9]+:' | sed -nE 's/.*taskId=([0-9]+): ([^ ]+).*(visible=(true|false)).*/\1 \2 \4/p'; }
tvis() { case $1 in w*) [ -n "$(wwrect "$1")" ] && [ "$(wwhost "$1" state)" = floating ] && echo true || echo false; return ;; esac
  sh_ "am stack list" | grep -E "taskId=$1:" | grep -oE 'visible=(true|false)' | head -1 | cut -d= -f2; }
tbounds() { case $1 in w*) wwrect "$1"; return ;; esac
  sh_ "am stack list" | grep -E "taskId=$1:" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ' | xargs; }
# win <key: pkg or l:app> <field>: id | minimised | away | bounds | front. A web window first (id "w<id>"; front = the
# top .webwindow in its page's DOM order), else the old floating window (windows.list, front first).
win() {
  local v; v=$(hcall webwindows.list "[]" "l=>{const K='$1',w=l.filter(w=>w.key===K||w.key==='a:'+K||w.key.startsWith('a:'+K+'/')).pop();if(!w)return 'none';const f='$2',e=document.querySelector('.webwindow[data-wwid=\"'+w.id+'\"]'),r=e&&e.getBoundingClientRect(),on=!!r&&r.width>2&&r.right>0&&r.left<innerWidth&&r.bottom>0&&r.top<innerHeight,d=devicePixelRatio;if(f==='id')return 'w'+w.id;if(f==='minimised')return String(w.state==='minimised');if(f==='away')return String(w.state==='floating'&&!on);if(f==='bounds')return on?[r.left,r.top,r.right,r.bottom].map(v=>Math.round(v*d)).join(' '):'';if(f==='front'){const s=e&&e.parentElement?[...e.parentElement.querySelectorAll(':scope > .webwindow[data-wwid]')]:[];return String(!!e&&s[s.length-1]===e)}return String(w[f])}")
  case $v in none|ERR*|"") ;; *) echo "$v"; return ;; esac
  hcall windows.list "[]" "l=>{const w=l.find(w=>w.pkg==='$1'||w.app==='$1');if(!w)return 'none';const f='$2';return f==='bounds'?(w.bounds||[]).join(' '):f==='front'?String(l.find(x=>!x.minimised&&!x.away)===w):String(w[f])}"
}
# waitwin <key> <s>: up to s seconds for its window; prints its id (a task, or "w<id>" for a web window) or "none".
waitwin() { local i id=none; for i in $(seq 1 "$2"); do id=$(win "$1" id); [ "$id" != none ] && [ -n "$id" ] && case $id in ERR*) ;; *) break ;; esac; id=none; sleep 1; done; echo "$id"; }
# wgone <id>: true when that window is gone (a task: not in am stack list; a web window: not in webwindows.list).
wgone() { case $1 in w*) [ "$(wwhost "$1" gone)" = true ] ;; *) [ -z "$(tasks | grep "^$1 ")" ] ;; esac; }
# wframe <title text>: that window's frame (a plain substring: "PowOS window bar 12}" - the } ends the title).
wframe() { sh_ "dumpsys window windows" | awk -v p="$1" '/^ *Window #/{f=(index($0,p)>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' ' | xargs; }
dp() { echo $(($1 * DENS / 160)); }
# shadeup: "up" while PowOS's shade window shows (open, or a banner), else "down". `cmd statusbar collapse` only reaches
# SystemUI's panel, never PowOS's shade: 11-02 render-scan closed it that way, left it open (invisible to home's DOM
# checks), and the next journey's first tap (search-setting 01-inner-dock: 0 pointerdowns on home, the shade's window
# took focus) went to the shade instead of Settings.
# Up = shown and touchable (a reload's alpha-0 window takes no touch: not up).
shadeup() { sh_ "dumpsys window windows" | awk '/^ *Window #/{f=(index($0,"PowOS shade}")>0)} f && / fl=/{nt=(index($0,"NOT_TOUCHABLE")>0)} f && /mViewVisibility=/{print ((index($0,"mViewVisibility=0x0 ")>0 && !nt) ? "up" : "down"); exit}'; }
# shade_shut [why]: PowOS's shade put away by the user's routes - Back (the open shade has focus), then Home (its
# CLOSE_SYSTEM_DIALOGS "homekey" settles it shut); logged when it was up.
shade_shut() {
  [ "$(shadeup)" = up ] || return 0
  sh_ "input keyevent 4"; sleep 1.2
  [ "$(shadeup)" = up ] && { sh_ "input keyevent 3"; sleep 1.5; }
  log "PowOS's shade was down at ${1:-a step}: put away (Back/Home) - now $(shadeup)"
}
# screenrect "l t r b": a SurfaceFlinger HWC rect (Disp Frame: the panel's own orientation) in screen px. The inner
# screen is mounted at 270 (installOrientation 3): its raw rects are the window's turned (window-rec/window-live read
# Calculator's content at "437 431 2145 1791" for a task at 477 437 1837 2145, 2026-10-23). Needs W, H (e2e_setup).
screenrect() { set -- $1; [ $# -ge 4 ] || { echo "$*"; return; }
  [ -n "${INST:-}" ] || INST=$(sh_ "dumpsys display" | grep -E "^  DisplayDeviceInfo" | grep " state ON," | grep -oE "installOrientation [0-3]" | head -1 | cut -d" " -f2)
  case ${INST:-0} in 3) echo "$((W - $4)) $1 $((W - $2)) $3" ;; 1) echo "$2 $((H - $3)) $4 $((H - $1))" ;; 2) echo "$((W - $3)) $((H - $4)) $((W - $1)) $((H - $2))" ;; *) echo "$*" ;; esac; }
# closebtn <task>: its title bar's close button (21 dp from the bar's right), "x y" or "".
closebtn() { case $1 in w*) wwpt "$1" .ww-close; return ;; esac; local b; b=$(wframe "PowOS window bar $1}"); [ -n "$b" ] || return 0; set -- $b; echo "$(($3 - $(dp 21))) $((($2 + $4) / 2))"; }
# wwpt <w-id> <selector>: the centre of that element inside the web window, "x y" device px, or "".
wwpt() { local v; v=$(wwel "$1" "e=>{const b=e.querySelector('$2');if(!b)return '';const r=b.getBoundingClientRect(),d=devicePixelRatio;return r.width<1?'':Math.round((r.left+r.width/2)*d)+' '+Math.round((r.top+r.height/2)*d)}"); [ "$v" = none ] || echo "$v"; }
# minbtn <w-id>: a web window's title-bar minimise button, "x y" device px or "".
minbtn() { case $1 in w*) wwpt "$1" ".ww-button[aria-label=Minimise]" ;; esac; }
# hitat <x> <y>: what the page's hit test finds at that device-px point ("tag.class.es" or "none") - a grip's log line.
hitat() { ev "(()=>{const d=devicePixelRatio,e=document.elementFromPoint($1/d,$2/d);return e?e.tagName.toLowerCase()+'.'+String(e.className&&e.className.baseVal!==undefined?e.className.baseVal:e.className).trim().split(/ +/).join('.'):'none'})()"; }
# grippt <id>: its resize grip (bottom right), "x y" or "" - a web window's .ww-grip-br, else the old grip window.
grippt() { case $1 in w*) wwpt "$1" ".ww-grip-se"; return ;; esac; local g; g=$(wframe "PowOS window grip $1}"); [ -n "$g" ] || return 0; set -- $g; echo "$((($1 + $3) / 2)) $((($2 + $4) / 2))"; }
# barpt <task>: a spot on its title bar for a drag: the left part, away from the buttons, clear of the pill if it can.
barpt() { case $1 in w*) local t; t=$(wwel "$1" "e=>{const b=e.querySelector('.webwindow-title');if(!b)return '';const r=b.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width/4)*d)+' '+Math.round((r.top+r.height/2)*d)}"); [ "$t" = none ] || echo "$t"; return ;; esac
  local b x r; b=$(wframe "PowOS window bar $1}"); [ -n "$b" ] || return 0; set -- $b
  r=$(pillrect); x=$(($1 + ($3 - $1) / 4))
  if [ -n "$(echo $r)" ]; then set -- "$@" $r; [ "$x" -ge $(($5 - 60)) ] && [ "$x" -le $(($7 + 60)) ] && x=$(($1 + $(dp 24))); fi
  echo "$x $((($2 + $4) / 2))"; }

# --- the journey's frame -----------------------------------------------------------------------------------------
# e2e_args "$@": --round R (default: a time stamp) --part K --of LAST --android-only (skip any Linux-session step:
# the emulator lane has no KWin/Kate/Plasma; ANDROID_ONLY=1 for the journey to check and skip by, noting why instead
# of failing - handbook "The emulator lane").
e2e_args() {
  ROUND=$(date +%m%d-%H%M); PART=1; LAST=1; ANDROID_ONLY=0
  while [ $# -gt 0 ]; do case "$1" in --round) ROUND=$2; shift 2 ;; --part) PART=$2; shift 2 ;; --of) LAST=$2; shift 2 ;;
    --android-only) ANDROID_ONLY=1; shift ;; *) shift ;; esac; done
  [[ $ROUND =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad --round $ROUND"; exit 2; }
}
# skip_linux <slug> <what it would have done>: --android-only's way of leaving out a Linux-session step - a NOTE, not
# a FAIL (the emulator has no Linux session to test it with; the phone run still covers it).
skip_linux() { step "$1" "$2"; note "skipped: --android-only (no Linux session on this lane)"; }
e2e_init() {
  JOURNEY=$1; LO=$(((PART - 1) * 25 + 1)); HI=$((PART * 25)); N=$((LO - 1)); NPASS=0; NFAIL=0; NSKIP=0; DONE=0; APID0=
  CUR=setup; CURD=setup; CURX=
  UDIR=/home/powos/design-qa/e2e-$JOURNEY/$ROUND; PDIR=/data/powos/root$UDIR
  OUT=$HOME/.cache/powos-verify/e2e-$JOURNEY-$ROUND; mkdir -p "$OUT"; STEPS=$OUT/steps-$PART.txt; : > "$STEPS"; : > "$OUT/log.txt"
  log "$JOURNEY round $ROUND part $PART of $LAST: steps $LO-$HI to $UDIR"
  # This part's earlier files (a re-queued try) go; the other parts' stay.
  ash <<EOF
mkdir -p $PDIR; cd $PDIR && for f in [0-9][0-9]-*.png; do [ -e "\$f" ] || continue; n=\${f%%-*}; n=\${n#0}; [ "\$n" -ge $LO ] && [ "\$n" -le $HI ] && rm -f "\$f"; done; true
EOF
}
# step <slug> <what the user does / sees>: the screenshot of this step, now.
step() {
  [ -n "${I0:-}" ] && touched "step $1"
  [ $N -lt $HI ] && N=$((N + 1)); CUR=$(printf '%02d-%s.png' "$N" "$1"); CURD=$2; CURN=0
  echo "-- $CUR: $2"
  "$T/shot.sh" --phone "$PDIR/$CUR" >/dev/null 2>&1; local rc=$?
  [ $rc = 0 ] || { [ $rc = 4 ] && CURX=" (screenshot came back blank)" || CURX=" (no screenshot, rc $rc)"; }
  [ $rc = 0 ] && CURX=""
  [ -n "$APID0" ] || APID0=$(apppid)
}
# A detail with a newline (a page's innerText) was cut at it in steps.txt and the log: flatten control chars to spaces.
_res() { local m=${2//[[:cntrl:]]/ }; printf '%s\t%s%s\t%s: %s\n' "$CUR" "$CURD" "$CURX" "$1" "$m" >> "$STEPS"; echo "$1: [${CUR%.png}] $m" | tee -a "$OUT/log.txt"; }
pass() { NPASS=$((NPASS + 1)); _res PASS "$*"; }
# Evidence (2026-10-28): the phone's logcat ring wraps in ~1 min, so a FAIL left nothing to diagnose from. The journey keeps
# its own window/shell log ($PDIR/logcat-<part>.txt, e2e_logcat_start); a FAIL copies its last 400 lines next to the
# step's screenshot (NN-step.logcat.txt) and names the file in the FAIL line.
LOGCAT_TAGS="PowosShade:V PowosSwitcher:V PowosDock:V PowosWebWindows:V PowosWindowFrames:V WindowTasks:V PowosWindow:V PowosFreeform:V PowosPageSlide:V PowosRunning:V PowosShell:V chromium:D"
e2e_logcat_start() {
  [ -n "${PDIR:-}" ] || return 0
  ash <<EOF
mkdir -p $PDIR; f=$PDIR/logcat-$PART.txt; [ -f \$f.pid ] && kill \$(cat \$f.pid) 2>/dev/null
: > \$f; nohup logcat -v time -s $LOGCAT_TAGS > \$f 2>&1 < /dev/null &
echo \$! > \$f.pid; chmod a+r \$f
EOF
}
e2e_logcat_stop() {
  [ -n "${PDIR:-}" ] || return 0
  ash <<EOF
f=$PDIR/logcat-$PART.txt; [ -f \$f.pid ] && kill \$(cat \$f.pid) 2>/dev/null; : > \$f.pid; chmod -R a+rX $PDIR
EOF
}
# A step interrupted is not judged (round 203, 11-01: six FAILs from a doze, a user touch and an APK install that
# restarted PowOS mid-step - "Kate from search: window w3, bounds " was the new process's empty window list). On a
# failing check, interrupted() says why the step couldn't be judged: the screen not Awake or the keyguard up (asleep()'s
# rule from window-render.sh, incl. the 11-01 keyguard rule: a locked phone draws no app), its screenshot refused for
# that (shot.sh rc 3), a real touch-down since the start (the touch guard's count), or PowOS's process not the one the
# journey started with (an install or a crash: its windows are gone). Never wakes the screen.
apppid() { sh_ "pidof com.powos.app" | awk '{print $1}'; }
interrupted() {
  [ "${POWOS_DEVICE:-phone}" = emu ] && return 1
  local w q p; w=$("$A" shell "dumpsys power | grep -m1 mWakefulness=" </dev/null 2>/dev/null | tr -d '\r ' | cut -d= -f2)
  if [ -n "$w" ] && [ "$w" != Awake ]; then echo "the screen is $w"; return 0; fi
  "$A" shell "dumpsys window | grep -m1 isKeyguardShowing" </dev/null 2>/dev/null | grep -q "isKeyguardShowing=true" && { echo "the phone is locked (keyguard up)"; return 0; }
  case $CURX in *"rc 3"*) echo "its screenshot was refused: the screen was off/dozing"; return 0 ;; esac
  q=$(irq); if [ -n "$q" ] && [ "$q" != -1 ] && [ -n "${I0:-}" ] && [ "$q" != "$I0" ]; then echo "the user touched the phone"; return 0; fi
  p=$(apppid); if [ -n "$APID0" ] && [ "$p" != "$APID0" ]; then echo "PowOS restarted (pid $APID0 -> ${p:-none}: an install or a crash)"; return 0; fi
  return 1
}
# skipped <why> <check>: a step's check not judged - a SKIP line, counted apart from FAILs.
skipped() { NSKIP=$((NSKIP + 1)); _res SKIP "(interrupted: $1) $2"; }
fail() {
  local why; why=$(interrupted) && { skipped "$why" "$*"; return 0; }
  NFAIL=$((NFAIL + 1)); local lc="$PDIR/${CUR%.png}.logcat.txt"
  sh_ "tail -n 400 $PDIR/logcat-$PART.txt > $lc; chmod a+r $lc" >/dev/null 2>&1
  _res FAIL "$* [logcat: $lc]"
}
# note: a line in steps.txt that is neither (what was seen, for the manager).
note() { _res NOTE "$*"; }
ok() { local c=$1; shift; [ "$c" = 0 ] && pass "$*" || fail "$*"; }
# fps_gate <step_name> <frame_count> <duration_ms> <min_fps>: check FPS threshold; on emu, print NOTE; on phone, PASS/FAIL.
fps_gate() {
  local step_name="$1" frame_count="$2" duration_ms="$3" min_fps="$4"
  local fps=$((frame_count * 1000 / duration_ms))
  case "${POWOS_DEVICE:-phone}" in
    emu) note "$step_name: $frame_count frames in $duration_ms ms ($fps fps) - emu note: fps gates apply on the phone only)" ;;
    *) [ "$fps" -ge "$min_fps" ] && pass "$step_name: $frame_count frames in $duration_ms ms ($fps fps)" || fail "$step_name: $frame_count frames in $duration_ms ms ($fps fps, want >= $min_fps)" ;;
  esac
}

# steps.txt on the phone: the other parts' lines kept, this part's replaced; the folder the session user's.
publish() {
  [ -n "${PDIR:-}" ] || return 0
  local tmp=/data/local/tmp/e2e-steps-$$.txt
  "$A" push "$STEPS" "$tmp" >/dev/null 2>&1
  ash <<EOF
d=$PDIR; mkdir -p \$d; touch \$d/steps.txt
grep -v '^#' \$d/steps.txt | awk -F- -v lo=$LO -v hi=$HI '!((\$1 + 0) >= lo && (\$1 + 0) <= hi)' > \$d/.s
cat $tmp >> \$d/.s 2>/dev/null; rm -f $tmp
{ echo "# e2e-$JOURNEY round $ROUND: one line per screenshot - file, what the user did / saw, PASS / FAIL / SKIP / NOTE"; sort \$d/.s; } > \$d/steps.txt; rm -f \$d/.s
chown $E2E_UID:$E2E_UID /data/powos/root/home/powos/design-qa; chown -R $E2E_UID:$E2E_UID /data/powos/root/home/powos/design-qa/e2e-$JOURNEY
chmod -R a+rX /data/powos/root/home/powos/design-qa/e2e-$JOURNEY
EOF
}
mail_manager() {
  local msg="E2E round $ROUND ready: $UDIR" n
  # The round's counts over every part: interrupted steps (SKIP, not judged) apart from FAILs.
  n=$(sh_ "f=$PDIR/steps.txt; echo \$(grep -c \"PASS: \" \$f) passed, \$(grep -c \"FAIL: \" \$f) failed, \$(grep -c \"SKIP: (interrupted\" \$f) skipped \(interrupted\)")
  [ -n "$n" ] && msg="$msg - $n"
  # The round's skipped / aborted journeys (user active, a touch): named, so a missing part isn't read as a pass.
  [ -n "${sk:-}" ] && msg="$msg - skipped/aborted (re-queued, not FAILs): $(printf '%s\n' "$sk" | cut -d' ' -f2- | paste -sd';' - | sed 's/;/; /g')"
  printf 'powos comms send manager %q --from e2e\n' "$msg" > "$OUT/mail.sh"
  # Capped: a hung `powos comms send` ran the App API journey past its 300 s budget after its last step (2026-10-23).
  perl -e 'alarm shift; exec @ARGV' 20 "$T/user.sh" "$OUT/mail.sh" >/dev/null 2>&1 && log "mailed the manager: E2E round $ROUND ready: $UDIR" || log "mail to the manager failed"
}

# e2e_setup [inner]: screen awake (never woken), the lock face swiped (no PIN), home in front; what it started from
# recorded (the app in front, home's page, the tasks, the Linux apps running, the layout). inner: the inner screen
# forced (cmd device_state state 3; reset at the end).
E2E_APPS="$TEST_APP|com.android.chrome|PowosWindowActivity"
E2E_LINUX='dolphin kate gwenview'
FORCED=0
e2e_setup() {
  . "$here/window-lock.sh"
  window_lock "e2e-$JOURNEY" 120
  trap 'e2e_abort' EXIT
  e2e_idle_gate
  I0=$(irq)
  e2e_logcat_start
  if [ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" != Awake ]; then
    # The "never wake the screen" rule is for the PHONE - someone may genuinely be asleep next to it, and a check
    # waking it is the bug. Nobody is ever "asleep next to" the emulator: the emulator lane owns the opposite rule
    # (tools/emu/emu.sh stay_awake, run before every job) and waking it HERE, if it still isn't awake, is correct -
    # applying the phone's rule to it instead SKIPped a real check for no reason (f72, 2026-10-24).
    if [ "${POWOS_DEVICE:-phone}" = emu ]; then
      sh_ "svc power stayon true; input keyevent KEYCODE_WAKEUP"; sleep 1
      [ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || { echo "FAIL: the emulator's screen won't wake"; exit 1; }
    else
      echo "the screen isn't awake - not woken (rule); nothing done"; exit 3
    fi
  fi
  TOP=$(sh_ "dumpsys activity activities | grep -m1 topResumedActivity")
  TOPT=$(sed -nE 's/.* t([0-9]+)\}.*/\1/p' <<<"$TOP"); case $TOP in *HomeShell*|*HomeDesktop*|*PowosLock*|"") TOPT= ;; esac
  TASKS0=$(tasks); LIN0=$(us "for p in $E2E_LINUX; do pgrep -x \$p >/dev/null && echo \$p; done; true")
  log "started from: ${TOP:-?} | linux apps up: $(echo $LIN0)"
  if [ "${1:-}" = inner ]; then
    [ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || { echo "FAIL: enable_freeform_support isn't 1"; exit 1; }
    # Forced even when already open (as every unfolded check): `state reset` at the end hands it back to the hinge.
    FORCED=1; device_state_set 3; sleep 2; chk unfold
  fi
  local t=0 WH; WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  while [ "${1:-}" = inner ] && [ "${WH%% *}" -le 2000 ] 2>/dev/null && [ $t -lt 13 ]; do sleep 1; t=$((t + 1)); WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); done
  W=${WH% *}; H=${WH#* }
  [ "${W:-0}" -gt 500 ] || { echo "ENV: no screen size ($WH) - stopping before any input"; exit 5; }
  [ "${1:-}" != inner ] || [ "$W" -gt 2000 ] || { echo "ENV: the inner screen didn't come on ($WH) - stopping"; exit 5; }
  DENS=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1)
  kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
  if kg | grep -q true; then
    sh_ "wm dismiss-keyguard"; sleep 1.5
    kg | grep -q true && { swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300 "the lock face"; sleep 1.5; }
    kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?) - stopping"; exit 5; }
  fi
  sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300 "the lock face"; sleep 1.5; }
  chk lock
  # Home's page first: going home while home shows turns it to page 1 (state.ts goHome).
  PAGE0=$(hpage); [[ $PAGE0 =~ ^-?[0-9]+$ ]] || PAGE0=0; LAY0=$(layout)
  shade_shut "the start"
  sh_ "cmd statusbar collapse; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
  # The journey starts on page 1 (PowOS AI's page or another one: back to it at the end).
  hemit system.home null
  log "on: ${W}x${H} @${DENS} dpi, home page $PAGE0, layout $LAY0"
}
# Everything the journey opened closed, the start state back (also on an abort: a touch, the budget, a FAIL exit).
RESTORED=0
e2e_restore() {
  [ $RESTORED = 1 ] && return 0; RESTORED=1
  e2e_logcat_stop
  # Setup never read the start state (the screen asleep, no window): nothing of the journey's to close - without
  # TASKS0 every task looked new and a user's Linux window was closed (resize-probe, 2026-10-23 18:38).
  [ -n "${TASKS0+set}" ] || { log "nothing to restore (the journey never started)"; return 0; }
  sh_ "input motionevent CANCEL 1 1" >/dev/null 2>&1
  hemit system.home null; hemit system.home null
  local id pkg vis was
  while read -r id pkg vis; do
    [ -n "$id" ] || continue
    if ! grep -q "^$id " <<<"$TASKS0"; then
      grep -qE "$E2E_APPS" <<<"$pkg" && { sh_ "am stack remove $id"; log "closed task $id ($pkg): the journey opened it"; }
    else
      # The user's own task, brought forward by the journey: back where it was (out of sight).
      was=$(grep "^$id " <<<"$TASKS0" | awk '{print $3}')
      [ "$was" = false ] && [ "$vis" = true ] && grep -qE "$E2E_APPS" <<<"$pkg" && { hcall windows.minimise "[$id]" "()=>'ok'" >/dev/null; log "task $id ($pkg) was the user's: out of sight again"; }
    fi
  done <<<"$(tasks)"
  local p kill=""; for p in $E2E_LINUX; do grep -qx "$p" <<<"$LIN0" || kill="$kill $p"; done
  [ -n "$kill" ] && us "for p in$kill; do pkill -x \$p; done; true" >/dev/null
  # The journey's shade never left down for the next one (its window over home eats the next tap).
  SHADE_LEFT=$(shadeup); shade_shut "the restore"
  [ $FORCED = 1 ] && { device_state_reset; sleep 1.5; }
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1
  # Once more after home is up: a minimised window (under home) wasn't in the list the first read saw (e2e r3 part 1
  # left Calculator 2494 open, "closed" never logged for it).
  local id2 pkg2 vis2
  while read -r id2 pkg2 vis2; do
    [ -n "$id2" ] && ! grep -q "^$id2 " <<<"$TASKS0" && grep -qE "$E2E_APPS" <<<"$pkg2" && { sh_ "am stack remove $id2"; log "closed task $id2 ($pkg2): the journey opened it (second pass)"; }
  done <<<"$(tasks)"
  [ -n "${PAGE0:-}" ] && setpage "$PAGE0"
  [ -n "${TOPT:-}" ] && [ -n "$(tasks | grep "^$TOPT ")" ] && { hcall tasks.open "[$TOPT]" "()=>'ok'" >/dev/null; log "the app in front at the start (task $TOPT) is back"; }
  log "restored"
}
e2e_abort() {
  local rc=$?
  [ $DONE = 1 ] || { e2e_restore; publish; }
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
  [ $DONE = 1 ] || echo "e2e-$JOURNEY part $PART ended early (rc $rc) - $NPASS passed, $NFAIL failed, ${NSKIP:-0} skipped (interrupted); steps so far in $UDIR"
}
# e2e_finish: the end step (after the restore: home as it started, nothing of the journey's left, the layout the same),
# steps.txt published, the manager mailed after the last part; the summary line last (the board's step).
e2e_finish() {
  e2e_restore
  if [ -z "${TOPT:-}" ]; then
    step end "back where the journey started: home's page $PAGE0, everything it opened closed"
    local pg left; pg=$(hpage); left=$(tasks | while read -r id pkg vis; do grep -q "^$id " <<<"$TASKS0" || { grep -qE "$E2E_APPS" <<<"$pkg" && echo "$id:$pkg"; }; done)
    [ "$pg" = "$PAGE0" ] && [ -z "$left" ] && pass "home on page $pg as at the start, none of the journey's windows left" || fail "at the end: page $pg (started $PAGE0), left open: ${left:-none}"
    [ "${SHADE_LEFT:-}" = up ] && note "the journey left PowOS's shade down - the restore put it away"
  else
    step end "back where the journey started: the app in front then (task $TOPT) in front again"
    note "the journey started over an app (task $TOPT); it is back in front"
  fi
  local lay; lay=$(layout)
  [ "$lay" = "$LAY0" ] && pass "the home layout is unchanged (home.get + home.wide)" || fail "the home layout CHANGED during the journey ($LAY0 -> $lay) - check home.wide.backup"
  publish
  sk=$(sh_ "cat $PDIR/skipped.txt 2>/dev/null")
  [ -n "$sk" ] && log "skipped / aborted in this round so far (not FAILs, re-queued):" && printf '%s\n' "$sk" | sed 's/^/  /' | tee -a "$OUT/log.txt"
  [ "$PART" = "$LAST" ] && mail_manager
  DONE=1
  local s="e2e-$JOURNEY round $ROUND part $PART/$LAST: $NPASS passed, $NFAIL failed, $NSKIP skipped (interrupted) - $UDIR"
  [ $NFAIL = 0 ] && echo "PASS $s" || { echo "FAIL $s ($(grep -c FAIL "$STEPS") FAIL lines in steps.txt)"; print_fails; }
}
# print_fails: every FAIL step line of steps.txt, untruncated, so the done log says WHY (not only how many).
print_fails() { grep FAIL "$STEPS" | sed 's/^/  FAIL step: /'; }
