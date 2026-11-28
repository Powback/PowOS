#!/bin/bash
# lanes: phone
# focus-modes.sh [OUT] (Mac side; board focus-modes-and-a-notification-digest): the control center's focus tile
# (shell/ui/focus.ts, control.tsx) turns a focus mode on: Android's Do not disturb goes on (qs.state dnd), and a
# notification posted then from an app the mode doesn't allow (the shell's own `cmd notification post`, package
# com.android.shell) is held - no card in the list, counted on the digest card (.notif-digest). The tile again: the focus
# ends, Do not disturb off, the digest card still there ("while ... was on"); its "Show" puts the notification in the
# list. Cleans up: the test notification cancelled, the focus state and Do not disturb as they were (trap).
# Exit 1 + "FAIL:" on a miss, 3 on a real touch (restored) or no window, 5 + "ENV:" when it can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/focus-modes-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
. "$here/base.sh"
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
q() { "$T/cdp.sh" eval shade "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
PB='((m,a)=>new Promise((ok,no)=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return no("no bridge");const r=h.resolve,j=h.reject,id=950000+Math.floor(Math.random()*9000);const done=f=>v=>{h.resolve=r;h.reject=j;f(v)};h.resolve=(i,v)=>i===id?done(ok)(v):r(i,v);h.reject=(i,x)=>i===id?done(no)(x):j(i,x);setTimeout(()=>done(no)("no answer"),8000);P.postMessage(JSON.stringify([id,m,JSON.stringify(a)]))}))'
dnd() { q "$PB('qs.state',[]).then(s=>String(s.dnd), () => 'err')"; }
store() { q "String(localStorage.getItem('powos.$1'))"; }
TAG=powos-focus-check
# The host's list as key|pkg|title|time|clearable. In a variable: written inline as "...$(q "...{k:..,t:..}...")" the Mac's
# bash 3.2 brace-expanded the JS object literal - four evals of "(key:n.key)", each "SyntaxError: Unexpected token ':'"
# (11-28; tools/agents/shell-pitfalls.py brace-subst).
LISTED="$PB"'("notifications.list",[]).then(l=>JSON.stringify((l.items||[]).map(n=>[n.key,n.pkg,n.title,n.time,n.clearable].join("|"))),()=>"err")'
. "$here/window-lock.sh"; window_lock focus-modes 150 "${MAX_WAIT:-10800}"
ON0=""; DIG0=""; DND0=""
# The test notification is the SHELL's (uid 2000, package com.android.shell), so it is posted and cancelled through
# plain `adb shell`, never sh_: as root (su -c, uid 0) `cmd notification post` lists nothing under com.android.shell,
# and its output went to /dev/null - the 11-28 08:57 run's list had no $TAG at all (System UI's DND notice was what the
# digest counted).
post_shell() { "$A" shell "cmd notification post -t 'focus check' $TAG 'held while the focus is on'" 2>&1 | tr -d '\r'; }
# No `cmd notification cancel` on this Android ("Unknown command: cancel", probe 11-28 10:48 - the old trap's cancel
# never removed anything): dismissed as the shade does it, through the host (notifications.dismiss), only keys
# "0|com.android.shell|<id>|$TAG|..." - never anything else.
CANCEL="$PB"'("notifications.list",[]).then(l=>Promise.all((l.items||[]).map(n=>n.key).filter(k=>{const p=String(k).split("|");return p[1]==="com.android.shell"&&p[3]==="'"$TAG"'"}).map(k=>'"$PB"'("notifications.dismiss",[k]))).then(r=>"dismissed "+r.length)),e=>"err "+e)'
cancel_shell() { q "$CANCEL"; }
restore() {
  log "cleanup: $(cancel_shell)"
  if [ -n "$ON0" ]; then
    # The page's own storage back as it was (the storage event follows in the other pages).
    q "(()=>{const s=(k,v)=>v==='null'?localStorage.removeItem('powos.'+k):localStorage.setItem('powos.'+k,v);s('focus.on','$ON0');s('focus.digest','$DIG0');return 'ok'})()" >/dev/null
  fi
  if [ -n "$DND0" ] && [ "$(dnd)" != "$DND0" ]; then q "$PB('qs.toggle',['dnd']).then(()=>'ok')" >/dev/null; fi
  sh_ "cmd statusbar collapse; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
}
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; "$A" shell input motionevent CANCEL 1 1 >/dev/null 2>&1; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
f() { echo "$1" | awk -v i="$2" '{print $i}'; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "ENV: the screen is $s - not woken (rule); nothing done"; exit 5; }
sh_ "cmd statusbar collapse; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
ON0=$(store focus.on); DIG0=$(store focus.digest); DND0=$(dnd)
case "$DND0" in true | false) ;; *) echo "ENV: no shade page / qs.state ($DND0)"; exit 5 ;; esac
[ "$ON0" = null ] || { echo "ENV: a focus is on already ($ON0) - the user's; nothing done"; ON0=""; exit 5; }
log "start: dnd=$DND0 focus.on=$ON0"
# A clean slate for the check (restored after): no digest left from before.
q "localStorage.removeItem('powos.focus.digest')" >/dev/null
read -r W H < <(sh_ "wm size" | sed -nE 's/.*: ([0-9]+)x([0-9]+).*/\1 \2/p' | tail -1)
W=${W:-1116}; H=${H:-2484}

