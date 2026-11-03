#!/bin/bash
# test-idle-touchmon.sh: tools/phone/idle.sh's touch watcher after a phone reboot (11-02: the verify queue ran nothing
# 20:36-00:46). The pid file left from before the 21:57 reboot named a reused pid (YouTube), `kill -0` passed, the
# watcher never restarted, powos-lasttouch stayed empty and idle read 0 s forever. A fake adb.sh runs the phone side
# locally (/data/local/tmp and /proc mapped into a temp dir; su, dumpsys, nohup faked): a stale pid of another process
# or a pid file from before the boot -> the watcher restart is issued and idle falls back to act (not 0); a live
# watcher -> no restart, idle from its lasttouch; --wait with an empty lasttouch reads act, not 0.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/idle-touchmon-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }

mkdir -p "$T/tools" "$T/bin" "$T/dlt" "$T/proc"
cp "$src/tools/phone/idle.sh" "$T/tools/idle.sh"
cat > "$T/tools/adb.sh" <<EOF2
#!/bin/bash
case "\$1" in --transport-state|--vpn-state) exit 0 ;; esac
[ "\$1" = shell ] || exit 0   # adb shell joins its args with spaces, as the real one does
cmd=\$(shift; printf %s "\$*" | sed -e "s#/data/local/tmp#$T/dlt#g" -e "s#/proc/#$T/proc/#g")
case "\$cmd" in
  "cat > "*) f=\${cmd#cat > }; sed -e "s#/data/local/tmp#$T/dlt#g" -e "s#/proc/#$T/proc/#g" > "\$f" ;;
  *) PATH="$T/bin:\$PATH" sh -c "\$cmd" ;;
esac
EOF2
cat > "$T/bin/su" <<'EOF2'
#!/bin/sh
[ "$1" = -c ] && exec sh -c "$2"
EOF2
cat > "$T/bin/dumpsys" <<'EOF2'
#!/bin/sh
echo "  lastUserActivityTime=123456 (45000 ms ago)"
echo "  mWakefulness=Awake"
EOF2
cat > "$T/bin/nohup" <<EOF2
#!/bin/sh
echo "nohup \$*" >> "$T/restart.log"
EOF2
chmod +x "$T/tools/"*.sh "$T/bin/"*

# The phone booted 600 s ago; pid 14646 is YouTube, pid 777 is the real watcher.
printf '600.12 1200.00\n' > "$T/proc/uptime"
mkdir -p "$T/proc/14646" "$T/proc/777"
printf 'com.google.android.youtube\0' > "$T/proc/14646/cmdline"
printf "sh\0$T/dlt/powos-touchmon.sh\0" > "$T/proc/777/cmdline"
now=$(date +%s)
run() { : > "$T/restart.log"; out=$(bash "$T/tools/idle.sh" "$@" 2>&1); rc=$?; }

# 1. A pid file from this boot naming another process + an empty lasttouch.
echo 14646 > "$T/dlt/powos-touchmon.pid"; : > "$T/dlt/powos-lasttouch"
run
if grep -q 'powos-touchmon.sh' "$T/restart.log" && [ "$out" = "idle=45 screen=Awake act=45" ]; then
  ok "stale pid of another process + empty lasttouch: watcher restarted, idle=act (45), not 0"
else bad "stale pid of another process + empty lasttouch" "rc=$rc out=$out"$'\n'"$(cat "$T/restart.log")"; fi

# 2. A pid file from before this boot (even one whose pid now runs the script) + an old lasttouch.
echo 777 > "$T/dlt/powos-touchmon.pid"; touch -d "@$(( now - 7200 ))" "$T/dlt/powos-touchmon.pid"
echo $(( now - 5000 )) > "$T/dlt/powos-lasttouch"
run
if grep -q 'powos-touchmon.sh' "$T/restart.log" && [ ! -e "$T/dlt/powos-touchmon.pid" ] && [ "$out" = "idle=45 screen=Awake act=45" ]; then
  ok "pid file older than the boot: cleared, watcher restarted, the pre-reboot lasttouch not trusted"
else bad "pid file older than the boot" "rc=$rc out=$out"$'\n'"$(cat "$T/restart.log")"; fi

# 3. The real watcher running, lasttouch 300 s ago: left alone, idle from lasttouch.
echo 777 > "$T/dlt/powos-touchmon.pid"; echo $(( now - 300 )) > "$T/dlt/powos-lasttouch"
run
idle=$(sed -n 's/^idle=\([0-9]*\) .*/\1/p' <<<"$out")
if [ ! -s "$T/restart.log" ] && [ -n "$idle" ] && [ "$idle" -ge 300 ] && [ "$idle" -le 305 ]; then
  ok "live watcher: no restart, idle from lasttouch ($idle)"
else bad "live watcher" "rc=$rc out=$out"$'\n'"$(cat "$T/restart.log")"; fi

# 4. --wait with an empty lasttouch (the watcher not yet writing): returns on act, never stuck at idle 0.
echo 14646 > "$T/dlt/powos-touchmon.pid"; : > "$T/dlt/powos-lasttouch"
run --wait 0 20
if [ $rc = 0 ] && grep -q '^idle=4[5-9] screen=Awake$' <<<"$out"; then
  ok "--wait with an empty lasttouch: the sample reads act ($out), not 0 / an arithmetic error"
else bad "--wait with an empty lasttouch" "rc=$rc out=$out"; fi

# 5./6. A game running with the screen on (2026-10-23: a check closed My Friend Pedro after 2 min without a touch;
# 11-03: Broforce left frozen and running held every window all night). The real watcher is live (777), so idle comes
# from lasttouch. A pgrep stub stands in for `reaper SteamLaunch`.
cat > "$T/bin/pgrep" <<'EOF2'
#!/bin/sh
case "$*" in *SteamLaunch*) [ -e "${GAME_FLAG:-/nonexistent}" ] ;; *) exit 1 ;; esac
EOF2
chmod +x "$T/bin/pgrep"; : > "$T/game"; export GAME_FLAG=$T/game
echo 777 > "$T/dlt/powos-touchmon.pid"; echo $(( $(date +%s) - 60 )) > "$T/dlt/powos-lasttouch"
run --wait 0 12
if [ $rc = 1 ] && [ "$out" = timeout ]; then
  ok "game running + a touch 60 s ago: not free ($out)"
else bad "game running + a touch 60 s ago" "rc=$rc out=$out"; fi
echo 777 > "$T/dlt/powos-touchmon.pid"; echo $(( $(date +%s) - 1000 )) > "$T/dlt/powos-lasttouch"
run --wait 0 12
if [ $rc = 0 ] && grep -q '^idle=10[0-9][0-9] screen=Awake game=away$' <<<"$out"; then
  ok "game running + no input for 1000 s: free, marked game=away ($out)"
else bad "game running + no input for 1000 s" "rc=$rc out=$out"; fi
# The watcher reads every input device, not only the touch panels' IRQs (a pad/keyboard game has no touch).
if grep -q 'getevent -q' "$src/tools/phone/idle.sh" && grep -q 'powos-input.devs' "$src/tools/phone/idle.sh"; then
  ok "the watcher counts /dev/input events (pads, keyboards) too"
else bad "the watcher counts only the touch panels"; fi
rm -f "$T/game"

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
