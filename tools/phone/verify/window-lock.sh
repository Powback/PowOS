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
# wl_wake <phone dir>: wake the screen and dismiss the keyguard when it's off and nobody touched it for WAKE_IDLE_S;
# marks ~/.cache/powos-verify-woke so the runner puts it back to sleep after (queue.sh, wl_sleep).
wl_wake() {
  local st i; st=$("$1/idle.sh" 2>/dev/null); i=$(sed -n 's/.*idle=\([0-9]*\).*/\1/p' <<<"$st")
  case "$st" in *screen=Awake*) return 0 ;; esac
  [ -n "$i" ] && [ "$i" -ge "${WAKE_IDLE_S:-600}" ] || return 0
  "$1/adb.sh" shell 'input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard' >/dev/null 2>&1 && touch "$HOME/.cache/powos-verify-woke"
  echo "woke the screen for the checks (idle ${i}s)"
}
# wl_sleep <phone dir>: the screen back off if wl_wake woke it and still nobody touched it.
wl_sleep() {
  [ -e "$HOME/.cache/powos-verify-woke" ] || return 0
  local i; i=$("$1/idle.sh" 2>/dev/null | sed -n 's/.*idle=\([0-9]*\).*/\1/p')
  [ -n "$i" ] && [ "$i" -ge "${QUEUE_IDLE_S:-120}" ] && "$1/adb.sh" shell 'input keyevent KEYCODE_SLEEP' >/dev/null 2>&1
  rm -f "$HOME/.cache/powos-verify-woke"
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
    # In 5-min chunks: between them, a screen that is off with nobody touching it for WAKE_IDLE_S (600; 0 = never) is
    # woken and its keyguard dismissed (no PIN) - the user's ask, 2026-10-23 ("so wake the screen"): checks waited
    # all night for an Awake screen. The touch counters still decide idle, so any finger ends it as before.
    local chunk=$left; [ "${WAKE_IDLE_S:-600}" -gt 0 ] && [ $chunk -gt 300 ] && chunk=300
    if ! s=$(AWAKE_ONLY=1 "$phone/idle.sh" --wait "$need" "$chunk"); then
      [ $chunk -lt $left ] || { echo "$name: no free window: $s"; exit 3; }
      wl_wake "$phone"; continue
    fi
    case "$s" in stop*) WL_GOT=$s; echo "$name: stopped from the phone"; exit 6 ;; esac
    if mkdir "$WL_LOCK" 2>/dev/null; then
      echo "$name $(date +%T) (pid $$)" > "$WL_LOCK/who"
      trap 'rm -rf "$WL_LOCK"; '"${WL_TRAP:-:}" EXIT
      WL_GOT=$s
      echo "$s"
      return 0
    fi
    # Someone else's injected check: wait for it to finish (not holding anything), then look for a free window again.
    echo "$name: free, but $(cat "$WL_LOCK/who" 2>/dev/null || echo another check) is running - waiting for it"
    while [ -d "$WL_LOCK" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 20
      [ -z "${VERIFY_STATE:-}" ] || "$phone/adb.sh" shell "touch /data/local/tmp/powos-verify-runner" >/dev/null 2>&1; done
  done
}
