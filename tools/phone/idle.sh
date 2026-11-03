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
#        VERIFY_GO=1: also return "go=<task|all> screen=<..>" (respecting AWAKE_ONLY) when the AI page's "test now" wrote PowOS's
#        /tmp/powos-verify-go (the user hands the phone over; tools/phone/verify/queue.sh's runner clears it), and
#        "stop screen=<..>" when the status pill's tap wrote /tmp/powos-verify-stop (the runner pauses).
#        GO_ONLY=1 (the runner paused): return for the go flag only. VERIFY_STATE=<word>: the runner's state for the
#        AI page (VerifyRun.kt state): written to /data/local/tmp/powos-verify-runner, touched at every 5 s check (its
#        heartbeat: a dead runner's goes stale).
here=$(dirname "$0")
# The emulator lane (POWOS_DEVICE=emu): nobody touches it - always free, screen on (it never sleeps: emu.sh).
if [ "${POWOS_DEVICE:-phone}" = emu ]; then echo "idle=86400 screen=Awake act=86400"; exit 0; fi
"$here/adb.sh" --transport-state >/dev/null || { echo transport-error; exit 70; }
# Off the VPN (a stale WireGuard handshake, tools/phone/adb.sh --vpn-state): "offline", exit 69 - never an empty state
# that reads as busy or free. --wait keeps waiting for it to come back (checked every 30 s on the Mac, no adb call).
if [ "${1:-}" != "--wait" ] && ! "$here/adb.sh" --vpn-state >/dev/null; then echo "offline"; exit 69; fi
if [ "${1:-}" = "--wait" ]; then
  need=${2:-60}; max=${3:-600}; awake=${AWAKE_ONLY:-0}; go=${VERIFY_GO:-0}; only=${GO_ONLY:-0}
  st=$(printf %s "${VERIFY_STATE:-}" | tr -cd 'a-z'); hb=/data/local/tmp/powos-verify-runner
  # Awake counts only once the screen has been ON for IDLE_S too: after a long sleep the last touch is hours old, so
  # "no touch for IDLE_S" alone said free the moment the user woke the phone to use it.
  # The held connection can drop (the VPN's adb, ~8 min in): it's held again for what's left, not given up on - an
  # empty answer is a dropped connection, never "busy". The Awake streak restarts with it (conservative).
  deadline=$(( $(date +%s) + max ))
  while :; do
  left=$(( deadline - $(date +%s) ))
  [ $left -gt 0 ] || { out=${off:-timeout}; break; }
  "$here/adb.sh" --transport-state >/dev/null || { echo transport-error; exit 70; }
  if ! "$here/adb.sh" --vpn-state >/dev/null; then off=offline; sleep $(( left < 30 ? left : 30 )); continue; fi; off=
  # (Re)starts the touch watcher before every held connection, not once: a connection dropped by a phone reboot comes
  # back to a phone whose watcher is gone (11-02 21:57 reboot: nothing restarted it and idle read 0 until 00:46).
  "$0" >/dev/null
  out=$("$here/adb.sh" shell "end=\$(( \$(date +%s) + $left )); on=0; [ -n '$st' ] && printf %s '$st' > $hb
    while [ \$(date +%s) -lt \$end ]; do
      touch /data/local/tmp/powos-touchmon.ask; [ -n '$st' ] && touch $hb
      w=\$(dumpsys power | grep -m1 mWakefulness= | cut -d= -f2)
      # An empty/missing/garbled lasttouch is NOT \"touched now\" (an empty file read as 0 s idle forever, 11-02): this
      # sample falls back to lastUserActivityTime (never longer than the real touch idle); the next connection restarts
      # the watcher (powos-touchmon.sh --ensure).
      l=\$(cat /data/local/tmp/powos-lasttouch 2>/dev/null)
      case x\$l in x|x*[!0-9]*) ms=\$(dumpsys power | sed -n 's/.*lastUserActivityTime=[^(]*(\\([0-9]*\\) ms ago).*/\\1/p' | head -1)
        l=\$(( \$(date +%s) - \${ms:-0} / 1000 )) ;; esac
      t=\$(( \$(date +%s) - l ))
      [ \$w = Awake ] && { [ \$on = 0 ] && on=\$(date +%s); } || on=0
      a=\$(( \$(date +%s) - on ))
      [ "$go" = 1 ] && { [ "$awake" != 1 ] || [ \$w = Awake ]; } && [ -s /data/powos/root/tmp/powos-verify-go ] && { echo go=\$(head -c 64 /data/powos/root/tmp/powos-verify-go | tr -cd 'A-Za-z0-9_.:-') screen=\$w; exit 0; }
      [ "$go" = 1 ] && [ "$only" != 1 ] && [ -e /data/powos/root/tmp/powos-verify-stop ] && { echo stop screen=\$w; exit 0; }
      # A game running is the user playing, touched or not (23:51, 2026-10-23: a check closed My Friend Pedro mid-game
      # because 2 min without a touch counted as free). Checks wait until it's closed; "test now" (go) still overrides.
      # [r]: the pattern must not match this loop's own command line (it did, so nothing was ever free, 00:3x 2026-10-24).
      # Screen on only: with the screen off nobody is playing, and an APK install keeps the Linux session and its game
      # (2026-10-29: Broforce left running in the background held every install back for an hour, screen dozing).
      [ \$w = Awake ] && pgrep -f '[r]eaper SteamLaunch' >/dev/null 2>&1 && { on=0; sleep 5; continue; }
      [ "$only" = 1 ] || case \$w in Asleep|Dozing) [ "$awake" = 1 ] || { echo idle=\$t screen=\$w; exit 0; } ;; Awake) [ \$t -ge $need ] && [ \$a -ge $need ] && { echo idle=\$t screen=\$w; exit 0; } ;; esac
      sleep 5
    done; echo timeout" 2>/dev/null | tr -d '\r' | tail -1)
  [ -n "$out" ] && break
  sleep 10
  done
  echo "$out"
  case "$out" in idle=*|go=*|stop*) exit 0 ;; *) exit 1 ;; esac
