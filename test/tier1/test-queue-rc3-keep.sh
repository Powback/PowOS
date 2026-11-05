#!/bin/bash
# test-queue-rc3-keep.sh: a check that ends rc 3 ("SKIP phone in use: ...", bf-pacing's INVALID "game wasn't on the
# screen", a touch) STAYS QUEUED however many tries - the 5th rc 3 used to move the job to done/ as "SKIP phone in
# use" and the measurement never ran (11-05: 194920, 215351, 221526, 221528). Each try's log is appended to
# done/<job>.log.tries, from the 5th try the job backs off (held by select_jobs until after=), and a later PASS
# finishes it as usual. Drives queue.sh's own rc3_requeue / rc3_waits / select_jobs (the runner needs a phone).
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)/tools/phone/verify/queue.sh
fns=$(sed -n '/^rc3_requeue() {/,/echo "\$after"; }$/p; /^rc3_waits() {/p' "$src")
sel=$(sed -n '/^  select_jobs() {/,/^    done; }$/p' "$src")
[ -n "$fns" ] && [ -n "$sel" ] || { echo "FAIL couldn't find rc3_requeue/rc3_waits/select_jobs in queue.sh"; exit 1; }
eval "$fns"; eval "$sel"
shipped() { return 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/rc3-keep.XXXXXX"); trap 'rm -rf "$T"' EXIT
Q=$T/q; mkdir -p "$Q/done"
fails=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1${2:+ - $2}"; fails=$((fails + 1)); }

# The fake check: "SKIP phone in use" + exit 3 for its first 6 runs, then PASS.
cat > "$T/check.sh" <<EOF
#!/bin/bash
c=\$(cat "$T/count" 2>/dev/null || echo 0); c=\$((c + 1)); echo \$c > "$T/count"
if [ \$c -le 6 ]; then echo "measuring run \$c"; echo "SKIP phone in use: touched run \$c"; exit 3; fi
echo "PASS measured on run \$c"; exit 0
EOF
chmod +x "$T/check.sh"
j=$Q/20261105-221526-1-broforce.job; n=$(basename "$j" .job); log=$Q/done/$n.log
printf 'task=broforce\nclose=0\ntries=0\ncwd=%q\nrel=0\nname=bf\nbudget=300\nneed=\nqt=0\ncmd=(%q base)\n' "$T" "$T/check.sh" > "$j"

now=1000000; last_after=0
date() { [ "${1:-}" = +%s ] && echo "$now" || command date "$@"; }   # the runner's clock, for rc3_waits
for i in 1 2 3 4 5 6 7; do
  tries=0; after=0; cmd=(); . "$j"
  select_jobs "" >/dev/null 2>&1
  if [ $i -ge 6 ]; then   # backing off: held at its after=, selected once that time has passed
    [ ${#sel[@]} = 0 ] || bad "try $i: a backing-off job is held, not selected" "sel=${#sel[@]} after=$after"
    now=$((after + 1)); select_jobs "" >/dev/null 2>&1
  fi
  [ ${#sel[@]} = 1 ] || { bad "try $i: the job is selected" "sel=${#sel[@]}"; break; }
  echo "build: test" > "$log"; "${cmd[@]}" >> "$log" 2>&1; rc=$?
  if [ $rc = 3 ]; then last_after=$(rc3_requeue "$j" "$log" "$tries" "$now")
  else echo "PASS: $(tail -1 "$log")" >> "$log"; mv "$j" "$Q/done/$n.job"; fi
done

[ ! -f "$j" ] && [ -f "$Q/done/$n.job" ] && ok "6 SKIP-phone-in-use tries kept it queued; the 7th run (PASS) finished it" \
  || bad "job finished after its PASS" "$(ls "$Q" "$Q/done")"
tail -1 "$log" | grep -q '^PASS' && ok "the final log's verdict is PASS (no SKIP verdict on the board)" || bad "final verdict PASS" "$(tail -1 "$log")"
grep -q '^SKIP' "$log" && bad "the final log carries no earlier try's SKIP" || ok "the final log carries no earlier try's SKIP"
nt=$(grep -c '^=== try ' "$log.tries" 2>/dev/null); ns=$(grep -c '^SKIP phone in use: touched run' "$log.tries" 2>/dev/null)
[ "$nt" = 6 ] && [ "$ns" = 6 ] && ok "all 6 rc-3 tries' logs are appended to $n.log.tries" || bad "6 tries appended" "headers=$nt skips=$ns"
grep -q '^tries=6$' "$Q/done/$n.job" && ok "tries counted to 6" || bad "tries=6" "$(grep '^tries' "$Q/done/$n.job")"
[ "$last_after" -gt 0 ] && ok "from the 5th try it backs off (after=$last_after)" || bad "backoff after the 5th try"

# Tries 1-4 don't back off (the next window runs it); the backoff is capped at 30 min.
j2=$Q/x.job; printf 'task=t\ntries=0\ncmd=(true)\n' > "$j2"
a=$(rc3_requeue "$j2" "$Q/none.log" 0 100); [ "$a" = 0 ] && ok "try 1: no backoff" || bad "try 1: no backoff" "after=$a"
a=$(rc3_requeue "$j2" "$Q/none.log" 40 100); [ "$a" = 1900 ] && ok "backoff capped at 1800 s" || bad "backoff cap" "after=$a"
[ "$(grep -c '^tries=' "$j2")" = 1 ] && [ "$(grep -c '^after=' "$j2")" = 1 ] && ok "one tries=/after= line each" || bad "duplicate tries/after lines" "$(cat "$j2")"

# The runner's rc 3 branch has no tries cap any more and never turns rc 3 into a done SKIP.
grep -q 'if \[ \$rc = 3 \] && \[ \$tries -lt' "$src" && bad "runner still caps rc 3 tries" || ok "runner keeps every rc 3 queued"
grep -q 'r="SKIP phone in use"' "$src" && bad "runner still writes a SKIP phone in use verdict" || ok "no SKIP-phone-in-use verdict left"

echo; [ $fails = 0 ] && { echo "All tests passed"; exit 0; }; echo "$fails tests failed"; exit 1
