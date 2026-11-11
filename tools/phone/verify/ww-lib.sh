# shellcheck shell=bash
# tools/phone/verify/ww-lib.sh (sourced by e2e-lib.sh, linux-float.sh): home's page over CDP (ev), its bridge (hcall)
# and the web windows (W1, docs/WEB_WINDOWS.md) every window check reads - one copy, not one per check. Needs T set.
# ev <js> [page]: a CDP eval, its answer unquoted when it is a JSON string (cdp.sh prints "\"opened\"" - a quoted answer
# read as is made app-api.sh and app-frost.sh FAIL on a page that had opened, 2026-10-23).
UNQ='import json,sys
s=sys.stdin.read().strip()
try:
    v=json.loads(s)
except Exception:
    v=s
print(v if isinstance(v,str) else json.dumps(v))'
ev() { sess_ev "${2:-home}" "$1" && return 0; [ $? = 75 ] || return 0
  "$T/cdp.sh" eval "${2:-home}" "$1" 2>/dev/null | tr -d '\r' | tail -1 | python3 -c "$UNQ"; }
# hcall <method> <JS args> <JS fn of the answer -> string>: a call on home's bridge as the page makes it
# (float-windows.sh); an empty answer is a failed hop before the page, made again (up to 4 tries).
hcall_once() {
  ev "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=930300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:String(($3)(v)))"
}
# WW_DEADLINE (a $SECONDS value, set by wwc-lib.sh): past it a call answers "ERR deadline" at once - a hidden home page
# (another activity in front) answers no call, and 4 tries x the CDP timeout per poll spent switcher-launch's whole
# 300 s budget in ww_open's wait (11-10 03:35 job) with no line saying where.
ww_late() { [ -n "${WW_DEADLINE:-}" ] && [ "$SECONDS" -ge "$WW_DEADLINE" ]; }
hcall() { local v i; for i in 1 2 3 4; do ww_late && { echo "ERR deadline"; return; }; v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer (${v:-empty})"; }
# Web windows (W1, docs/WEB_WINDOWS.md): their ids are "w<id>" here (the page's data-wwid), task ids stay plain numbers.
# The truth is the host's list (webwindows.list: key "a:<drawer key>"/"l:<app>", state, task) and the page's element
# (.webwindow[data-wwid]: where it is on screen now, device px). WWRECTS: every web window shown on screen, "l t r b,...".
# WWON: a JS fn of a window's element -> true when any of it shows: its rect cut to its page's box (.page clips its
# windows, PS2 - sideways overflow clip) and the screen. Its bare rect isn't enough: a window hanging past its page's
# right edge (under the dock, E2E 203/206/207: 553..2127 on a 2087 px page) kept 40 px "on screen" after a swipe to the
# next page, while the page's clip (and the host's w.f, visible 0) hid all of it.
WWON="(e=>{const r=e.getBoundingClientRect(),p=e.closest('.page'),q=p?p.getBoundingClientRect():{left:-1e9,right:1e9};return Math.min(r.right,q.right,innerWidth)-Math.max(r.left,q.left,0)>=2&&Math.min(r.bottom,innerHeight)-Math.max(r.top,0)>=2})"
WWRECTS="(()=>{const d=devicePixelRatio,on=$WWON;return [...document.querySelectorAll('.webwindow[data-wwid]')].filter(on).map(e=>e.getBoundingClientRect()).map(r=>[r.left,r.top,r.right,r.bottom].map(v=>Math.round(v*d)).join(' ')).join(',')})()"
# wwel <w-id> <js fn of the element -> string>: its frame element in home's page ("none" when it has none).
wwel() { ev "(()=>{const e=document.querySelector('.webwindow[data-wwid=\"${1#w}\"]');return e?String(($2)(e)):'none'})()"; }
# wwrect <w-id>: its frame, "l t r b" device px (uncut), "" when none of it shows (WWON: minimised, another page).
wwrect() { local v; v=$(wwel "$1" "e=>{const r=e.getBoundingClientRect(),d=devicePixelRatio;return !($WWON)(e)?'':[r.left,r.top,r.right,r.bottom].map(v=>Math.round(v*d)).join(' ')}"); [ "$v" = none ] && v=""; echo "$v"; }
# wwhost <w-id> <field>: from the host's webwindows.list - state | task | key | gone (true when it isn't listed).
wwhost() { hcall webwindows.list "[]" "l=>{const w=l.find(w=>w.id===${1#w});return '$2'==='gone'?String(!w):w?String(w['$2']):'none'}"; }
# wwbody <w-id>: its body (the app's content, under the title bar) on screen, "l t r b" device px, or "".
wwbody() { local v; v=$(wwel "$1" "e=>{const b=e.querySelector('.webwindow-body');if(!b)return '';const r=b.getBoundingClientRect(),d=devicePixelRatio;return r.width<2||r.height<2||r.right<1||r.bottom<1||r.left>innerWidth-1||r.top>innerHeight-1?'':[r.left,r.top,r.right,r.bottom].map(v=>Math.round(v*d)).join(' ')}"); [ "$v" = none ] && v=""; echo "$v"; }
# wwpt <w-id> <selector>: the centre of that element inside the web window, "x y" device px, or "". (here, not e2e-lib.sh: ww-resize.sh sources only this file and FAILed "wwpt: command not found" -> "no .ww-edge-se on screen", 11-07 16:32)
wwpt() { local v; v=$(wwel "$1" "e=>{const b=e.querySelector('$2');if(!b)return '';const r=b.getBoundingClientRect(),d=devicePixelRatio;return r.width<1?'':Math.round((r.left+r.width/2)*d)+' '+Math.round((r.top+r.height/2)*d)}"); [ "$v" = none ] || echo "$v"; }
# wwids [key prefix]: the host's web windows (webwindows.list) whose key starts with it, "w<id>" one per line, sorted
# (comm's order). "l:" = every Linux window.
wwids() { local v; v=$(hcall webwindows.list "[]" "l=>l.filter(w=>String(w.key).startsWith('${1:-}')).map(w=>'w'+w.id).join(' ')"); case $v in ERR*) v="" ;; esac
  printf '%s\n' $v | grep . | sort; }
