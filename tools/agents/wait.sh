#!/usr/bin/env bash
# wait.sh <pid | file-or-glob | "cmd"> [max_s<=110] [pattern]
# Blocks ONCE instead of poll loops. Returns when:
#   pid   : the process has exited
#   file  : (glob -> newest match) has a line matching pattern (default: PASS|FAIL|DONE|ok|error)
#   "cmd" : the shell command exits 0
# Then prints the last ~15 relevant lines (PASS/FAIL-ish lines of the file, else its tail). Exit 0 = done,
# 124 = timed out (still prints what there is).
t="${1:?usage: wait.sh <pid|file-pattern|\"cmd\"> [max_s<=110] [pattern]}"; max="${2:-100}"; pat="${3:-PASS|FAIL|DONE|[Oo]k|[Ee]rror}"
[ "$max" -gt 110 ] 2>/dev/null && max=110
end=$(( $(date +%s) + max )); rc=124
newest() { ls -t $t 2>/dev/null | head -1; }
while [ "$(date +%s)" -lt "$end" ]; do
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    kill -0 "$t" 2>/dev/null || { rc=0; echo "pid $t exited"; break; }
  elif [ -n "$(newest)" ]; then
    f=$(newest); grep -Eq "$pat" "$f" 2>/dev/null && { rc=0; break; }
  elif [[ "$t" == *" "* ]]; then
    bash -c "$t" >/dev/null 2>&1 && { rc=0; echo "cmd ok: $t"; break; }
  fi
  sleep 0.5
done
[ -n "${f:-}" ] || f=$(newest)
if [ -n "$f" ] && [ -f "$f" ]; then
  echo "== $f"; { grep -E "$pat" "$f" | tail -15; } | grep . || tail -15 "$f"
fi
[ $rc = 124 ] && echo "wait.sh: timed out after ${max}s (still running)"
exit $rc
