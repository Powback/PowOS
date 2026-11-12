# tools/phone/verify/window-lock.sh (sourced): a free window first, the verify lock only then - handbook rule 5a: the
# lock (~/.cache/powos-verify.lock) is never held through a wait, since ship-apk won't install while it exists.
#   . "$(dirname "$0")/window-lock.sh"; window_lock <name> [idle_s=120] [max_s=$WAIT_S or 7200]
# Returns once the phone is free (screen on, nobody touching it for idle_s) AND this script holds the lock (released on
# exit: a trap). If another check holds the lock, it waits for it WITHOUT holding anything, then waits for a free window
# again. Exit 3: no free window in max_s. LOCK_HELD=1: the caller holds the lock already (nothing done).
# VERIFY_GO=1 (exported; queue.sh's runner): the phone's "test now" flag ends the wait at once; WL_GOT says what ended
# it ("idle=... screen=..." or "go=<task|all> screen=..."); the pill's stop flag ends it with exit 6 (the runner pauses).
# WL_PHONE: the tools/phone dir to use (the runner's, a stub in tests). VERIFY_STATE set (the runner): while another
# check holds the lock, its heartbeat file on the phone is touched at each 20 s look (idle.sh's).
# wl_wake <phone dir>: the user's OK (11-07 "yeah do whatever"): jobs wait (not GO_ONLY), the screen is off and nobody
# touched the phone for WAKE_IDLE_S (600) s -> wake it at minimum brightness for the batch. The user's brightness,
# brightness mode and screen-off timeout are saved first ($WL_WOKE: b= m= t= at=) and wl_restore puts them back
# exactly; the screen-off timeout is held at 30 min so the screen stays on through the window (11-07 05:31-09:20: the
# old wake let the phone doze again before the 120 s idle window came - 25 jobs never ran). The keyguard: only
# `wm dismiss-keyguard` (dismisses a swipe lock; a PIN/pattern lock stays up - never entered). Battery below
# WAKE_MIN_BATT (20) % and not charging: never woken.
WL_WOKE=${WL_WOKE:-$HOME/.cache/powos-verify-woke}
# SELF_INPUT: prefix for an adb shell command that changes the screen state (KEYCODE_WAKEUP/SLEEP, a power key): it
# marks the next 8 s as the tools' own on the phone (powos-selfinput, read by idle.sh's touch watcher), since the
# panels' resume/suspend move the touch IRQ counters and emit panel events with no finger. Without it every wake counted
# as the user picking the phone up: wl_touched stopped the woken window's first check within 4 s (11-07 20:20-22:04,
# ww-glue rc 3 "touched" 10 times at night, nothing ran).
# self_input_for <s>: the same mark for the next <s> s - a check's own injected input that lasts longer than a key (the
# pad presses of pad-lib.sh: powos-padd's controller is an input device idle.sh counts as a person's; bf-play).
self_input_for() { printf 'echo $(( $(date +%%s) + %d )) > /data/local/tmp/powos-selfinput; ' "${1:-8}"; }
SELF_INPUT=$(self_input_for 8)
# wl_save <phone dir>: the user's brightness, its mode and the screen-off timeout saved to $WL_WOKE (once: a second
# call keeps the first save) with at=<now>; rc 1 when they can't be read. HELD=1 marks a hold (wl_hold), not a wake.
wl_save() { [ -s "$WL_WOKE" ] && return 0
  local cur b m t
  cur=$("$1/adb.sh" shell 'echo b=$(settings get system screen_brightness); echo m=$(settings get system screen_brightness_mode); echo t=$(settings get system screen_off_timeout)' 2>/dev/null | tr -d '\r')
  b=$(sed -n 's/^b=\([0-9]*\)$/\1/p' <<<"$cur"); m=$(sed -n 's/^m=\([0-9]*\)$/\1/p' <<<"$cur"); t=$(sed -n 's/^t=\([0-9]*\)$/\1/p' <<<"$cur")
  [ -n "$b" ] && [ -n "$m" ] && [ -n "$t" ] || return 1
  mkdir -p "$(dirname "$WL_WOKE")"; printf 'b=%s\nm=%s\nt=%s\nat=%s\n%s' "$b" "$m" "$t" "$(date +%s)" "${HELD:+held=1
}" > "$WL_WOKE"; }
# wl_hold <phone dir>: a window that found the screen already on (nobody woke it) keeps it on: the user's screen-off
# timeout saved (wl_save) and held at 30 min until wl_sleep/wl_restore put it back, brightness untouched. Without it
# the window ran on the user's 30 s timeout: 11-10 04:46:58 the screen dozed between two checks, ww-clamp said "screen
# not on" and the doze read as a touch, so the window ended with 25 jobs runnable. A touch since the hold stops the
# check like one on a woken phone (wl_touched).
wl_hold() {
  [ -z "${GO_ONLY:-}" ] || return 0
  [ -s "$WL_WOKE" ] && return 0
  HELD=1 wl_save "$1" || return 0
  "$1/adb.sh" shell "settings put system screen_off_timeout 1800000" >/dev/null 2>&1; }
