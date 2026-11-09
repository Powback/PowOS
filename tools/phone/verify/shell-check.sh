#!/bin/bash
# lanes: emu phone
# shell-check.sh <page> <shell/dev check file> <function> [arg...]: a gate check, run in the PHONE's live page (the
# real host, its real apps and windows) - the gate's own code, so the device check and the gate scene can't drift.
# The file is inlined (its `export`s dropped; it may not import - checks reach modules through importShim / the
# window.__gw shim set up here, the gate's helpers: sleep, frames, until, still, settled, steady, mod). An argument
# "@fold" is the screen the phone is on now ("folded" | "unfolded"). The function returns the gate's answer: a list
# of fails ([] = PASS); a first entry "SKIP: <why>" is a SKIP (its precondition isn't on the phone now).
# Run it through tools/phone/verify/queue.sh add (a free window): a check may drive the page (open the drawer, the
# switcher) but must put back what it changed. Screencap: $OUT/<function>.png. Exit 0 PASS, 1 FAIL, 5 SKIP, 3 no window.
# Sourced (SHELL_CHECK_LIB=1), it only defines shell_check <page> <file> <fn> [arg...] (prints the JSON answer).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$here/..; ROOT=$(cd "$here/../../.." && pwd)

# The screen the phone is on now.
phone_fold() { case $("$T/adb.sh" shell "dumpsys device_state | grep -m1 mCommittedState" 2>/dev/null) in *CLOSED*) echo folded ;; *) echo unfolded ;; esac; }

# The gate's in-page helpers (gate.mjs window.__gw), for a page that never ran in the gate.
GW_SHIM='if(!window.__gw){const sleep=(ms)=>new Promise((r)=>setTimeout(r,ms));const frames=(n=1)=>new Promise((ok)=>{const f=(k)=>(k<=0?ok():requestAnimationFrame(()=>f(k-1)));f(n)});const until=async(f,ms=8000)=>{const t0=performance.now();while(!(await f())){if(performance.now()-t0>ms)return false;await sleep(16)}return true};const documentAnimations=(sel)=>document.getAnimations().filter((a)=>a.playState==="running"&&a.timeline===document.timeline&&(!sel||a.effect?.target?.closest?.(sel)));const still=(sel)=>!documentAnimations(sel).some((a)=>a.effect?.getComputedTiming().endTime!==Infinity);const settled=async(f=()=>true,sel,ms=8000)=>(await until(async()=>(await f())&&still(sel),ms))&&(await frames(2),true);const steady=async(f,n=3,ms=8000)=>{const t0=performance.now();let last=JSON.stringify(await f()),same=0;while(same<n){if(performance.now()-t0>ms)return false;await frames(1);const now=JSON.stringify(await f());same=now===last?same+1:0;last=now}return true};const mods=new Map();const mod=(p)=>{if(!mods.has(p))mods.set(p,window.importShim(p).catch((e)=>(mods.delete(p),Promise.reject(e))));return mods.get(p)};window.__gw={sleep,frames,until,still,settled,steady,mod,documentAnimations}}'

shell_check() {
  local page=$1 file=$2 fn=$3; shift 3
  local src args="" a
  src=$(sed -E 's/^export (async function|function|const|let)/\1/' "$ROOT/shell/dev/$file") || { echo '["no such check file"]'; return; }
  for a in "$@"; do
    [ "$a" = @fold ] && a=$(phone_fold)
    args+="${args:+,}$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  done
  "$T/cdp.sh" eval "$page" "(async()=>{${GW_SHIM};${src}
;try{return JSON.stringify(await ${fn}(${args}))}catch(e){return JSON.stringify(['threw: '+(e&&e.stack||e)])}})()" 2>&1 | tail -1 | sed -E 's/^"(.*)"$/\1/; s/\\"/"/g'
}

[ -n "${SHELL_CHECK_LIB:-}" ] && return 0

[ $# -ge 3 ] || { echo "usage: shell-check.sh <page> <shell/dev file> <function> [arg...|@fold]"; exit 2; }
OUT=${OUT:-$HOME/.cache/powos-verify/shell-check-$3-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
. "$here/window-lock.sh"
window_lock "shell-check-$3" 120
trap '[ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
r=$(shell_check "$@")
"$T/shot.sh" "$OUT/$3.png" >/dev/null 2>&1 || true
echo "shell-check $3 ($(phone_fold)): $r"
case $r in
  '[]') echo "PASS $3: the gate check holds on the phone (shot $OUT/$3.png)"; exit 0 ;;
  '["SKIP:'*) echo "SKIP: $3: $(sed -E 's/^\["SKIP: ?//; s/"\]$//' <<<"$r")"; exit 5 ;;
  *) echo "FAIL $3: $r"; exit 1 ;;
esac
