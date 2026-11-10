#!/bin/bash
# lanes: phone
# linux-cold-open.sh [OUT]: (Mac side; queue it: queue.sh add --close linux-apps-opened-as-their-own-task-e-g-dolphin
# tools/phone/verify/linux-cold-open.sh) each Linux app (APPS, default dolphin kate konsole) opened COLD - no process of
# it running - as its own Android task, the drawer's way (powos-run.sh -> powos-open-task, as RootedGuest.openAsTask),
# timed on the phone's clock: launch -> exec -> KWin's task -> first frame live on the host (linux-cold-open-phone.sh).
# One BENCH line and a bench.tsv row (metric app value budget verdict) per stage; the verdict is launch -> live against
# COLD_BUDGET_MS (2000). A launch that rebuilt a ksycoca6 cache in-process says so (the 11-10 04:38 cause:
# docs/research/linux-app-cold-start.md). An app already running is skipped (never the user's window); what this check
# started is closed (its pid, its task) and home comes back. Exit: 0 PASS; 1 FAIL; 3 a real touch / not now; 5 ENV.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
APPS=${APPS:-"dolphin kate konsole"}; COLD_BUDGET_MS=${COLD_BUDGET_MS:-2000}
OUT=${1:-$HOME/.cache/powos-verify/linux-cold-open-$(date +%m%d-%H%M)}; mkdir -p "$OUT"; R=$OUT/log.txt
TSV=$OUT/bench.tsv; printf 'metric\tapp\tvalue\tbudget\tverdict\n' > "$TSV"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
log() { echo "$(date +%T) $*" | tee -a "$R"; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
tasks() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
FAILS=0
bench() {  # bench <metric> <app> <ms|-> <budget|""> : a row, and a FAIL past the budget
  local v=PASS; [ -n "$4" ] && { [ "$3" = - ] || [ "$3" -gt "$4" ]; } && v=FAIL; [ -z "$4" ] && v=INFO
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:+<=${4}ms}" "$v" >> "$TSV"
  log "BENCH $1 $2: ${3}ms${4:+ (budget <=${4}ms)} $v"; [ $v = FAIL ] && FAILS=$((FAILS + 1)); true
}

. "$here/window-lock.sh"
window_lock linux-cold-open.sh 120
WHY=""; STARTED_PIDS=""; NEWTASKS=""
restore() {
  for p in $STARTED_PIDS; do sh_ "kill $p" >/dev/null; done
  sleep 1; for t in $NEWTASKS; do [ -n "$(sh_ "am stack list | grep -E \"taskId=${t}[^0-9]\"")" ] && sh_ "am stack remove $t"; done
  sh_ "rm -f /data/local/tmp/powos-cold-*"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  echo "restored; artefacts $OUT"
}
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"; [ -z "$WHY" ] || echo "$WHY"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { log "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { log "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ -n "$(sh_ "pidof kwin_wayland")" ] || { WHY="SKIP: KWin isn't running in the session"; exit 5; }
log "apk $(sh_ "dumpsys package com.powos.app | grep -m1 versionName" | sed 's/ *//')"
"$A" shell "su -c 'cat > /data/local/tmp/powos-cold-open.sh'" < "$here/linux-cold-open-phone.sh"

ran=0
for a in $APPS; do
  case $a in dolphin|kate|konsole) id=org.kde.$a; exe=$a; ex=$a ;; *) id=$a; exe=$a; ex=$a ;; esac
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk "before $a"
  before=$(tasks)
  r=$(sh_ "sh /data/local/tmp/powos-cold-open.sh $id $exe $ex $a"); echo "$r" > "$OUT/$a.txt"
  chk "after $a"
  if grep -qx 'running=1' <<<"$r"; then log "$a already runs (maybe the user's): not cold, skipped"; continue; fi
  ran=$((ran + 1))
  g() { sed -n "s/^$1=//p" <<<"$r" | head -1; }
  p=$(g pid); [ "$p" != - ] && [ -n "$p" ] && STARTED_PIDS="$STARTED_PIDS $p"
  NEWTASKS="$NEWTASKS $(comm -13 <(echo "$before") <(tasks) | tr '\n' ' ')"
  bench cold-exec "$a" "$(g exec)" ""
  bench cold-task "$a" "$(g task)" ""
  bench cold-status "$a" "$(g status)" ""
  bench cold-live "$a" "$(g live)" "$COLD_BUDGET_MS"
  sy=$(g sycoca_rebuilt); [ -n "${sy// /}" ] && log "NOTE $a: this launch rebuilt ksycoca6 cache(s): $sy (a stale cache for the launch's XDG_DATA_DIRS)"
  h=$(g helper); [ -n "$h" ] && log "$a powos-open-task stages:$h"
  "$T/shot.sh" "$OUT/opened-$a.png" >/dev/null 2>&1
  for q in $p; do [ "$q" != - ] && sh_ "kill $q" >/dev/null; done; sleep 1.5
done
[ $ran -gt 0 ] || { WHY="SKIP: every app in APPS already runs - no cold open possible now"; exit 5; }
[ $FAILS = 0 ] || { log "FAIL: $FAILS cold-open stage(s) over budget - $TSV"; exit 1; }
log "PASS: every cold open reached its first frame within ${COLD_BUDGET_MS} ms"
