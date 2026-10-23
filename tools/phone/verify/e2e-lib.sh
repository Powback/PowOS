# shellcheck shell=bash
# tools/phone/verify/e2e-lib.sh (sourced by e2e-desktop.sh, e2e-appapi.sh): "use the phone like a user" journeys as
# queue jobs. Real injected taps and swipes at spots read over read-only CDP; one screenshot per step on the phone
# (/home/powos/design-qa/e2e-<journey>/<round>/NN-<step>.png) with a steps.txt line each (file, what was done,
# PASS/FAIL); the manager looks at them as a user. Rules kept here so both journeys keep them:
#   - NEVER a touch on the verify status pill (VerifyRun.kt "PowOS verify status", top centre): every DOWN is checked
#     against its window frame (+48 px) right before it is made, and refused (a FAIL line, no touch) inside it;
#   - a real finger (touch IRQs move) ends the run at once: exit 3, the runner re-queues it;
#   - only what the journey opened is closed (new tasks of its apps, Linux apps it started); the page, the screen state
#     and the app in front it started from come back; the layout (home.get + home.wide) must be the same at the end;
#   - a step's FAIL doesn't end the journey (more screenshots for the manager): exit 0 with FAIL lines = a FAIL.
# A journey longer than the queue's 300 s budget runs as parts (--part K of LAST): each part is its own job, numbers
# its steps from (K-1)*25+1, replaces only its own files and steps.txt lines; the last part mails the manager.
#   e2e_args "$@"; e2e_init <journey>; e2e_setup [inner]; ... step/pass/fail ...; e2e_finish
here=${here:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}; T=$here/..; A="$T/adb.sh"
E2E_UID=10359   # the PowOS session user (review-image.sh)
L=$HOME/.cache/powos-verify.lock

sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# ash: a script on stdin as Android root (any quoting inside).
ash() { "$A" shell "su -c 'sh -s'" 2>/dev/null | tr -d '\r'; }
# us: a script text inside PowOS as the session user (user.sh).
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; sh_ "input motionevent CANCEL 1 1" >/dev/null; exit 3; }; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }

# ev <js> [page]: a CDP eval, its answer unquoted when it is a JSON string (cdp.sh prints "\"opened\"" - a quoted answer
# read as is made app-api.sh and app-frost.sh FAIL on a page that had opened, 2026-10-23).
UNQ='import json,sys
s=sys.stdin.read().strip()
try:
    v=json.loads(s)
except Exception:
    v=s
print(v if isinstance(v,str) else json.dumps(v))'
ev() { "$T/cdp.sh" eval "${2:-home}" "$1" 2>/dev/null | tr -d '\r' | tail -1 | python3 -c "$UNQ"; }
# hcall <method> <JS args> <JS fn of the answer -> string>: a call on home's bridge as the page makes it
# (float-windows.sh); an empty answer is a failed hop before the page, made again (up to 4 tries).
hcall_once() {
  ev "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=930300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:String(($3)(v)))"
}
hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer (${v:-empty})"; }
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
# A dock cell by its key prefix (read only).
dockel() { echo "[...document.querySelectorAll('.home .dock .app[data-key]')].find(a=>a.dataset.key.startsWith('$1'))"; }
# winrects: every window on screen now (windows.list: not minimised, not on another page), "l t r b,l t r b" in device px.
winrects() { local v; v=$(hcall windows.list "[]" "l=>l.filter(w=>!w.minimised&&!w.away&&w.bounds).map(w=>w.bounds.join(' ')).join(',')"); case $v in ERR*) echo "" ;; *) echo "$v" ;; esac; }
# freept <window bounds or ""> <way -1|1|0> <length> [min x, 0..1] [min y, 0..1]: an empty spot on home's page (no tile,
# app, bar, dock; outside the window) with room for a sideways swipe that long (float-touch.sh's: a short swipe doesn't
# turn a page). Never under ANY window on screen: elementFromPoint sees only home's page, so a spot under a floating
# window (Chrome left up, a stray Kate) read as empty and the touch went to that window (the drawer's stages, rounds 1-3).
freept() {
  local ws; ws=$(winrects)
  ev "(()=>{const b='$1'.split(' ').filter(Boolean).map(Number),ws='$ws'.split(',').filter(Boolean).map(s=>s.split(' ').map(Number)),r=devicePixelRatio,d=${2:-0},len=${3:-0},W=innerWidth*r;let best=null,room=-1;for(let y=${5:-.2};y<=.75;y+=.05)for(let x=${4:-.06};x<=.94;x+=.04){const cx=innerWidth*x,cy=innerHeight*y,px=cx*r,py=cy*r;if(b.length===4&&px>=b[0]-60&&px<=b[2]+60&&py>=b[1]-120&&py<=b[3]+60)continue;if(ws.some(w=>px>=w[0]-40&&px<=w[2]+40&&py>=w[1]-140&&py<=w[3]+40))continue;const e=document.elementFromPoint(cx,cy);if(!e||!e.closest('.page-track'))continue;if(e.closest('.tile,.home-tile,.app,.panel,.widget,.island,.owl,button,a,input,textarea,.bar,.dock,[data-key]'))continue;const m=d<0?px-20:d>0?W-20-px:len;if(m>=len)return Math.round(px)+' '+Math.round(py);if(m>room){room=m;best=Math.round(px)+' '+Math.round(py)}}return best||'none'})()"
}

