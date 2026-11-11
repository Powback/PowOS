#!/bin/bash
# test-phone-orphans.sh - phone-side check processes can't outlive their run (11-11: two wb-drawn.sh watchers, tags
# test:x/test:y, ran 19.5 h at ppid 1 and held a game at ~2 fps):
#   1. a wb-drawn.sh watcher whose clock never reaches its end (now() broken) exits on its own $SECONDS deadline;
#   2. one stuck inside a call (logcat hangs) is ended by its timeout wrapper;
#   3. the queue's sweep (phone-orphans.sh orphan_pick) picks only the exact check command lines, past the age.
# No pipefail on purpose (see test-base.sh).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
V="$ROOT/tools/phone/verify"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; FAIL=$((FAIL+1)); }
T=$(mktemp -d); trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT

# A fake phone: sh = bash (mksh-alike: $SECONDS, 10#), the chroot's python3 + window-render.py present, no screencap.
mkdir -p "$T/bin" "$T/root/usr/bin" "$T/root/tmp" "$T/out"
printf '#!/bin/sh\nexit 1\n' > "$T/root/usr/bin/python3"; : > "$T/root/tmp/window-render.py"
printf '#!/bin/sh\nexec bash "$@"\n' > "$T/bin/sh"
chmod +x "$T/bin/sh" "$T/root/usr/bin/python3"

echo "== 1. a watcher whose clock is broken ends on its deadline =="
mkdir -p "$T/b1"; cp "$T/bin/sh" "$T/b1/sh"
printf '#!/bin/sh\n:\n' > "$T/b1/logcat"
printf '#!/bin/sh\ncase "$1" in "+%%s %%N") echo garbage x ;; *) /bin/date "$@" ;; esac\n' > "$T/b1/date"   # now() fails
chmod +x "$T/b1/"*
t0=$SECONDS
PATH="$T/b1:$PATH" WBD_CAPPED=1 WBD_SLACK_S=2 WBD_ROOT="$T/root" WBD_OUT_DIR="$T/out" \
  perl -e 'alarm 20; exec @ARGV' bash "$V/wb-drawn.sh" test:x 1000 >/dev/null 2>&1; rc=$?
el=$((SECONDS - t0)); o=$(cat "$T/out/wb-drawn-test_x.out" 2>/dev/null)
[ "$rc" = 0 ] && [ "$el" -le 6 ] && [ "$o" = "nogo deadline" ] && ok "exited in ${el}s: $o" || bad "rc $rc after ${el}s, out '$o' (want 'nogo deadline' within 6 s)"

echo "== 2. a watcher stuck in a call is ended by its timeout =="
if command -v timeout >/dev/null; then
  mkdir -p "$T/b2"; cp "$T/bin/sh" "$T/b2/sh"
  printf '#!/bin/sh\nexec sleep 60\n' > "$T/b2/logcat"; chmod +x "$T/b2/"*
  t0=$SECONDS
  PATH="$T/b2:$PATH" WBD_SLACK_S=2 WBD_ROOT="$T/root" WBD_OUT_DIR="$T/out" \
    perl -e 'alarm 30; exec @ARGV' bash "$V/wb-drawn.sh" test:y 1000 >/dev/null 2>&1; rc=$?
  el=$((SECONDS - t0))
  [ "$rc" != 142 ] && [ "$el" -le 10 ] && ok "ended by its cap in ${el}s (rc $rc)" || bad "still running after ${el}s (rc $rc; want <= 10 s, cap 3 s + 3 s kill)"
else
  bad "no timeout(1) in this environment"
fi

echo "== 3. the sweep picks only check processes past the age =="
. "$V/phone-orphans.sh"
got=$(orphan_pick 300 <<'EOF'

    1     0  2-09:06:40 init second_stage
  101     1  19:30:01 sh /data/local/tmp/wb-drawn.sh test:x 15000
  102   101     00:01 logcat -d -T 11-10 06:30:00.000 -v raw -s PowosShell:I
  103     1     02:00 sh /data/local/tmp/wb-drawn.sh open:kate 30000
  104     1  1-02:00:00 timeout 330 logcat -v time -s PowosShade:V PowosShell:V chromium:D
  105   104  1-02:00:00 logcat -v time -s PowosShade:V PowosShell:V chromium:D
  106   900     30:00 logcat -v time -s PowosShell:V
  107     1     30:00 logcat -v time -s ActivityManager:I
  108     1     30:00 sh /data/local/tmp/other.sh x 1
  109     1     30:00 sh /data/local/tmp/wb-drawn.sh x 1; rm -rf /
  110   900     30:00 timeout -k 3 35 sh /data/local/tmp/wb-drawn.sh settle:3 20000
  111     1     30:00 sh /data/local/tmp/wb-drawnXsh x 1
  112     1     30:00 sh /sdcard/wb-drawn.sh x 1
  113     1     30:00 logcat -v time -s PowosShell:V *:E
  114     1     30:00 logcat -d -v time -s PowosShell:V
  115     1     30:00 sh /data/local/tmp/wb-drawn.sh read open:a 8000
EOF
)
want='101 104 105 110 115'
[ "$(echo $(awk '{print $1}' <<< "$got"))" = "$want" ] && ok "picked $want" || bad "picked: $(echo $(awk '{print $1}' <<< "$got")) (want $want)" "$got"
grep -q '^101 70201 sh /data/local/tmp/wb-drawn.sh test:x 15000$' <<< "$got" && ok "age from ETIME, args kept" || bad "line for 101" "$got"
[ -z "$(orphan_pick 100000 <<< '  101     1  19:30:01 sh /data/local/tmp/wb-drawn.sh test:x 15000')" ] && ok "younger than the budget: kept" || bad "a young watcher was picked"

echo "== 4. window-bench ends its own watchers by pid =="
grep -q '^  drawn_stop$' "$V/window-bench.sh" && [ "$(grep -c 'drawn_stop$' "$V/window-bench.sh")" -ge 2 ] && ok "restore_bench and hard_stop run drawn_stop" || bad "drawn_stop not in both exit paths"
grep -q 'phone-orphans.sh" "$budget"' "$V/queue.sh" && ok "the queue sweeps after every job" || bad "queue.sh does not run phone-orphans.sh"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
