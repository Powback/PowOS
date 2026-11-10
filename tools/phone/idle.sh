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
# Pads and keyboards (USB, Bluetooth via uhid, the app's padd pad Steam reads) count too: the watcher also reads every
# /dev/input device's events (getevent) - all but uinput-made virtual ones (injected input) other than pads/keyboards,
# and the haptics motor.
#
#   tools/phone/idle.sh --wait IDLE_S MAX_S   one call that RETURNS when the phone is free: the screen off
#        (Asleep/Dozing), or Awake with no touch for IDLE_S; exit 1 after MAX_S without that. The waiting runs ON THE
#        PHONE (a local 5 s check) over one held adb connection - no VPN round trip per check. Agents never poll the
#        phone in loops (docs/AGENT-HANDBOOK.md); this is what to call instead.
#        A Steam game running with the screen on is the user playing: not free until GAME_IDLE_S (900) s without any
#        input; then it is, and the answer ends in " game=away" (queue.sh skips jobs that would close the game).
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
  need=${2:-60}; max=${3:-600}; gidle=$(( ${GAME_IDLE_S:-900} + 0 )); awake=${AWAKE_ONLY:-0}; go=${VERIFY_GO:-0}; only=${GO_ONLY:-0}
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
      # The Awake streak starts at the screen's real wake (dumpsys power mLastWakeTime), not at this call's first look:
      # every --wait call (each window, each chunk) restarted it and spent IDLE_S (120) s of a screen that had been on,
      # untouched, for long before (docs/research/verify-queue-speed.md, 11-10). The queue's own wake (wl_wake writes
      # powos-queuewake) is no user picking the phone up: its streak counts as served.
      if [ \$w = Awake ]; then
        if [ \$on = 0 ]; then
          wa=\$(dumpsys power | sed -n 's/.*mLastWakeTime=[0-9]* (\\([0-9]*\\) ms ago).*/\\1/p' | head -1)
          on=\$(( \$(date +%s) - \${wa:-0} / 1000 ))
          q=\$(cat /data/local/tmp/powos-queuewake 2>/dev/null); case x\$q in x|x*[!0-9]*) q=0 ;; esac
          [ \$(( on - q )) -le 15 ] && [ \$(( q - on )) -le 15 ] && on=\$(( \$(date +%s) - $need ))
        fi
      else on=0; fi
      a=\$(( \$(date +%s) - on ))
      [ "$go" = 1 ] && { [ "$awake" != 1 ] || [ \$w = Awake ]; } && [ -s /data/powos/root/tmp/powos-verify-go ] && { echo go=\$(head -c 64 /data/powos/root/tmp/powos-verify-go | tr -cd 'A-Za-z0-9_.:-') screen=\$w; exit 0; }
      [ "$go" = 1 ] && [ "$only" != 1 ] && [ -e /data/powos/root/tmp/powos-verify-stop ] && { echo stop screen=\$w; exit 0; }
      # A game running is the user playing, touched or not (23:51, 2026-10-23: a check closed My Friend Pedro mid-game
      # because 2 min without a touch counted as free). Checks wait until it's closed; "test now" (go) still overrides.
      # [r]: the pattern must not match this loop's own command line (it did, so nothing was ever free, 00:3x 2026-10-24).
      # Screen on only: with the screen off nobody is playing, and an APK install keeps the Linux session and its game
      # (2026-10-29: Broforce left running in the background held every install back for an hour, screen dozing).
      # But only while someone is there: no touch/pad/key input for GAME_IDLE_S (900) means the user left it (11-03:
      # Broforce went black at 00:05 and was left running, the screen kept Awake, and no window came all night - 15 checks
      # and installs blocked). That window says game=away: the runner then skips every job that would close the game or
      # Steam (queue.sh, closes_game); the rest may cover it, it stays running.
      g=; [ \$w = Awake ] && pgrep -f '[r]eaper SteamLaunch' >/dev/null 2>&1 && g=' game=away'
      [ -n \"\$g\" ] && [ \$t -lt $gidle ] && { on=0; sleep 5; continue; }
      [ "$only" = 1 ] || case \$w in Asleep|Dozing) [ "$awake" = 1 ] || { echo idle=\$t screen=\$w; exit 0; } ;; Awake) [ \$t -ge $need ] && [ \$a -ge $need ] && { echo idle=\$t screen=\$w\$g; exit 0; } ;; esac
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
# The watcher's version: --ensure restarts a running watcher of another version (a long-lived watcher otherwise kept
# the old logic until the phone rebooted - the file is rewritten under it but sh keeps what it already read).
V=4
if [ "${1:-}" = --ensure ]; then
  now=$(date +%s); boot=$(( now - $(cut -d. -f1 /proc/uptime) ))
  p=$(cat $d/powos-touchmon.pid 2>/dev/null)
  [ -e $d/powos-touchmon.pid ] && [ "$(stat -c %Y $d/powos-touchmon.pid)" -lt $boot ] && { rm -f $d/powos-touchmon.pid; p=; }
  live=0
  case x$p in x|x*[!0-9]*) ;; *) tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -v -e --ensure | grep -q powos-touchmon.sh && live=1 ;; esac
  l=$(cat $d/powos-lasttouch 2>/dev/null); case x$l in x|x*[!0-9]*) l= ;; esac
  # A watcher of an older version: restarted, its lasttouch kept (it saw the same input, only the self-input mask is new).
  if [ $live = 1 ] && [ "$(cat $d/powos-touchmon.ver 2>/dev/null)" != "$V" ]; then
    kill $p 2>/dev/null; g=$(cat $d/powos-touchmon.gpid 2>/dev/null)
    case x$g in x|x*[!0-9]*) ;; *) tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | grep -q '^getevent' && kill $g 2>/dev/null ;; esac
    rm -f $d/powos-touchmon.pid $d/powos-touchmon.gpid
    nohup sh $d/powos-touchmon.sh >/dev/null 2>&1 &
    echo touchmon=upgraded
    [ -n "$l" ] && echo touch=$(( now - l )) || echo touch=unknown
    exit 0
  fi
  if [ $live = 0 ] || [ -z "$l" ]; then
    # A watcher that wasn't running didn't see the touches since: its old lasttouch is untrusted as well.
    [ $live = 1 ] && kill $p 2>/dev/null
    # Its getevent reader too (a reused pid is only killed if it really is getevent).
    g=$(cat $d/powos-touchmon.gpid 2>/dev/null); case x$g in x|x*[!0-9]*) ;; *) tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | grep -q '^getevent' && kill $g 2>/dev/null ;; esac
    rm -f $d/powos-touchmon.pid $d/powos-touchmon.gpid $d/powos-lasttouch; l=
    nohup sh $d/powos-touchmon.sh >/dev/null 2>&1 &
    echo touchmon=restarted
  fi
  [ -n "$l" ] && echo touch=$(( now - l )) || echo touch=unknown
  exit 0
