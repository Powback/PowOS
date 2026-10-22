#!/bin/bash
# Seconds since the user last touched the phone, and the screen state:
#   "idle=<s> screen=<Awake|Dozing|Asleep> act=<s>"
# Drive the phone (injected input, screenrecord journeys, installs that restart the session) only when idle>=120
# and screen=Awake; never wake the screen with key events.
#
# idle comes from the touch panels' interrupt counters (touch-00 / touch-01 in /proc/interrupts): only a real finger
# raises them - injected input (input swipe / motionevent, uinput) and app wakelocks don't. dumpsys power's
# lastUserActivityTime (reported as act=) is NOT a user signal on its own: a screen-bright wakelock, an APK install
# restarting com.powos.app or another agent's injected input all reset it.
# A tiny watcher on the phone (/data/local/tmp/powos-touchmon.sh, every 2 s, started here if not running) writes the
# epoch of the last counter change to /data/local/tmp/powos-lasttouch. Right after it starts, idle counts from then
# (conservative). The watcher is ephemeral, not a service: it exits by itself when idle.sh hasn't asked for 30 min
# (each call touches /data/local/tmp/powos-touchmon.ask), so nothing stays running on the phone between sessions.
# Not covered: a Bluetooth gamepad (no IRQ of its own) - check act= too if a pad is connected.
#
#   tools/phone/idle.sh --wait IDLE_S MAX_S   one call that RETURNS when the phone is free: the screen off
#        (Asleep/Dozing), or Awake with no touch for IDLE_S; exit 1 after MAX_S without that. The waiting runs ON THE
#        PHONE (a local 5 s check) over one held adb connection - no VPN round trip per check. Agents never poll the
#        phone in loops (docs/AGENT-HANDBOOK.md); this is what to call instead.
#        AWAKE_ONLY=1: return only for Awake + idle (a check that needs the screen on waits through doze; never wakes it).
#        VERIFY_GO=1: also return "go=<task|all> screen=<..>" at once when the AI page's "test now" wrote PowOS's
#        /tmp/powos-verify-go (the user hands the phone over; tools/phone/verify/queue.sh's runner clears it).
here=$(dirname "$0")
if [ "${1:-}" = "--wait" ]; then
  need=${2:-60}; max=${3:-600}; awake=${AWAKE_ONLY:-0}; go=${VERIFY_GO:-0}
  "$0" >/dev/null   # starts the touch watcher if it isn't running
  # Awake counts only once the screen has been ON for IDLE_S too: after a long sleep the last touch is hours old, so
  # "no touch for IDLE_S" alone said free the moment the user woke the phone to use it.
  # The held connection can drop (the VPN's adb, ~8 min in): it's held again for what's left, not given up on - an
  # empty answer is a dropped connection, never "busy". The Awake streak restarts with it (conservative).
  deadline=$(( $(date +%s) + max ))
  while :; do
  left=$(( deadline - $(date +%s) ))
  [ $left -gt 0 ] || { out=timeout; break; }
  out=$("$here/adb.sh" shell "end=\$(( \$(date +%s) + $left )); on=0; while [ \$(date +%s) -lt \$end ]; do
      touch /data/local/tmp/powos-touchmon.ask
      w=\$(dumpsys power | grep -m1 mWakefulness= | cut -d= -f2)
      t=\$(( \$(date +%s) - \$(cat /data/local/tmp/powos-lasttouch 2>/dev/null || date +%s) ))
      [ \$w = Awake ] && { [ \$on = 0 ] && on=\$(date +%s); } || on=0
      a=\$(( \$(date +%s) - on ))
      [ "$go" = 1 ] && [ -s /data/powos/root/tmp/powos-verify-go ] && { echo go=\$(head -c 64 /data/powos/root/tmp/powos-verify-go | tr -cd 'A-Za-z0-9_.:-') screen=\$w; exit 0; }
      case \$w in Asleep|Dozing) [ "$awake" = 1 ] || { echo idle=\$t screen=\$w; exit 0; } ;; Awake) [ \$t -ge $need ] && [ \$a -ge $need ] && { echo idle=\$t screen=\$w; exit 0; } ;; esac
      sleep 5
    done; echo timeout" 2>/dev/null | tr -d '\r' | tail -1)
  [ -n "$out" ] && break
  sleep 10
  done
  echo "$out"
  case "$out" in idle=*|go=*) exit 0 ;; *) exit 1 ;; esac
fi
"$here/adb.sh" shell 'cat > /data/local/tmp/powos-touchmon.sh' <<'EOF'
# powos-touchmon.sh: every 2 s, the epoch of the last touch-panel IRQ count change -> /data/local/tmp/powos-lasttouch
# (started by tools/phone/idle.sh on the Mac; stop: pkill -f powos-touchmon.sh)
echo $$ > /data/local/tmp/powos-touchmon.pid
prev=""
while [ $(( $(date +%s) - $(stat -c %Y /data/local/tmp/powos-touchmon.ask 2>/dev/null || echo 0) )) -lt 1800 ]; do
  c=$(awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}' /proc/interrupts)
  [ "$c" != "$prev" ] && { date +%s > /data/local/tmp/powos-lasttouch; prev=$c; }
  sleep 2
done
rm -f /data/local/tmp/powos-touchmon.pid
EOF
"$here/adb.sh" shell 'touch /data/local/tmp/powos-touchmon.ask; su -c "kill -0 \$(cat /data/local/tmp/powos-touchmon.pid 2>/dev/null) 2>/dev/null || { nohup sh /data/local/tmp/powos-touchmon.sh >/dev/null 2>&1 & sleep 1; }";
  echo touch=$(( $(date +%s) - $(cat /data/local/tmp/powos-lasttouch 2>/dev/null || date +%s) ));
  dumpsys power | grep -m1 -E "^ *lastUserActivityTime="; dumpsys power | grep -m1 mWakefulness=' 2>/dev/null | tr -d '\r' |
  awk '/^touch=/{split($0,t,"="); idle=t[2]}
       /lastUserActivityTime=/{ if (match($0, /\(([0-9]+) ms ago\)/)) { s=substr($0, RSTART+1, RLENGTH-9); act=int(s/1000) } }
       /mWakefulness=/{split($0,b,"="); w=b[2]} END{ printf "idle=%d screen=%s act=%d\n", idle, w, act }'