# wwnew <s> <before: wwids' lines> [key prefix]: up to s seconds for web windows not in before; prints them.
wwnew() { local n="" i; for i in $(seq 1 "$1"); do sleep 1; n=$(comm -13 <(echo "$2") <(wwids "${3:-}")); [ -n "$n" ] && break; done; echo "$n"; }
# wwbar <w-id>: true when its PowOS title bar (.webwindow-title) shows on screen in its frame, else false.
wwbar() { wwel "$1" "e=>{const b=e.querySelector('.webwindow-title');if(!b)return false;const r=b.getBoundingClientRect();return r.width>2&&r.height>2&&r.right>0&&r.bottom>0&&r.left<innerWidth&&r.top<innerHeight}"; }
# wwtop <w-id>...: of those, the one on top (the page's webWins, bottom first), "w<id>" or "none".
wwtop() { local ids; ids=$(printf "%s," "${@#w}")
  ev "importShim('./ui/webwindows.tsx').then(m=>{const s=[${ids%,}],w=m.webWins.value.filter(w=>s.includes(w.id)).at(-1);return w?'w'+w.id:'none'})"; }

# --- Self-setup (11-07: ww-glue/ww-popups SKIPped "no web window" / "no viewable Steam main window" on an idle phone;
# a check never SKIPs for state it can create itself). A check opens what it needs through home's own launch path
# (the bridge call a tap makes: apps.launch, as float-windows.sh / steam-one-window.sh) and closes only what it opened.
# ww_us <script text>: run it in the PowOS session as the session user (user.sh), output back.
ww_us() { local f; f=$(mktemp "${TMPDIR:-/tmp}/wwus.XXXXXX"); printf '%s\n' "$1" > "$f"; "$T/user.sh" "$f" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; rm -f "$f"; }
# ww_ready: home shows web windows here (unfolded, the host has the list) - else nothing a check can open.
ww_ready() { [ "$(hcall webwindows.list "[]" "l=>'ok'")" = ok ]; }
# ww_running <proc>: true when that process runs in the session (the user's app - never opened over, never closed).
ww_running() { [ -n "$(ww_us "pgrep -x '$1' | head -1")" ]; }
# ww_open <key> <secs>: launch it as a tap would (apps.launch), wait up to secs for a NEW web window of that key whose
# body is live (its app's frames, not the launch placeholder); prints "w<id>" (rc 1 and the last state when none).
ww_open() { local key=$1 s=$2 before r n="" i live=""
  before=$(wwids "$key")
  r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || { echo "apps.launch $key: $r"; return 1; }
  for i in $(seq 1 "$s"); do
    ww_late && { echo "no live $key window by the check's deadline (window ${n:-none} ${live:-})"; return 1; }
    sleep 1
    [ -n "$n" ] || n=$(comm -13 <(echo "$before") <(wwids "$key") | head -1)
    [ -n "$n" ] || continue
    live=$(wwel "$n" "e=>e.querySelector('.webwindow-body.live')?'live':'placeholder'")
    [ "$live" = live ] && { echo "$n"; return 0; }
  done
  echo "no live $key window ${s} s after apps.launch (window ${n:-none} ${live:-})"; return 1; }
