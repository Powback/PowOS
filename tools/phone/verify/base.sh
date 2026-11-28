# shellcheck shell=bash
# tools/phone/verify/base.sh - the one shared base for the phone checks (docs/CLEANUP.md item 2). Source it right after
#   here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
# (it sets those three itself when they're unset). bash 3.2 (the Mac's /bin/bash) and `set -euo pipefail` safe.
# WHY: 52 checks pasted the same `sh_` line, 27 their own `hcall`, and several FAILed on the check script, not the
# product (11-23/24): one `adb shell su` per motionevent dragging too slowly (scroll-own, home-stack), `\"` inside a
# `python3 -c` (ai-tab-head), a quoted "x y" passed as one tap coordinate, broken pipes. The helpers here do it once:
#   sh_ <cmd>               root shell, \r stripped, stderr dropped (the pasted form, but any <cmd> - a ' inside is
#                           safe: tools/phone/su-quote.sh). Capped at SH_T seconds when
#                           SH_T is set, and at what's left of a `step` cap; unset = no cap, as before.
#   rsh                     a script on stdin as root (`su -c 'sh -s'`): any quoting inside, same caps as sh_.
#   vb_cap <s> <cmd...>     run a program, its process group killed after s seconds (rc 124).
#   within <s> <what> <cmd...>  run a command or function with a time cap; past it its process tree is killed,
#                           "FAIL: <what>: over its <s> s cap" is printed and rc is 124. (A subshell: it can't set vars.)
#   cdp_eval <page> <js>    CDP eval on that page (tools/phone/cdp.sh), its last line, \r stripped, raw.
#   cdp_val <js> [page]     the same, JSON-string answers unquoted (page default home).
#   hcall <method> <JS args> <JS fn of the answer>  a call on home's bridge as the page makes it, up to 4 tries on an
#                           empty/transport answer (HCALL_ID: id base, default 910300; HCALL_TRACE=0: no "try N" on
#                           stderr). hcall_once: one try.
#   tap x y | tap "x y"     validated integers (else "FAIL: tap: bad coordinates" and rc 2, nothing sent).
#   swipe x1 y1 x2 y2 [ms]  one `input swipe` (real time on the phone; default 300 ms).
#   drag x1 y1 x2 y2 [hold_ms] [move_ms] [steps] [end_hold_ms]  DOWN, hold, `steps` MOVEs spread over move_ms, a hold
#                           at the end (a finger resting on a scrubbed-to spot), UP - all in ONE on-device shell, so
#                           adb's per-call latency can't stretch or bunch the gesture (defaults 0, 400, 12, 0). Run it
#                           with `&` to probe the page while the finger is still down.
#   shot <out.png> [args]   tools/phone/shot.sh, its last line.
#   step <name> [cap_s]     "== name"; with cap_s, every sh_/rsh until the next step is capped at what's left of it,
#                           and a call past it sends nothing and prints "FAIL: step <name>: past its <cap_s> s cap".
#   pass/fail/skip <msg>    "PASS: msg" / "FAIL: msg" (counted) / "SKIP: msg" + exit 0 (the queue's SKIP: a first verdict
#                           line "SKIP:"). Also appended to $OUT/log.txt when OUT is a directory.
#   result <summary>        the last line: "PASS: <summary>" + exit 0, or "FAIL: N step(s) failed" + exit 1.
# Every public name is defined only when the script hasn't defined it already, and a definition after the `.` wins, so
# sourcing this never changes a check's own helpers. Its tier-1 test (fake adb/cdp/shot): test/tier1/test-verify-base.sh.
here=${here:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}; T=${T:-$here/..}; A=${A:-$T/adb.sh}
declare -F su_q >/dev/null || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/su-quote.sh"  # su_q: quote-safe su -c
VB_FAILS=${VB_FAILS:-0}; VB_STEP=""; VB_STEP_CAP=""; VB_STEP_END=""