# Tasks and windows.
tasks() { sh_ "am stack list" | grep -E 'taskId=[0-9]+:' | sed -nE 's/.*taskId=([0-9]+): ([^ ]+).*(visible=(true|false)).*/\1 \2 \4/p'; }
tvis() { sh_ "am stack list" | grep -E "taskId=$1:" | grep -oE 'visible=(true|false)' | head -1 | cut -d= -f2; }
tbounds() { sh_ "am stack list" | grep -E "taskId=$1:" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ' | xargs; }
# win <key: pkg or l:app> <field>: from windows.list (front first): id | minimised | away | bounds | front
win() { hcall windows.list "[]" "l=>{const w=l.find(w=>w.pkg==='$1'||w.app==='$1');if(!w)return 'none';const f='$2';return f==='bounds'?(w.bounds||[]).join(' '):f==='front'?String(l.find(x=>!x.minimised&&!x.away)===w):String(w[f])}"; }
# waitwin <key> <s>: up to s seconds for its window; prints the task id or "none".
waitwin() { local i id=none; for i in $(seq 1 "$2"); do id=$(win "$1" id); [ "$id" != none ] && [ -n "$id" ] && break; sleep 1; done; echo "$id"; }
# wframe <title text>: that window's frame (a plain substring: "PowOS window bar 12}" - the } ends the title).
wframe() { sh_ "dumpsys window windows" | awk -v p="$1" '/^ *Window #/{f=(index($0,p)>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' ' | xargs; }
dp() { echo $(($1 * DENS / 160)); }
# screenrect "l t r b": a SurfaceFlinger HWC rect (Disp Frame: the panel's own orientation) in screen px. The inner
# screen is mounted at 270 (installOrientation 3): its raw rects are the window's turned (window-rec/window-live read
# Calculator's content at "437 431 2145 1791" for a task at 477 437 1837 2145, 2026-10-23). Needs W, H (e2e_setup).
screenrect() { set -- $1; [ $# -ge 4 ] || { echo "$*"; return; }
  [ -n "${INST:-}" ] || INST=$(sh_ "dumpsys display" | grep -E "^  DisplayDeviceInfo" | grep " state ON," | grep -oE "installOrientation [0-3]" | head -1 | cut -d" " -f2)
  case ${INST:-0} in 3) echo "$((W - $4)) $1 $((W - $2)) $3" ;; 1) echo "$2 $((H - $3)) $4 $((H - $1))" ;; 2) echo "$((W - $3)) $((H - $4)) $((W - $1)) $((H - $2))" ;; *) echo "$*" ;; esac; }
# closebtn <task>: its title bar's close button (21 dp from the bar's right), "x y" or "".
closebtn() { local b; b=$(wframe "PowOS window bar $1}"); [ -n "$b" ] || return 0; set -- $b; echo "$(($3 - $(dp 21))) $((($2 + $4) / 2))"; }
# barpt <task>: a spot on its title bar for a drag: the left part, away from the buttons, clear of the pill if it can.
barpt() { local b x r; b=$(wframe "PowOS window bar $1}"); [ -n "$b" ] || return 0; set -- $b
  r=$(pillrect); x=$(($1 + ($3 - $1) / 4))
  if [ -n "$(echo $r)" ]; then set -- "$@" $r; [ "$x" -ge $(($5 - 60)) ] && [ "$x" -le $(($7 + 60)) ] && x=$(($1 + $(dp 24))); fi
  echo "$x $((($2 + $4) / 2))"; }