# ww_close <w-id>: the host's close (what its bar's close does: the app is asked to close that window).
ww_close() { hcall webwindows.close "[${1#w}]" "()=>'ok'" >/dev/null 2>&1; }

# --- Persistent sessions (11-11, e2e-desktop r262: every part out of budget at load ~40-48, each step 50-60 s where
# 11-10's took 3-18 s). Every sh_/ash was its own `docker exec powos-vadb adb shell` (~3 s for the docker exec, ~2-3 s
# for adb's connection) and every ev its own `docker exec` into the warm bun container plus bun's start; a step makes
# 10-20 of them. sess_start opens ONE root shell on the phone (one adb) and ONE cdp.ts "serve" (one docker exec) that
# the calls then talk to over two FIFO pairs: a round trip is the WireGuard RTT plus the command, not two process
# starts. Off: E2E_SESS=0, the emulator, a second phone (their per-call paths are fast or differ). A call the session
# can't carry (rc 75: none up, it died, the watchdog killed it) falls back to the per-call path, the same command; a
# call sent but unanswered within SESS_TIMEOUT_S (rc 76) is not re-sent (an input must never run twice) - it answers
# "" as a failed adb call did, and the session is stopped (its stream no longer trusted).
# Framing: every request carries a tag; its answer ends with a line "<\001><tag> <rc>"; lines before a DIFFERENT tag's
# end (a caller killed mid-read left them) are dropped, so one lost answer never shifts the next call's.
SH_PID= CDP_PID= SESS_N=0
_sess_fifos() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/sess.XXXXXX") && mkfifo "$d/i" "$d/o" && echo "$d"; }
# _sess_read <fd> <tag>: the answer's lines (stdout), rc = the answer's rc, or 76 (timeout / EOF).
_sess_read() { local line buf="" c=$'\001' rc
  while IFS= read -r -t "${SESS_TIMEOUT_S:-40}" line <&"$1"; do line=${line%$'\r'}
    case $line in
      *"$c$2 "*) rc=${line##*"$c$2 "}; line=${line%"$c$2 "*}; [ -n "$line" ] && buf+="$line"$'\n'; printf '%s' "$buf"; return "${rc:-0}" ;;
      *"$c"__s*) buf= ;;
      *) buf+="$line"$'\n' ;;
    esac
  done; return 76; }