"$A" shell "cmd statusbar collapse" >/dev/null; sleep 0.3
"$A" shell input swipe $((W * 800 / 1000)) 8 $((W * 800 / 1000)) $((H * 600 / 1000)) 350; sleep 1.5; chk open
"$A" shell input swipe $((W / 2)) $((H * 450 / 1000)) $((W / 2)) $((H * 750 / 1000)) 300; sleep 1.5; chk pull

TILE='(()=>{const e=document.querySelector("[data-key=\"powos.focus\"] button");if(!e)return "";const r=e.getBoundingClientRect();if(r.height<=0)return "";const d=devicePixelRatio;return [Math.round((r.left+r.width/2)*d),Math.round((r.top+r.height/2)*d)].join(" ")})()'
tap_tile() {
  local t; t=$(q "$TILE")
  [ -n "$t" ] || { fail "the focus tile isn't shown in the control center ($1)"; return 1; }
  "$A" shell "input tap $(f "$t" 1) $(f "$t" 2)" >/dev/null; sleep 2; chk "$1"
}
tap_tile on || exit 1
on=$(store focus.on); log "after the tap: focus.on=$on dnd=$(dnd)"
# q strips the answer's quotes (tr -d '"'): {id:dnd,...,since:...} - match the bare key (11-28 FAIL on a focus that was on).
case "$on" in *since:*) ;; *) fail "the tile didn't turn a focus on (focus.on=$on)" ;; esac
[ "$(dnd)" = true ] || fail "focus on, Do not disturb is not (qs.state dnd=$(dnd))"

po=$(post_shell); log "post (shell uid): $po"
# Listed within ~5 s, or the rest of the check means nothing (the digest would count some other notification).
lw=""; for _ in 1 2 3 4 5; do lw=$(q "$LISTED"); case "$lw" in *"|$TAG|"*) break ;; esac; sleep 1; done
case "$lw" in *"|$TAG|"*) ;; *) fail "the test notification (tag $TAG) wasn't listed within 5 s of its post ('$po'); listed=$lw"; exit 1 ;; esac
sleep 1
cards=$(q '[...document.querySelectorAll(".notif-items .notif:not(.notif-digest)")].filter(e=>e.textContent.includes("held while the focus")).length')
digest=$(q 'document.querySelector(".notif-digest")?.textContent ?? ""')
log "while on: matching cards=$cards digest='$digest'"
# Every listed notification, not just the test one (11-28: the only one held was System UI's 0|com.android.systemui|10001|null|...,
# gone once Do not disturb went off - was the test post listed at all?): key, package, title, time, clearable.
lw=$(q "$LISTED"); log "while on: listed=$lw"
case "$lw" in *"|$TAG|"*) ;; *) fail "the test notification (tag $TAG) isn't in the host's list - the digest counted something else" ;; esac
[ "$cards" = 0 ] || fail "the held notification shows as a card ($cards)"
case "$digest" in *held*) ;; *) fail "no digest card counting it ('$digest')" ;; esac

tap_tile off || exit 1
log "after the second tap: focus.on=$(store focus.on) dnd=$(dnd)"
[ "$(store focus.on)" = null ] || fail "the focus didn't end"
[ "$(dnd)" = false ] || fail "focus off, Do not disturb still on"
digest=$(q 'document.querySelector(".notif-digest")?.textContent ?? ""')
log "after: digest='$digest'"
# What the digest decides from (11-28 FAIL: held while on, gone after): the stored windows and the test notification as listed.
log "after: focus.digest=$(store focus.digest)"
log "after: listed=$(q "$LISTED")"
case "$digest" in *"was on"*) ;; *) fail "the digest card isn't there after the focus ended ('$digest')" ;; esac

SHOW='(()=>{const b=[...document.querySelectorAll(".notif-digest button")].find(e=>e.textContent.trim()==="Show");if(!b)return "";b.scrollIntoView({block:"center"});const r=b.getBoundingClientRect(),d=devicePixelRatio;return [Math.round((r.left+r.width/2)*d),Math.round((r.top+r.height/2)*d)].join(" ")})()'
sleep 0.6; s=$(q "$SHOW")
if [ -z "$s" ]; then fail "no Show on the digest card"; else
  "$A" shell "input tap $(f "$s" 1) $(f "$s" 2)" >/dev/null; sleep 1.5; chk show
  cards=$(q '[...document.querySelectorAll(".notif-items .notif:not(.notif-digest)")].filter(e=>e.textContent.includes("held while the focus")).length')
  log "after Show: matching cards=$cards digest=$(q '!!document.querySelector(".notif-digest")')"
  [ "$cards" -ge 1 ] 2>/dev/null || fail "Show didn't put the held notification in the list"
fi

restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: the focus tile turns a focus + Do not disturb on/off; a non-allowed app's notification is held on the digest card and shown by its Show" ||
  { echo "FAIL: $FAILS step(s)"; exit 1; }