# WL_WHY (set by every call): why the phone isn't free / wasn't woken, in words stable across looks (no running
# seconds), so window_lock logs it once per change (wl_say) - empty when GO_ONLY (the caller says why itself).
wl_wake() {
  WL_WHY=; [ -z "${GO_ONLY:-}" ] || return 0
  local st i bat lvl pw
  st=$("$1/idle.sh" 2>/dev/null); i=$(sed -n 's/.*idle=\([0-9]*\).*/\1/p' <<<"$st")
  case "$st" in *screen=Awake*) WL_WHY="the screen is on - waiting until nobody has touched it for the window's idle time"; return 0 ;; esac
  [ -n "$i" ] || { WL_WHY="the phone doesn't answer (idle.sh: ${st:-no answer})"; return 0; }
  # Nobody touched the phone since the queue's last window opened ($WL_LASTWIN, written by queue.sh: that window began
  # on an idle phone) -> that is enough, no fresh WAKE_IDLE_S: a short window (an install yield, a re-pick) put the
  # screen back off, and the next one waited up to 600 s for a phone nobody had picked up (11-10).
  local need=${WAKE_IDLE_S:-600} lw since
  lw=$(cat "${WL_LASTWIN:-$HOME/.cache/powos-verify-lastwin}" 2>/dev/null); case $lw in ''|*[!0-9]*) lw=0 ;; esac
  since=$(( $(date +%s) - lw ))
  [ "$lw" -gt 0 ] && [ $since -ge 0 ] && [ $since -lt "$need" ] && need=$(( since > ${QUEUE_IDLE_S:-120} ? since : ${QUEUE_IDLE_S:-120} ))
  if [ "$i" -lt "$need" ]; then
    if [ "$need" -lt "${WAKE_IDLE_S:-600}" ]; then WL_WHY="the screen is off and the phone was touched since the queue's last window - not woken"
    else WL_WHY="the screen is off and the phone was touched in the last ${WAKE_IDLE_S:-600} s - not woken until it's untouched that long"; fi
    return 0; fi
  bat=$("$1/adb.sh" shell 'dumpsys battery' 2>/dev/null | tr -d '\r')
  lvl=$(sed -n 's/^ *level: *\([0-9]*\).*/\1/p' <<<"$bat" | head -1)
  pw=0; grep -qE '^ *(AC|USB|Wireless|Dock) powered: true' <<<"$bat" && pw=1
  if [ "$pw" = 0 ] && [ -n "$lvl" ] && [ "$lvl" -lt "${WAKE_MIN_BATT:-20}" ]; then
    WL_WHY="the screen is off and the battery is at ${lvl}% and not charging - not woken under ${WAKE_MIN_BATT:-20}% (plug the phone in)"
    echo "not waking the phone: battery ${lvl}% and not charging"; return 0; fi
  wl_save "$1" || { WL_WHY="the screen is off and its brightness/timeout can't be read to restore later - not woken"
    echo "not waking the phone: can't read its brightness/timeout to restore later"; return 0; }
  # powos-queuewake: this wake is the queue's (idle.sh counts its Awake streak as served - no 120 s wait for a screen
  # the queue itself turned on). Polled, not slept: wm dismiss-keyguard as soon as the screen reports Awake.
  "$1/adb.sh" shell "settings put system screen_brightness_mode 0; settings put system screen_brightness ${WAKE_BRIGHTNESS:-1}; settings put system screen_off_timeout 1800000; date +%s > /data/local/tmp/powos-queuewake; ${SELF_INPUT}input keyevent KEYCODE_WAKEUP; for i in 1 2 3 4 5 6 7 8 9 10; do dumpsys power | grep -q mWakefulness=Awake && break; sleep 0.1; done; wm dismiss-keyguard" >/dev/null 2>&1
  WL_DID=1   # this window woke it (queue.sh's wl_done logs it even after a touch restored the settings early)
  WL_WHY="woke the phone at minimum brightness for the checks (battery ${lvl:-?}%) - waiting for it to report free"
  echo "woke the phone at minimum brightness for the checks (idle ${i}s${lvl:+, battery ${lvl}%})"
}
# wl_say <line>: a wait's reason on stderr (the runner's log: queue.sh sends window_lock's stdout to /dev/null), only when
# it differs from the last one said - a silent wait is a bug (11-12 22:07-23:50: the phone dozing at 10% battery, unplugged,
# wl_wake declined every minute into /dev/null and the runner logged nothing for 1h40 with 9 runnable jobs queued).
wl_say() { [ -n "$1" ] && [ "$1" != "${WL_SAID:-}" ] || return 0; WL_SAID=$1; echo "$(date +%T) $1" >&2; }
# wl_touched <phone dir>: the phone was woken by wl_wake and a real input came since (idle.sh's input reading).
wl_touched() { [ -s "$WL_WOKE" ] || return 1
  local at i; at=$(sed -n 's/^at=//p' "$WL_WOKE"); i=$("$1/idle.sh" 2>/dev/null | sed -n 's/.*idle=\([0-9]*\).*/\1/p')
  [ -n "$i" ] && [ -n "$at" ] && [ "$i" -lt $(( $(date +%s) - at )) ]; }
