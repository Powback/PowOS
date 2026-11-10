#!/system/bin/sh
# wb-drawn.sh - runs ON the phone (pushed by window-bench.sh): times "drawn" (a window body that is a picture, not a flat
# fill) on the phone's clock. window-bench's open-drawn and resize-settle were Mac-clock screenshot polls (adb screencap
# | gzip -> Mac -> python, 2-8 s a round trip at Mac load ~35: open-drawn read 8.7-10.9 s, 11-10 p2).
#   wb-drawn.sh <tag> <max ms>     started in the background before the action. Waits for home's console line
#                                  "wb-go <tag> <t0 epoch ms|0> <l> <t> <r> <b> [<l> <t> <r> <b>...]" (logcat PowosShell;
#                                  t0 0 = the watcher's own start; every rect must be drawn; the page logs it when
#                                  the window is live / the resize's pointer is up, with the body's rect in device px),
#                                  then screenshots that rect until it is drawn.
#   -> /data/local/tmp/wb-drawn-<tag>.out: "drawn <ms after t0> <stats>" | "flat <ms> <stats>" | "nogo" | "error <why>"
#   wb-drawn.sh read <tag> <wait ms>   that file's line once written (waits up to <wait ms>; "none" if not), removed.
# A round is one screencap + one python run in the chroot (~0.3 s); the time is taken just before the screencap that
# showed it. Deps: the PowOS chroot's python3, window-render.py copied to its /tmp by window-bench.sh.
outof() { echo "/data/local/tmp/wb-drawn-$(echo "$1" | tr -c 'A-Za-z0-9.\n' _).out"; }
if [ "$1" = read ]; then
  o=$(outof "$2"); i=0; n=$(( ${3:-10000} / 100 ))
  while [ ! -s "$o" ] && [ $i -lt $n ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$o" ] && { cat "$o"; rm -f "$o"; } || echo none
  exit 0
fi
tag=$1 max=${2:-20000}
R=/data/powos/root; f=/tmp/wb-drawn-$$.raw; out=$(outof "$tag")
# Clock: ms since BASE (this run's start second). mksh's arithmetic is 32-bit: epoch ms overflowed (now() read 1484).
BASE=$(date +%s)
now() { set -- $(date '+%s %N'); echo $(( ($1 - BASE) * 1000 + 10#${2%??????} )); }
rel() { local s=${1%???} m=${1#${1%???}}; echo $(( (s - BASE) * 1000 + 10#$m )); }   # epoch ms (13 digits) -> now()'s scale
put() { echo "$*" > $out.tmp; mv -f $out.tmp $out; rm -f $R$f; exit 0; }
rm -f $out
[ -x $R/usr/bin/python3 ] && [ -f $R/tmp/window-render.py ] || put "error no python3 or window-render.py in $R"
start=$(now); end=$((start + max)); since=$(date +'%m-%d %H:%M:%S.000')
# The go line: newest for this tag since this watcher started (-T; `-t N` counts before the tag filter and found
# nothing), whose t0 is not older than the watcher (an earlier run's line is ignored).
go=""
while [ -z "$go" ]; do
  go=$(logcat -d -T "$since" -v raw -s PowosShell:I 2>/dev/null | grep -F "wb-go $tag " | tail -1 | sed 's/.*wb-go //')
  # t0 "0": the clock is this watcher's start (the bench starts it in the same phone call as the action: rotate, unfold).
  if [ -n "$go" ]; then set -- $go; [ "${2:-0}" = 0 ] || [ "$(rel "${2:-0}")" -ge $((start - 2000)) ] 2>/dev/null || go=""; fi
  [ -n "$go" ] && break
  [ $(now) -gt $end ] && put "nogo"
  sleep 0.05
done
set -- $go; [ "$2" = 0 ] && t0=$start || t0=$(rel "$2")
[ "$3" = timeout ] && { shift 3; put "nogo page: $*"; }
shift 2; rects="$*"   # one or more "l t r b": drawn when every one is
# The stages ride along (p5 unfold 4870 ms: the page's go came ~1 s after the screen change, the rest was unaccounted):
# go = ms from t0 to the go line seen, rounds = screenshots taken, flat = the last flat round's verdict.
gm=$(( $(now) - t0 )); n=0; fl=""
while :; do
  ts=$(now); n=$((n + 1))
  screencap > $R$f 2>/dev/null
  st=$(chroot $R /usr/bin/python3 -I /tmp/window-render.py drawnall $f 8 $rects 2>&1); rc=$?
  [ $rc = 0 ] && put "drawn $((ts - t0)) go $gm rounds $n round_ms $(( ($(now) - ts) )) last_flat ${fl:-none} - $st"
  [ $rc = 1 ] || put "error $st"
  fl="$((ts - t0))ms:$(echo $st | tr ' ' _)"
  [ $(now) -gt $end ] && put "flat $((ts - t0)) go $gm rounds $n $st"
done
