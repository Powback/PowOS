#!/bin/bash
# test-skip-reason-last.sh: a check's SKIP reason reaches the queue's verdict (11-10 04:13, window-task-ime: "SKIP test
# error (rc 5): : restored; ..." - its SKIP line carried a clock prefix and the trap's "restored" line came after it),
# and window-task-ime's KWin cap probe finds "window-ime" in a UTF-16 caps literal (QStringLiteral: the plain grep
# never matched, so every run SKIPped on a KWin that had the cap).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd); q=$root/tools/phone/verify/queue.sh; w=$root/tools/phone/verify/window-task-ime.sh
fails=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1${2:+ - $2}"; fails=$((fails + 1)); }
T=$(mktemp -d "${TMPDIR:-/tmp}/skipwhy.XXXXXX"); trap 'rm -rf "$T"' EXIT

# 1. queue.sh's rc-5 reason, run on that log.
line=$(grep -m1 'if \[ \$rc = 5 \]; then skipwhy=' "$q" | sed -E 's/^ *if \[ \$rc = 5 \]; then //')
[ -n "$line" ] || { echo "FAIL the rc-5 skipwhy line isn't in queue.sh"; exit 1; }
log=$T/log; printf 'build: x\n04:46:36 SKIP: the running KWin has no window-ime cap\nrestored; artefacts /tmp/x\n' > "$log"
eval "$line"
case $skipwhy in *": SKIP: the running KWin has no window-ime cap") ok "a clock-prefixed SKIP line is the reason" ;;
  *) bad "clock-prefixed SKIP reason" "$skipwhy" ;; esac

# 2. window-task-ime prints its SKIP reason last (after restore's lines), via skip().
grep -q 'trap .*restore.*echo "\$WHY"' "$w" && ok "window-task-ime's EXIT trap prints the reason after restore" \
  || bad "the EXIT trap ends with the reason"
n=$(grep -c 'log "SKIP' "$w"); [ "$n" = 0 ] && ok "every SKIP goes through skip()" || bad "bare SKIP/exit 5 left" "$n"

# 3. The cap probe's pipeline on a UTF-16 caps string (and not on a library without it).
printf 'quit window-ime fullscreen' | iconv -f UTF-8 -t UTF-16LE > "$T/lib"
probe() { LC_ALL=C tr -d '\000' < "$1" | LC_ALL=C grep -aq 'window-ime'; }
probe "$T/lib" && ok "the probe finds window-ime in a UTF-16 literal" || bad "UTF-16 window-ime found"
printf 'quit fullscreen' | iconv -f UTF-8 -t UTF-16LE > "$T/lib2"
probe "$T/lib2" && bad "no false yes without the cap" || ok "no cap -> no"
grep -q "tr -d '\\\\\\\\000' < /usr/lib/libkwin.so.6 | LC_ALL=C grep -aq 'window-ime'" "$w" && ok "window-task-ime uses that pipeline" \
  || bad "window-task-ime's probe strips NULs"
[ $fails = 0 ]