# --- the journey's frame -----------------------------------------------------------------------------------------
# e2e_args "$@": --round R (default: a time stamp) --part K --of LAST
e2e_args() {
  ROUND=$(date +%m%d-%H%M); PART=1; LAST=1
  while [ $# -gt 0 ]; do case "$1" in --round) ROUND=$2; shift 2 ;; --part) PART=$2; shift 2 ;; --of) LAST=$2; shift 2 ;; *) shift ;; esac; done
  [[ $ROUND =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad --round $ROUND"; exit 2; }
}
e2e_init() {
  JOURNEY=$1; LO=$(((PART - 1) * 25 + 1)); HI=$((PART * 25)); N=$((LO - 1)); NPASS=0; NFAIL=0; DONE=0
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
  [ $N -lt $HI ] && N=$((N + 1)); CUR=$(printf '%02d-%s.png' "$N" "$1"); CURD=$2; CURN=0
  echo "-- $CUR: $2"
  "$T/shot.sh" --phone "$PDIR/$CUR" >/dev/null 2>&1; local rc=$?
  [ $rc = 0 ] || { [ $rc = 4 ] && CURX=" (screenshot came back blank)" || CURX=" (no screenshot, rc $rc)"; }
  [ $rc = 0 ] && CURX=""
}
_res() { printf '%s\t%s%s\t%s: %s\n' "$CUR" "$CURD" "$CURX" "$1" "$2" >> "$STEPS"; echo "$1: [${CUR%.png}] $2" | tee -a "$OUT/log.txt"; }
pass() { NPASS=$((NPASS + 1)); _res PASS "$*"; }
fail() { NFAIL=$((NFAIL + 1)); _res FAIL "$*"; }
# note: a line in steps.txt that is neither (what was seen, for the manager).
note() { _res NOTE "$*"; }
ok() { local c=$1; shift; [ "$c" = 0 ] && pass "$*" || fail "$*"; }

# steps.txt on the phone: the other parts' lines kept, this part's replaced; the folder the session user's.
publish() {
  [ -n "${PDIR:-}" ] || return 0
  local tmp=/data/local/tmp/e2e-steps-$$.txt
  "$A" push "$STEPS" "$tmp" >/dev/null 2>&1
  ash <<EOF
d=$PDIR; mkdir -p \$d; touch \$d/steps.txt
grep -v '^#' \$d/steps.txt | awk -F- -v lo=$LO -v hi=$HI '!((\$1 + 0) >= lo && (\$1 + 0) <= hi)' > \$d/.s
cat $tmp >> \$d/.s 2>/dev/null; rm -f $tmp
{ echo "# e2e-$JOURNEY round $ROUND: one line per screenshot - file, what the user did / saw, PASS / FAIL / NOTE"; sort \$d/.s; } > \$d/steps.txt; rm -f \$d/.s
chown $E2E_UID:$E2E_UID /data/powos/root/home/powos/design-qa; chown -R $E2E_UID:$E2E_UID /data/powos/root/home/powos/design-qa/e2e-$JOURNEY
chmod -R a+rX /data/powos/root/home/powos/design-qa/e2e-$JOURNEY
EOF
}
mail_manager() {
  printf 'powos comms send manager %q --from e2e\n' "E2E round $ROUND ready: $UDIR" > "$OUT/mail.sh"
  # Capped: a hung `powos comms send` ran the App API journey past its 300 s budget after its last step (2026-10-23).
  perl -e 'alarm shift; exec @ARGV' 20 "$T/user.sh" "$OUT/mail.sh" >/dev/null 2>&1 && log "mailed the manager: E2E round $ROUND ready: $UDIR" || log "mail to the manager failed"
}

# e2e_setup [inner]: screen awake (never woken), the lock face swiped (no PIN), home in front; what it started from
# recorded (the app in front, home's page, the tasks, the Linux apps running, the layout). inner: the inner screen
# forced (cmd device_state state 3; reset at the end).
E2E_APPS='com.oneplus.calculator|com.android.chrome|PowosWindowActivity'
E2E_LINUX='dolphin kate gwenview'
FORCED=0
e2e_setup() {
  . "$here/window-lock.sh"
  window_lock "e2e-$JOURNEY" 120
  trap 'e2e_abort' EXIT
  I0=$(irq)
  [ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || { echo "the screen isn't awake - not woken (rule); nothing done"; exit 3; }
  TOP=$(sh_ "dumpsys activity activities | grep -m1 topResumedActivity")
  TOPT=$(sed -nE 's/.* t([0-9]+)\}.*/\1/p' <<<"$TOP"); case $TOP in *HomeShell*|*HomeDesktop*|*PowosLock*|"") TOPT= ;; esac
  TASKS0=$(tasks); LIN0=$(us "for p in $E2E_LINUX; do pgrep -x \$p >/dev/null && echo \$p; done; true")
  log "started from: ${TOP:-?} | linux apps up: $(echo $LIN0)"
  if [ "${1:-}" = inner ]; then
    [ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || { echo "FAIL: enable_freeform_support isn't 1"; exit 1; }
    # Forced even when already open (as every unfolded check): `state reset` at the end hands it back to the hinge.
    FORCED=1; sh_ "cmd device_state state 3"; sleep 2; chk unfold
  fi
  local t=0 WH; WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  while [ "${1:-}" = inner ] && [ "${WH%% *}" -le 2000 ] 2>/dev/null && [ $t -lt 13 ]; do sleep 1; t=$((t + 1)); WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); done
  W=${WH% *}; H=${WH#* }
  [ "${W:-0}" -gt 500 ] || { echo "no screen size ($WH) - stopping before any input"; exit 5; }
  [ "${1:-}" != inner ] || [ "$W" -gt 2000 ] || { echo "the inner screen didn't come on ($WH) - stopping"; exit 5; }
  DENS=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1)
  kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
  if kg | grep -q true; then
    sh_ "wm dismiss-keyguard"; sleep 1.5
    kg | grep -q true && { swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300 "the lock face"; sleep 1.5; }
    kg | grep -q true && { echo "the keyguard didn't go (a PIN?) - stopping"; exit 5; }
  fi
  sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300 "the lock face"; sleep 1.5; }
  chk lock
  # Home's page first: going home while home shows turns it to page 1 (state.ts goHome).
  PAGE0=$(hpage); [[ $PAGE0 =~ ^-?[0-9]+$ ]] || PAGE0=0; LAY0=$(layout)
  sh_ "cmd statusbar collapse; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
  # The journey starts on page 1 (PowOS AI's page or another one: back to it at the end).
  hemit system.home null
  log "on: ${W}x${H} @${DENS} dpi, home page $PAGE0, layout $LAY0"
}
# Everything the journey opened closed, the start state back (also on an abort: a touch, the budget, a FAIL exit).
RESTORED=0
e2e_restore() {
  [ $RESTORED = 1 ] && return 0; RESTORED=1
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
  [ $FORCED = 1 ] && { sh_ "cmd device_state state reset"; sleep 1.5; }
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
  [ $DONE = 1 ] || echo "e2e-$JOURNEY part $PART ended early (rc $rc) - $NPASS passed, $NFAIL failed; steps so far in $UDIR"
}
# e2e_finish: the end step (after the restore: home as it started, nothing of the journey's left, the layout the same),
# steps.txt published, the manager mailed after the last part; the summary line last (the board's step).
e2e_finish() {
  e2e_restore
  if [ -z "${TOPT:-}" ]; then
    step end "back where the journey started: home's page $PAGE0, everything it opened closed"
    local pg left; pg=$(hpage); left=$(tasks | while read -r id pkg vis; do grep -q "^$id " <<<"$TASKS0" || { grep -qE "$E2E_APPS" <<<"$pkg" && echo "$id:$pkg"; }; done)
    [ "$pg" = "$PAGE0" ] && [ -z "$left" ] && pass "home on page $pg as at the start, none of the journey's windows left" || fail "at the end: page $pg (started $PAGE0), left open: ${left:-none}"
  else
    step end "back where the journey started: the app in front then (task $TOPT) in front again"
    note "the journey started over an app (task $TOPT); it is back in front"
  fi
  local lay; lay=$(layout)
  [ "$lay" = "$LAY0" ] && pass "the home layout is unchanged (home.get + home.wide)" || fail "the home layout CHANGED during the journey ($LAY0 -> $lay) - check home.wide.backup"
  publish
  [ "$PART" = "$LAST" ] && mail_manager
  DONE=1
  local s="e2e-$JOURNEY round $ROUND part $PART/$LAST: $NPASS passed, $NFAIL failed - $UDIR"
  [ $NFAIL = 0 ] && echo "PASS $s" || echo "FAIL $s ($(grep -c FAIL "$STEPS") FAIL lines in steps.txt)"
}