fi
echo $$ > $d/powos-touchmon.pid; echo $V > $d/powos-touchmon.ver
# Every input device, not only the panels: a pad or keyboard game is played without a touch (11-03). getevent appends
# "/dev/input/eventN: type code value" lines to powos-input.ev; each 2 s look keeps the devices that are a person's
# (powos-input.devs: real hardware, or a virtual pad/keyboard - uinput-made touch/nav devices are injected input) and
# empties the file. getevent missing or dead: the panel IRQ counters still work alone (restarted on the next look).
devs() { for e in /sys/class/input/event*; do
    [ -e "$e" ] || continue; n=$(cat $e/device/name 2>/dev/null)
    case "$n" in *[Hh]aptic*) continue ;; esac
    case "$(readlink -f $e)" in */devices/virtual/input/*) echo "$n" | grep -qiE 'pad|controller|joystick|keyboard|mouse' || continue ;; esac
    echo "/dev/input/${e##*/}: "
  done > $d/powos-input.devs; }
gp=; prev=""; i=0; po=; pwf=
while [ $(( $(date +%s) - $(stat -c %Y $d/powos-touchmon.ask 2>/dev/null || echo 0) )) -lt 1800 ]; do
  [ $(( i % 30 )) = 0 ] && devs; i=$(( i + 1 ))
  { [ -n "$gp" ] && kill -0 $gp 2>/dev/null; } || { : > $d/powos-input.ev; getevent -q >> $d/powos-input.ev 2>/dev/null & gp=$!; echo $gp > $d/powos-touchmon.gpid; }
  c=$(awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}' /proc/interrupts)
  ev=0; [ -s $d/powos-input.ev ] && [ -s $d/powos-input.devs ] && grep -qF -f $d/powos-input.devs $d/powos-input.ev && ev=1
  : > $d/powos-input.ev
  # The tools' own screen changes are not the user (11-07 20:20-22:04: ww-glue stopped as "touched" 10 times at night).
  # Waking/sleeping the screen (KEYCODE_WAKEUP/SLEEP from wl_wake/wl_sleep, ship-guard, e2e) makes the touch panels
  # resume/suspend: their IRQ counters move and the panel nodes emit events, with no finger. A tool that changes the
  # screen state writes the epoch until which that is its own (powos-selfinput, see SELF_INPUT in window-lock.sh) first:
  # a change seen up to one sample (2 s) after it is taken in without counting as a touch.
  # A fold-state override (`cmd device_state state N` / `state reset`, the fold checks: game-present-rate, game-resize,
  # bf-fold, ...) powers the other panel up/down: its IRQ counter moves with no finger (11-07 01:44 + 02:06:
  # game-present-rate stopped as "the user picked up the phone" 10 s after its own "fold: cover", twice). Only a tool
  # sets an override - the hinge moves mBaseState - so an mOverrideState change marks the next 8 s as the tools' own.
  o=$(dumpsys device_state 2>/dev/null | grep -m1 mOverrideState=)
  [ -n "$po" ] && [ "$o" != "$po" ] && echo $(( $(date +%s) + 8 )) > $d/powos-selfinput
  po=${o:-none}
  # The screen going off by itself (the user's screen-off timeout: mLastSleepReason=timeout) suspends the panels: their
  # IRQ counters move with no finger (11-10 04:46:58: a doze mid-window read as a touch, the runner left the window and
  # waited WAKE_IDLE_S for a phone nobody had touched). A sleep by the power key is a key event: still the user.
  wf=$(dumpsys power 2>/dev/null | grep -m1 mWakefulness= | cut -d= -f2)
  [ -n "$pwf" ] && [ "$wf" != "$pwf" ] && [ "$wf" != Awake ] && dumpsys power 2>/dev/null | grep -q 'mLastSleepReason=timeout' \
    && echo $(( $(date +%s) + 8 )) > $d/powos-selfinput
  pwf=$wf
  now=$(date +%s); sf=$(cat $d/powos-selfinput 2>/dev/null); case x$sf in x|x*[!0-9]*) sf=0 ;; esac
  if [ "$c" != "$prev" ] || [ $ev = 1 ]; then
    [ $now -le $(( sf + 3 )) ] || date +%s > $d/powos-lasttouch
    prev=$c
  fi
  sleep 2
done
[ -n "$gp" ] && kill $gp 2>/dev/null
rm -f $d/powos-touchmon.pid $d/powos-touchmon.gpid $d/powos-input.ev
EOF
"$here/adb.sh" shell 'touch /data/local/tmp/powos-touchmon.ask; su -c "sh /data/local/tmp/powos-touchmon.sh --ensure";
  dumpsys power | grep -m1 -E "^ *lastUserActivityTime="; dumpsys power | grep -m1 mWakefulness=' 2>/dev/null | tr -d '\r' |
  awk '/^touch=/{split($0,t,"="); idle=t[2]}
       /lastUserActivityTime=/{ if (match($0, /\(([0-9]+) ms ago\)/)) { s=substr($0, RSTART+1, RLENGTH-9); act=int(s/1000) } }
       /mWakefulness=/{split($0,b,"="); w=b[2]}
       END{ if (idle == "" || idle == "unknown") idle = act; printf "idle=%d screen=%s act=%d\n", idle, w, act }'
