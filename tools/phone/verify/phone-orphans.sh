#!/usr/bin/env bash
# phone-orphans.sh - the verify queue's post-job sweep of phone-side check processes left behind by a killed or
# interrupted check. 11-11: two wb-drawn.sh watchers (window-bench) had run 19.5 h at ppid 1 (50 + 27 CPU-min, a
# logcat dump every 50 ms) and e2e logcat readers likewise - a game drew at ~2 fps and checks failed. Each check
# bounds and ends its own (wb-drawn.sh caps itself, window-bench's drawn_stop, e2e's timeout 330); this is the backstop.
#
#   phone-orphans.sh <min age s> [log]   kill what matches, older than <min age s> (the job's budget); one line each
#   . phone-orphans.sh; orphan_pick <min age s> < "pid ppid etime args" lines   -> "pid age args" of the matches
#
# Matches ONLY these exact check command lines (anything else on the phone is never touched):
#   - [timeout [-k N] N] sh /data/local/tmp/wb-drawn.sh <tag> <ms>|read <tag> <ms>   (any parent: it is ours)
#   - [timeout [-k N] N] logcat [-T 1] -v time -s <tags>  where every tag is a check tag (Powos*, WindowTasks,
#     Andromarchy, LaunchWindows, RenderWatch, WebWindowSource, ActivityTaskManager, ActivityStarter, chromium,
#     com.powos.app) and it is orphaned (ppid 1, or its timeout parent is) - a reader someone runs by hand is not
# A match's children go with it (pkill -P); each pid's cmdline is re-read on the phone just before the kill.
OP_WBD='^(timeout( -k [0-9]+)? [0-9]+ )?sh /data/local/tmp/wb-drawn[.]sh (read )?[^ ]+ [0-9]+$'
OP_LOGCAT='^(timeout( -k [0-9]+)? [0-9]+ )?logcat( -T 1)? -v time -s( [^ ]+)+$'
OP_TAG='^(Powos[A-Za-z]*|WindowTasks|Andromarchy|LaunchWindows|RenderWatch|WebWindowSource|ActivityTaskManager|ActivityStarter|chromium|com[.]powos[.]app)(:[VDIWEF])?$'

# orphan_pick: one awk pass (a bash loop forking per line took > 2 min over the phone's ~1100 processes on a loaded Mac).
orphan_pick() {
  awk -v min="$1" -v wbd="$OP_WBD" -v lc="$OP_LOGCAT" -v tag="$OP_TAG" '
    function secs(e,   d, n, p) { d = 0; if (e ~ /-/) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, p, ":"); if (n == 3) return d * 86400 + p[1] * 3600 + p[2] * 60 + p[3]
      if (n == 2) return d * 86400 + p[1] * 60 + p[2]; return 0 }
    function argsof(l) { sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", l); return l }
    $1 ~ /^[0-9]+$/ { n++; P[n] = $1; PP[n] = $2; E[n] = secs($3); A[n] = argsof($0); PPof[$1] = $2; Aof[$1] = A[n] }
    END { for (i = 1; i <= n; i++) {
      if (E[i] <= min) continue
      if (A[i] ~ wbd) { print P[i], E[i], A[i]; continue }
      if (A[i] !~ lc) continue
      t = A[i]; sub(/.* -s /, "", t); k = split(t, T, " "); ok = 1
      for (j = 1; j <= k; j++) if (T[j] !~ tag) ok = 0
      if (!ok) continue
      # orphaned: ppid 1, or a `timeout ... logcat` parent that is itself at ppid 1 (the parent is then picked too)
      if (PP[i] == 1 || (PPof[PP[i]] == 1 && Aof[PP[i]] ~ /^timeout .*logcat /)) print P[i], E[i], A[i]
    } }'
}

# orphan_sweep <min age s> <adb> [log]: list, pick, kill each still-matching pid with its children; logs each.
orphan_sweep() {
  local min=$1 adb=$2 log=${3:-/dev/stderr} ps picked pids pid age args
  ps=$(perl -e 'alarm shift; exec @ARGV' 15 "$adb" shell "su -c 'ps -A -o PID=,PPID=,ETIME=,ARGS='" 2>/dev/null | tr -d '\r') || return 0
  picked=$(orphan_pick "$min" <<< "$ps"); [ -n "$picked" ] || return 0
  pids=$(awk '{print $1}' <<< "$picked" | tr '\n' ' ')
  # Re-check on the phone: the pid still runs wb-drawn.sh or logcat (not reused since the listing), then kill it.
  perl -e 'alarm shift; exec @ARGV' 15 "$adb" shell "su -c 'for p in $pids; do c=\$(tr \"\\\\0\" \" \" < /proc/\$p/cmdline 2>/dev/null); case \$c in *wb-drawn.sh*|logcat*|timeout*logcat*) pkill -P \$p; kill \$p ;; esac; done'" >/dev/null 2>&1
  while read -r pid age args; do echo "$(date +%T) phone orphan killed: pid $pid, ${age}s old (> ${min}s): $args" >> "$log"; done <<< "$picked"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  here=$(cd "$(dirname "$0")" && pwd -P)
  [ $# -ge 1 ] || { echo "usage: phone-orphans.sh <min age s> [log]" >&2; exit 2; }
  orphan_sweep "$1" "${PHONE_ADB:-$here/../adb.sh}" "${2:-/dev/stderr}"
fi