# vb_cap: window-render.sh's `mt` (its fifo-bounds test covers it there): the command in a process group of its own; at
# the deadline (or a TERM/INT to it) the whole group gets TERM, then KILL 2 s later - a docker exec/adb child left alive
# keeps its pipe open and the reader (tr) waiting. rc 124 on the deadline.
vb_cap() { perl -e 'my $t = shift; my $p = fork(); defined $p or exit 127;
  if (!$p) { setpgrp(0, 0); exec @ARGV; exit 127 }
  setpgrp($p, $p); my $end = sub { kill "TERM", -$p;
    for (1 .. 20) { last unless kill 0, -$p; select undef, undef, undef, 0.1 } kill "KILL", -$p; waitpid($p, 0); exit $_[0] };
  $SIG{ALRM} = sub { $end->(124) }; $SIG{TERM} = sub { $end->(143) }; $SIG{INT} = sub { $end->(130) };
  alarm $t; waitpid($p, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"; }
vb_int() { case ${1:-} in ""|-|*[!0-9-]*|?*-*) return 1 ;; esac; }
vb_say() { if [ -n "${OUT:-}" ] && [ -d "${OUT:-}" ]; then echo "$*" | tee -a "$OUT/log.txt"; else echo "$*"; fi; }
# vb_root <cmd>: the one root adb call behind sh_ and rsh. With SH_T or a step cap, capped at the smaller of SH_T and
# what's left of the step; past the step's cap nothing is sent: "FAIL: step <name>: past its N s cap" on stderr (the
# queue's log takes both streams, and a FAIL line there fails the job even at rc 0 - sh_ usually runs in a $(...), so a
# counter couldn't carry it out) and rc 124.
vb_root() {
  local c=${SH_T:-} r
  if [ -z "$c$VB_STEP_END" ]; then "$A" shell "$(su_q "$1")" 2>/dev/null | tr -d '\r'; return; fi
  if [ -n "$VB_STEP_END" ]; then
    r=$((VB_STEP_END - SECONDS))
    [ "$r" -gt 0 ] || { echo "FAIL: step $VB_STEP: past its $VB_STEP_CAP s cap" >&2; return 124; }
    if [ -z "$c" ] || [ "$r" -lt "$c" ]; then c=$r; fi
  fi
  # Its own process group can't read a terminal (SIGTTIN would stop it): only rsh's script goes in on stdin.
  if [ "$1" = "sh -s" ]; then vb_cap "$c" "$A" shell "$(su_q "$1")" 2>/dev/null | tr -d '\r'
  else vb_cap "$c" "$A" shell "$(su_q "$1")" </dev/null 2>/dev/null | tr -d '\r'; fi
}
declare -F sh_ >/dev/null || sh_() { vb_root "$*"; }
declare -F rsh >/dev/null || rsh() { vb_root "sh -s"; }

# within <s> <what> <cmd...>
vb_kids() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do vb_kids "$c"; echo "$c"; done; }
declare -F within >/dev/null || within() {
  local s=$1 what=$2 p w t0=$SECONDS rc; shift 2
  "$@" & p=$!
  ( sleep "$s" & sl=$!; trap 'kill $sl 2>/dev/null; exit 0' TERM; wait $sl
    for k in $(vb_kids "$p") "$p"; do kill -TERM "$k" 2>/dev/null; done ) </dev/null >/dev/null 2>&1 &
  w=$!
  { wait "$p"; } 2>/dev/null; rc=$?
  kill -TERM "$w" 2>/dev/null; wait "$w" 2>/dev/null
  if [ $((SECONDS - t0)) -ge "$s" ] && [ "$rc" != 0 ]; then echo "FAIL: $what: over its $s s cap"; return 124; fi
  return "$rc"
}

# --- CDP and home's bridge -------------------------------------------------------------------------------------------
VB_UNQ='import json,sys
s=sys.stdin.read().strip()
try:
    v=json.loads(s)
except Exception:
    v=s