fi
"$here/adb.sh" shell 'cat > /data/local/tmp/powos-touchmon.sh' <<'EOF'
# powos-touchmon.sh: every 2 s, the epoch of the last touch-panel IRQ count change -> /data/local/tmp/powos-lasttouch
# (started by tools/phone/idle.sh on the Mac; stop: pkill -f powos-touchmon.sh)
# sh powos-touchmon.sh --ensure (as root): restart the watcher unless it is really running, then print touch=<s>, or
# touch=unknown when the last-touch file can't be trusted (the caller then uses lastUserActivityTime for that sample).
# "Running" = the pid file is from this boot AND /proc/<pid>/cmdline is this script: `kill -0` alone passed for a
# reused pid after a reboot (11-02 21:57: the 21:27 pid file named com.google.android.youtube), so the watcher never
# restarted, powos-lasttouch stayed empty and idle read 0 s forever - the verify queue ran nothing for 4 h.
d=/data/local/tmp
if [ "${1:-}" = --ensure ]; then
  now=$(date +%s); boot=$(( now - $(cut -d. -f1 /proc/uptime) ))
  p=$(cat $d/powos-touchmon.pid 2>/dev/null)
  [ -e $d/powos-touchmon.pid ] && [ "$(stat -c %Y $d/powos-touchmon.pid)" -lt $boot ] && { rm -f $d/powos-touchmon.pid; p=; }
  live=0
  case x$p in x|x*[!0-9]*) ;; *) tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -v -e --ensure | grep -q powos-touchmon.sh && live=1 ;; esac
  l=$(cat $d/powos-lasttouch 2>/dev/null); case x$l in x|x*[!0-9]*) l= ;; esac
  if [ $live = 0 ] || [ -z "$l" ]; then
    # A watcher that wasn't running didn't see the touches since: its old lasttouch is untrusted as well.
    [ $live = 1 ] && kill $p 2>/dev/null
    rm -f $d/powos-touchmon.pid $d/powos-lasttouch; l=
    nohup sh $d/powos-touchmon.sh >/dev/null 2>&1 &
    echo touchmon=restarted
  fi
  [ -n "$l" ] && echo touch=$(( now - l )) || echo touch=unknown
  exit 0
fi
echo $$ > $d/powos-touchmon.pid
prev=""
while [ $(( $(date +%s) - $(stat -c %Y $d/powos-touchmon.ask 2>/dev/null || echo 0) )) -lt 1800 ]; do
  c=$(awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}' /proc/interrupts)
  [ "$c" != "$prev" ] && { date +%s > $d/powos-lasttouch; prev=$c; }
  sleep 2
done
rm -f $d/powos-touchmon.pid
EOF
"$here/adb.sh" shell 'touch /data/local/tmp/powos-touchmon.ask; su -c "sh /data/local/tmp/powos-touchmon.sh --ensure";
  dumpsys power | grep -m1 -E "^ *lastUserActivityTime="; dumpsys power | grep -m1 mWakefulness=' 2>/dev/null | tr -d '\r' |
  awk '/^touch=/{split($0,t,"="); idle=t[2]}
       /lastUserActivityTime=/{ if (match($0, /\(([0-9]+) ms ago\)/)) { s=substr($0, RSTART+1, RLENGTH-9); act=int(s/1000) } }
       /mWakefulness=/{split($0,b,"="); w=b[2]}
       END{ if (idle == "" || idle == "unknown") idle = act; printf "idle=%d screen=%s act=%d\n", idle, w, act }'
