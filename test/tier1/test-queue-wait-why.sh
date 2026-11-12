#!/bin/bash
# test-queue-wait-why.sh: a verify-queue wait for a free window says WHY in the runner's log, once per change - never
# silence (11-12 22:07-23:50: the phone dozing at 10% battery, unplugged; wl_wake declined to wake it every minute into
# queue.sh's `window_lock ... >/dev/null` and the runner logged nothing for 1h40 with 9 runnable jobs queued).
# window_lock is run against a fake adb/idle.sh with a 1 s chunk, so it looks at the phone many times in a few seconds.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/queue-wait-why.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }
mkdir -p "$T/tools" "$T/set"
cat > "$T/tools/adb.sh" <<EOF2
#!/bin/bash
[ "\$1" = shell ] && shift
cmd="\$*"
if [ "\$cmd" = 'dumpsys battery' ]; then read -r l p < "$T/batt"; echo "  AC powered: \$p"; echo "  USB powered: false"; echo "  level: \$l"; exit 0; fi
settings() { case \$1 in get) cat "$T/set/\$3" ;; put) echo "\$4" > "$T/set/\$3" ;; esac; }
input() { case \$2 in KEYCODE_WAKEUP) echo Awake > "$T/wake" ;; KEYCODE_SLEEP) echo Dozing > "$T/wake" ;; esac; }
wm() { :; }; sleep() { :; }; dumpsys() { :; }; date() { :; }
eval "\$cmd" 2>/dev/null; exit 0
EOF2
# idle.sh: bare = the state; --wait = free only when Awake (AWAKE_ONLY), else "timeout" after a short look.
cat > "$T/tools/idle.sh" <<EOF2
#!/bin/bash
if [ "\${1:-}" = --wait ]; then
  [ "\$(cat "$T/wake")" = Awake ] && { echo "idle=\$(cat "$T/idle") screen=Awake"; exit 0; }
  sleep 0.2; echo timeout; exit 1; fi
echo "idle=\$(cat "$T/idle") screen=\$(cat "$T/wake") act=0"
EOF2
chmod +x "$T/tools/"*.sh
reset() { echo 87 > "$T/set/screen_brightness"; echo 1 > "$T/set/screen_brightness_mode"; echo 60000 > "$T/set/screen_off_timeout"
  echo Dozing > "$T/wake"; echo "$1" > "$T/idle"; echo "$2 $3" > "$T/batt"; rm -rf "$T/woke" "$T/.cache"; mkdir -p "$T/.cache"; }
# wait_runner MAX_S: the runner's call exactly (stdout to /dev/null), stderr = what reaches runner.log.
wait_runner() { HOME=$T WL_WOKE=$T/woke WL_LASTWIN=$T/none WL_PHONE=$T/tools WL_CHUNK_S=1 bash -c \
  '. "$1"; ( window_lock verify-queue 120 "$2" >/dev/null || exit 3 )' _ "$src/tools/phone/verify/window-lock.sh" "$1" 2>"$T/err"; }

# 1. dozing, idle 9 h, battery 10% unplugged (the 11-12 night): no window, and the log says why - exactly once.
reset 34210 10 false; wait_runner 4; rc=$?
n=$(grep -c 'battery is at 10% and not charging' "$T/err")
[ $rc = 3 ] && [ "$(cat "$T/wake")" = Dozing ] && ok "battery 10% unplugged: not woken, no window (rc 3)" || bad "low battery: no window" "rc=$rc wake=$(cat "$T/wake")"
[ "$n" = 1 ] && ok "the wait logs its reason (battery 10%, not charging) once over many looks" || bad "the wait logs its reason once (got $n lines)" "$(cat "$T/err")"
grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2} verify-queue waits for a free window: ' "$T/err" && ok "the line is timestamped and names the waiter" || bad "line format" "$(cat "$T/err")"
# The line must not read as a job result in queue-util.py's history (HEND: '<time> <job>: PASS|FAIL|...').
python3 -I - "$T/err" <<'PY' && ok "queue-util.py's history parser ignores it" || bad "history parser reads the wait line as a job"
import re, sys
HEND = re.compile(r"^(\d\d):(\d\d):(\d\d) (\S+): (PASS|FAIL|SKIP|INVALID|no window|rc 3|stopped|past its)(.*)$")
RUN = re.compile(r"^(\d\d):(\d\d):(\d\d) run (\S+): ")
sys.exit(any(HEND.match(l) or RUN.match(l) for l in open(sys.argv[1])))
PY

# 2. the reason changes (the phone touched recently) -> a new line, again only once.
reset 300 80 false; wait_runner 3
n=$(grep -c 'touched in the last 600 s' "$T/err")
[ "$n" = 1 ] && ok "touched recently: a different reason, said once" || bad "recent touch reason once (got $n)" "$(cat "$T/err")"

# 3. charging again: woken, the window taken - the wake is in the log too.
reset 34210 10 true; wait_runner 4; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/wake")" = Awake ] && grep -q 'woke the phone at minimum brightness' "$T/err" \
  && ok "battery 10% charging: woken, window taken, the wake logged" || bad "charging: woken + logged" "rc=$rc $(cat "$T/err")"

# 4. nothing runnable (GO_ONLY): queue.sh says that itself each poll - window_lock adds nothing.
reset 34210 80 false; HOME=$T WL_WOKE=$T/woke WL_PHONE=$T/tools WL_CHUNK_S=1 GO_ONLY=1 bash -c \
  '. "$1"; ( window_lock verify-queue 120 2 >/dev/null )' _ "$src/tools/phone/verify/window-lock.sh" 2>"$T/err"
[ ! -s "$T/err" ] && ok "GO_ONLY: no extra line (the runner's own 'waits for its ship' line covers it)" || bad "GO_ONLY quiet" "$(cat "$T/err")"

# 5. queue.sh keeps window_lock's stderr (the reason) in runner.log: only stdout goes to /dev/null.
grep -qE 'window_lock verify-queue "\$\{QUEUE_IDLE_S:-120\}" "\$wmax" >/dev/null \|\| exit 3' "$src/tools/phone/verify/queue.sh" \
  && ok "queue.sh: window_lock's stderr reaches runner.log" || bad "queue.sh window_lock call drops stderr"
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