print(v if isinstance(v,str) else json.dumps(v))'
declare -F cdp_eval >/dev/null || cdp_eval() { "$T/cdp.sh" eval "$1" "$2" 2>&1 | tr -d '\r' | tail -1; }
declare -F cdp_val >/dev/null || cdp_val() { "$T/cdp.sh" eval "${2:-home}" "$1" 2>/dev/null | tr -d '\r' | tail -1 | python3 -c "$VB_UNQ"; }
declare -F hcall_once >/dev/null || hcall_once() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=${HCALL_ID:-910300}+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# hcall with retries: an EMPTY answer is a failed adb/CDP hop before the call reached the page (cdp.sh's adb under
# set -e once exited silently: "Calculator's key from home's apps.list: ", 2026-10-23) - the call never ran, so it's
# made again (up to 4 tries, 2 s apart). An answer from the page (ok, ERR ...) is final.
declare -F hcall >/dev/null || hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) [ "${HCALL_TRACE:-1}" = 0 ] || echo "hcall $2: try $i: '${v}'" >&2; sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer after 4 tries (${v:-empty})"; }

# --- input -----------------------------------------------------------------------------------------------------------
# vb_xy <what> <n> <args...>: n integer args, else a FAIL line and rc 2. Accepts "x y" quoted as one arg.
vb_xy() {
  local what=$1 n=$2 a; shift 2
  # shellcheck disable=SC2048,SC2086  # deliberate: "540 1200" passed as one arg splits into two
  set -- $*
  [ $# -eq "$n" ] || { echo "FAIL: $what: bad coordinates '$*' (want $n integers)"; return 2; }
  for a in "$@"; do vb_int "$a" || { echo "FAIL: $what: bad coordinates '$*' (want $n integers)"; return 2; }; done
}
declare -F tap >/dev/null || tap() { vb_xy tap 2 "$@" || return 2; set -- $*; sh_ "input tap $1 $2"; }
declare -F swipe >/dev/null || swipe() {
  # shellcheck disable=SC2048,SC2086
  set -- $*; local ms=${5:-300}
  vb_xy swipe 5 "$1" "$2" "$3" "$4" "$ms" || return 2
  sh_ "input swipe $1 $2 $3 $4 $ms"
}
declare -F drag >/dev/null || drag() {
  # shellcheck disable=SC2048,SC2086
  set -- $*; local hold=${5:-0} ms=${6:-400} n=${7:-12} endh=${8:-0} k s dt
  vb_xy drag 8 "$1" "$2" "$3" "$4" "$hold" "$ms" "$n" "$endh" || return 2
  [ "$n" -ge 1 ] || n=1
  dt=$((ms / n)); s="input motionevent DOWN $1 $2"
  [ "$hold" -gt 0 ] && s="$s
sleep $((hold / 1000)).$(printf %03d $((hold % 1000)))"
  for k in $(seq 1 "$n"); do
    s="$s
input motionevent MOVE $(($1 + ($3 - $1) * k / n)) $(($2 + ($4 - $2) * k / n))
sleep $((dt / 1000)).$(printf %03d $((dt % 1000)))"
  done
  [ "$endh" -gt 0 ] && s="$s
sleep $((endh / 1000)).$(printf %03d $((endh % 1000)))"
  printf '%s\ninput motionevent UP %s %s\n' "$s" "$3" "$4" | rsh
}
declare -F shot >/dev/null || shot() { "$T/shot.sh" "$@" 2>&1 | tail -1; }

# --- steps and verdicts ----------------------------------------------------------------------------------------------
declare -F step >/dev/null || step() {
  VB_STEP=$1; VB_STEP_CAP=${2:-}
  if [ -n "$VB_STEP_CAP" ]; then VB_STEP_END=$((SECONDS + VB_STEP_CAP)); else VB_STEP_END=""; fi
  vb_say "== $1"
}
declare -F pass >/dev/null || pass() { vb_say "PASS: $*"; }
declare -F fail >/dev/null || fail() { vb_say "FAIL: $*"; VB_FAILS=$((VB_FAILS + 1)); }
declare -F skip >/dev/null || skip() { vb_say "SKIP: $*"; exit 0; }
declare -F result >/dev/null || result() {
  if [ "$VB_FAILS" = 0 ]; then vb_say "PASS: $*"; exit 0; fi
  vb_say "FAIL: $VB_FAILS step(s) failed"; exit 1
}