# _sess_kill <pid>: a session's process and its children (adb.sh -> docker exec).
_sess_kill() { [ -n "$1" ] || return 0; pkill -TERM -P "$1" 2>/dev/null; kill -TERM "$1" 2>/dev/null; return 0; }
_sess_on() { [ "${E2E_SESS:-1}" = 1 ] && [ "${POWOS_DEVICE:-phone}" != emu ] && [ -z "${CDP_MAC_ADB:-}" ] &&
  case ${PHONE_SERIAL:-${POWOS_PHONE_ADDR:-10.13.13.7:5555}} in 10.13.13.7:5555) true ;; *) false ;; esac; }
# sess_sh <script text>: run it in the phone's root shell session (stdin /dev/null, stderr dropped: sh_/ash's own
# rules), its stdout here. rc 75 = no session (nothing sent), 76 = sent, no answer.
sess_sh() {
  [ -n "$SH_PID" ] && kill -0 "$SH_PID" 2>/dev/null || return 75
  SESS_N=$((SESS_N + 1)); local tag=__s$$_${SESS_N}_$RANDOM
  ( trap '' PIPE; printf '(\n%s\n) </dev/null 2>/dev/null\nprintf "\\001%s %%s\\n" 0\n' "$1" "$tag" >&7 ) 2>/dev/null || return 75
  _sess_read 8 "$tag"; local rc=$?; [ $rc = 76 ] && _sess_kill "$SH_PID"; return $rc; }
# sess_ev <page> <js>: an eval through the cdp.ts serve session; its text as ev prints it. rc 75 = not sent, 3 = the
# forward is stale (nothing evaluated: the per-call path re-forwards), 76 = no answer.
sess_ev() {
  [ -n "$CDP_PID" ] && kill -0 "$CDP_PID" 2>/dev/null || return 75
  SESS_N=$((SESS_N + 1)); local tag=__s$$_${SESS_N}_$RANDOM n; n=$(LC_ALL=C; printf '%s' "${#2}")
  ( trap '' PIPE; printf '%s\t%s\t%s\n%s' "$tag" "$1" "$n" "$2" >&5 ) 2>/dev/null || return 75
  _sess_read 6 "$tag"; local rc=$?; case $rc in 76) _sess_kill "$CDP_PID" ;; 3) return 75 ;; esac; return 0; }
# sess_start / sess_stop: both sessions up (each optional: one that doesn't answer its first call stays off, the
# per-call path carries it). Called by e2e_setup before its watchdog (which spares them) and e2e_restore stops them.
sess_start() {
  _sess_on || return 0; sess_stop; local d
  if d=$(_sess_fifos); then
    "${A:-$T/adb.sh}" shell "su -c sh" <"$d/i" >"$d/o" 2>/dev/null & SH_PID=$!
    exec 7>"$d/i" 8<"$d/o"; rm -rf "$d"
    [ "$(SESS_TIMEOUT_S=30 sess_sh "echo ok")" = ok ] || { _sess_kill "$SH_PID"; SH_PID=; }
  fi
  [ "${SESS_CDP:-1}" = 1 ] || return 0
  "$T/cdp.sh" eval home 1 >/dev/null 2>&1   # the warm container, the forward and its cdp.ts copy, as cdp.sh makes them
  if d=$(_sess_fifos); then
    ( . "$T/cdp-warm.sh"; src="$(cd "$T" && pwd)/cdp.ts"
      exec "$CDP_DOCKER" exec -i -e CDP_PORT=9333 -e CDP_TIMEOUT_S "$CDP_WARM_NAME" bun "/s/cdp-${src//[^A-Za-z0-9]/_}.ts" serve ) <"$d/i" >"$d/o" 2>/dev/null & CDP_PID=$!
    exec 5>"$d/i" 6<"$d/o"; rm -rf "$d"
    [ "$(SESS_TIMEOUT_S=30 sess_ev home "'ok'")" = ok ] || { _sess_kill "$CDP_PID"; CDP_PID=; }
  fi; }
sess_stop() { _sess_kill "$SH_PID"; _sess_kill "$CDP_PID"; SH_PID= CDP_PID=; exec 5>&- 6<&- 7>&- 8<&-; return 0; }