# wl_restore <phone dir>: the user's brightness, its mode and the screen-off timeout back exactly as saved (mode last:
# auto brightness re-applies on top of the restored level). The save goes only once the restore went through.
wl_restore() { [ -s "$WL_WOKE" ] || return 0
  local b= m= t=; b=$(sed -n 's/^b=//p' "$WL_WOKE"); m=$(sed -n 's/^m=//p' "$WL_WOKE"); t=$(sed -n 's/^t=//p' "$WL_WOKE")
  "$1/adb.sh" shell "settings put system screen_brightness $b; settings put system screen_off_timeout $t; settings put system screen_brightness_mode $m" >/dev/null 2>&1 \
    && rm -f "$WL_WOKE" && echo "restored the phone's brightness $b (mode $m) and screen-off timeout $t"; }
# wl_sleep <phone dir>: after the batch - the settings restored, and the screen back off if still nobody touched it.
wl_sleep() {
  [ -e "$WL_WOKE" ] || return 0
  local i touched=0; wl_touched "$1" && touched=1
  wl_restore "$1"
  i=$("$1/idle.sh" 2>/dev/null | sed -n 's/.*idle=\([0-9]*\).*/\1/p')
  [ $touched = 0 ] && [ -n "$i" ] && [ "$i" -ge "${QUEUE_IDLE_S:-120}" ] && "$1/adb.sh" shell "${SELF_INPUT}input keyevent KEYCODE_SLEEP" >/dev/null 2>&1
  # The save goes only with a restore that went through (wl_restore removes it then): a failed restore keeps it for the
  # next wl_sleep/wl_restore - else the user's brightness/timeout are lost (11-07: the phone left at brightness 1,
  # manual mode, 30 min timeout after the 12:28 window, and the next wake saved those as "the user's").
  [ -e "$WL_WOKE" ] && echo "could not restore the phone's brightness/timeout yet - kept in $WL_WOKE for the next try"
  return 0
}
# wl_release: the verify lock goes, if this window took it. A caller that sets its own EXIT trap after window_lock
# (bash keeps ONE EXIT trap: the new one replaces window_lock's) must call it there - 11-07 12:28: queue.sh's window
# trap (warm_stop/util_rec/wl_done) replaced it, the lock outlived every window and the runner waited on its own lock
# (phone idle, 14 jobs queued, nothing ran for 2 h).
wl_release() { [ -n "${WL_MINE:-}" ] || return 0; rm -rf "${WL_LOCK:-$HOME/.cache/powos-verify.lock}"; WL_MINE=; }
# wl_stale <name>: a verify lock whose owner is gone is removed (its who line ends "(pid N)"): pid N no longer runs, or
# it is THIS process asking for a window under the same name - a window of ours that ended without its release (a
# runner's windows never overlap, so the lock it asks past can only be a leaked one). A who without a pid (an injected
# check's own mkdir lock) is never touched: that check's trap owns it.
wl_stale() {
  local L=${WL_LOCK:-$HOME/.cache/powos-verify.lock} who pid
  [ -d "$L" ] || return 0
  who=$(cat "$L/who" 2>/dev/null) || return 0
  pid=$(sed -n 's/.*(pid \([0-9][0-9]*\))$/\1/p' <<<"$who"); [ -n "$pid" ] || return 0
  if [ "$pid" = "$$" ] && [ "${who%% *}" = "$1" ]; then :
  elif kill -0 "$pid" 2>/dev/null; then return 0; fi
  echo "$1: removing a stale verify lock ($who - its window ended without releasing it)"
  rm -rf "$L"
}
window_lock() {
  local name=$1 need=${2:-120} max=${3:-${WAIT_S:-7200}} phone end s
  [ "${LOCK_HELD:-0}" = 1 ] && return 0
  phone=${WL_PHONE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  end=$(( $(date +%s) + max ))
  WL_LOCK=$HOME/.cache/powos-verify.lock
  while :; do
    local left=$(( end - $(date +%s) ))
    [ $left -gt 0 ] || { echo "$name: no free window in ${max}s"; exit 3; }
    # In WL_CHUNK_S (60 s) chunks (was 3 min until 11-10; the user, 2026-10-23: "the testing ... mostly waiting"; was 10 min / 5-min chunks): between them, a screen that is off with nobody touching it for WAKE_IDLE_S (600; 0 = never) is
    # woken and its keyguard dismissed (no PIN) - the user's ask, 2026-10-23 ("so wake the screen"): checks waited
    # all night for an Awake screen. The touch counters still decide idle, so any finger ends it as before.
    # The wake is tried BEFORE each wait, in WL_CHUNK_S (60) s chunks: it used to come only after a whole 180 s chunk
    # had timed out, so a window that ended with the phone untouched (idle already past WAKE_IDLE_S) paid 180 s of
    # dark screen, then idle.sh's 120 s Awake streak, before the next check (11-10: ~5 min between windows).
    local chunk=$left; [ "${WAKE_IDLE_S:-600}" -gt 0 ] && [ $chunk -gt "${WL_CHUNK_S:-60}" ] && chunk=${WL_CHUNK_S:-60}
    if [ "${WAKE_IDLE_S:-600}" -gt 0 ]; then wl_wake "$phone"; else WL_WHY="waking the phone is off (WAKE_IDLE_S=0) - waiting for the screen on and untouched"; fi
    [ -z "${GO_ONLY:-}" ] && wl_say "$name waits for a free window: $WL_WHY"
    if ! s=$(AWAKE_ONLY=1 "$phone/idle.sh" --wait "$need" "$chunk"); then
      # The user came back to a phone the queue woke: their settings back at once (it's their phone now).
      wl_touched "$phone" && wl_restore "$phone"
      [ $chunk -lt $left ] || { echo "$name: no free window: $s"; exit 3; }
      continue
    fi
    case "$s" in stop*) WL_GOT=$s; echo "$name: stopped from the phone"; exit 6 ;; esac
    wl_stale "$name"
    if mkdir "$WL_LOCK" 2>/dev/null; then
      echo "$name $(date +%T) (pid $$)" > "$WL_LOCK/who"; WL_MINE=1
      trap 'wl_release; '"${WL_TRAP:-:}" EXIT
      WL_GOT=$s
      echo "$s"
      return 0
    fi
    # Someone else's injected check: wait for it to finish (not holding anything), then look for a free window again.
    wl_say "$name: free, but $(cat "$WL_LOCK/who" 2>/dev/null || echo another check) is running - waiting for it"
    while [ -d "$WL_LOCK" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 20
      [ -z "${VERIFY_STATE:-}" ] || "$phone/adb.sh" shell "touch /data/local/tmp/powos-verify-runner" >/dev/null 2>&1; done
  done
}

# Checks never close the user's apps (rule, 2026-10-24). Needs the script's sh_ (adb shell as root).
#   claim_pkg <pkg>: <pkg> must NOT be running at check start (a process or an `am stack` task) - else it may be the
#     user's: print "<pkg> already runs (maybe the user's): not now", exit 3 (the EXIT trap's restore runs; it stops only
#     claimed packages). Not running: recorded as ours in CLAIMED.
#   release_pkgs [pkg...]: force-stop the claimed packages (only those among the args, if given), then remove the recents
#     tasks of theirs that weren't there at the first claim (CLAIM_T0). A force-stop alone leaves the task in recents
#     with no activities - the emulator kept a dead Calculator task (#15) from bar-in-task-probe.sh's FAIL run and the
#     next job, switcher-empty.sh, refused to run beside it (11-11). Tasks that were there before (maybe the user's) and
#     other packages' are never touched.
CLAIMED=""
CLAIM_T0=""
TOUCHED=0
# recent_task_ids [pkg]: the ids of the recents tasks (all, or those whose component or affinity is <pkg>'s).
recent_task_ids() {
  sh_ "dumpsys activity recents" | tr -d '\r' | awk -v p="${1:-}" '
    function out() { if (id != "" && (p == "" || index(h, ":" p "}") || index(h, ":" p " ") || index(c, p "/") == 1)) print id }
    /\* Recent #[0-9]+: Task\{/ { out(); h = $0; c = ""; match($0, / #[0-9]+ /); id = substr($0, RSTART + 2, RLENGTH - 3) }
    /^ *mActivityComponent=/ { c = $0; sub(/^ *mActivityComponent=/, "", c) }
    /Visible recent tasks/ { out(); id = ""; exit }
    END { out() }'
}
claim_pkg() {
  local p=$1
  case " $CLAIMED " in *" $p "*) return 0 ;; esac
  if [ -n "$(sh_ "pidof $p")" ] || [ -n "$(sh_ "am stack list" | grep -F "$p")" ]; then
    echo "$p already runs (maybe the user's): not now"; exit 3
  fi
  [ -n "$CLAIMED" ] || CLAIM_T0=" $(recent_task_ids | tr '\n' ' ')"
  CLAIMED="$CLAIMED $p"; TOUCHED=1
}
# claim_pkgs <pkg>...: all of them or none - every <pkg> is checked first (not running), and only then recorded as ours; a
#   running one exits 3 ("not now") before any claim, so TOUCHED stays 0 and the restore does nothing.
claim_pkgs() {
  local p
  for p in "$@"; do
    case " $CLAIMED " in *" $p "*) continue ;; esac
    if [ -n "$(sh_ "pidof $p")" ] || [ -n "$(sh_ "am stack list" | grep -F "$p")" ]; then
      echo "$p already runs (maybe the user's): not now"; exit 3
    fi
  done
  for p in "$@"; do claim_pkg "$p"; done
}
release_pkgs() {
  local p w t
  for p in $CLAIMED; do
    if [ $# -gt 0 ]; then w=0; for a in "$@"; do [ "$a" = "$p" ] && w=1; done; [ $w = 1 ] || continue; fi
    sh_ "am force-stop $p"
    for t in $(recent_task_ids "$p"); do
      case "$CLAIM_T0" in *" $t "*) ;; *) sh_ "am stack remove $t" >/dev/null ;; esac
    done
  done
}
