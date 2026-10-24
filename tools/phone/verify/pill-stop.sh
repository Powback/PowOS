#!/bin/bash
# tools/phone/verify/pill-stop.sh <token> (Mac; queue it: `queue.sh add --close <task> --budget 400
#   tools/phone/verify/pill-stop.sh $(date +%s)`): the status pill's stop + resume, end to end on the real runner.
# This check is itself the long check that gets stopped:
#   run 1: starts a detached asserter (outside the runner's process tree), then just runs (120 s) until it's killed.
#     The asserter taps the pill's x (VerifyRun.kt: its only touch target), then asserts: run 1 ended, the queue is
#     paused (~/.cache/powos-verify-queue/paused, the phone's runner state "paused"), the pill says "Tests paused
#     [Resume]" (its log line), the job is still queued; then taps Resume and asserts the pause ended.
#   run 2 (the resume runs the still-queued job again): prints the asserter's result - PASS, or its FAIL lines.
# Taps only the pill (nothing to restore). Q: QUEUE_DIR, as queue.sh.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P); phone=$(cd "$here/.." && pwd -P)
tok=${2:-${1:?usage: pill-stop.sh <token>}}
Q=${QUEUE_DIR:-$HOME/.cache/powos-verify-queue}
D=$HOME/.cache/powos-verify-pillstop/$(printf %s "$tok" | tr -cd 'A-Za-z0-9_-'); R=$D/result
A=$phone/adb.sh
sh_() { perl -e 'alarm shift; exec @ARGV' 20 "$A" shell "$1" 2>/dev/null | tr -d '\r'; }
# The pill's window frame: left top right bottom ("" when it isn't up) - e2e-lib.sh's pillrect.
pillrect() { sh_ "dumpsys window windows" | awk '/^ *Window #/{f=(index($0,"PowOS verify status")>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' '; }
T=; pilllog() { sh_ "logcat -d -v brief ${T:+-T '$T'} -s PowosVerify | grep 'pill ' | tail -1"; }
pillup() { [ -n "$(echo $(pillrect))" ]; }
said() { pilllog | grep -q "$1"; }
# until_ <s> <cmd...>: 0 once cmd succeeds, 1 after s seconds.
until_() { local e=$(( $(date +%s) + $1 )); shift; until "$@"; do [ "$(date +%s)" -lt $e ] || return 1; sleep 1; done; }
# tapend <dp from the right>: tap the pill's right end, centred vertically.
tapend() { local r d; r=($(pillrect)); [ ${#r[@]} = 4 ] || return 1
  d=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); d=${d:-420}
  sh_ "input tap $(( r[2] - $1 * d / 160 )) $(( (r[1] + r[3]) / 2 ))" >/dev/null; echo "tapped $(( r[2] - $1 * d / 160 )),$(( (r[1] + r[3]) / 2 )) (pill ${r[*]})"; }

if [ "${1:-}" = --assert ]; then
  run1=$3; f=0; out() { echo "$*"; echo "$*" >> "$R.tmp"; }; bad() { out "FAIL: $*"; f=1; }
  : > "$R.tmp"
  T=$(sh_ "date +'%m-%d %H:%M:%S.000'")   # only this run's pill lines (never logcat -c: the log is everyone's)
  sleep 5   # run 1's first beat: the pill shows this check
  if until_ 40 pillup; then out "ok: the pill is up"; else bad "no status pill while the check runs"; fi
  t=$(tapend 13) && out "$t" || bad "can't find the pill to tap its x"
  until_ 30 bash -c "! kill -0 $run1 2>/dev/null" && out "ok: the running check ended (pid $run1)" || bad "the running check (pid $run1) still runs 30 s after the x"
  until_ 20 test -e "$Q/paused" && out "ok: the queue is paused" || bad "the queue isn't paused ($Q/paused missing)"
  st=$(sh_ "cat /data/local/tmp/powos-verify-runner"); [ "$st" = paused ] && out "ok: the phone's runner state: paused" || bad "the phone's runner state is '$st', not paused"
  grep -lsq "pill-stop.sh" "$Q"/*.job && out "ok: the stopped check is still queued" || bad "the stopped check left the queue"
  until_ 10 said 'pill PAUSED: Tests paused \[Resume\]'
  l=$(pilllog); case "$l" in *"pill PAUSED: Tests paused [Resume]"*) out "ok: the pill says: Tests paused [Resume]" ;; *) bad "the pill doesn't say paused: '$l'" ;; esac
  t=$(tapend 26) && out "$t" || bad "can't find the paused pill to tap Resume"
  until_ 30 test ! -e "$Q/paused" && out "ok: Resume ended the pause" || bad "still paused 30 s after Resume"
  sh_ "logcat -d -v brief -T '$T' -s PowosVerify" | grep 'pill' | sed 's/^/info: /' >> "$R.tmp"
  [ $f = 0 ] && out "PASS: x stopped the check and paused the queue, the pill said so, Resume resumed"
  mv -f "$R.tmp" "$R"; exit 0
fi

if [ -d "$D" ]; then   # run 2: the asserter's result
  until_ 90 test -e "$R" || { echo "FAIL: no result from the stop asserter in 90 s (log $D/assert.log)"; exit 1; }
  cat "$R"; grep -q '^FAIL' "$R" && exit 1
  rm -rf "$D"; exit 0
fi
mkdir -p "$D"
# Detached: the runner kills this check's whole process tree on the stop; the asserter must outlive it.
( nohup bash "$0" --assert "$tok" $$ </dev/null >"$D/assert.log" 2>&1 & )
echo "run 1: the asserter taps the pill's x; this check runs until it's stopped"
for i in $(seq 120); do sleep 1; done
echo "FAIL: not stopped in 120 s (asserter log $D/assert.log)"; exit 1
