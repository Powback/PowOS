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
window_lock() {
  local name=$1 need=${2:-120} max=${3:-${WAIT_S:-7200}} phone end s
  [ "${LOCK_HELD:-0}" = 1 ] && return 0
  phone=${WL_PHONE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  end=$(( $(date +%s) + max ))
  WL_LOCK=$HOME/.cache/powos-verify.lock
  while :; do
    local left=$(( end - $(date +%s) ))
    [ $left -gt 0 ] || { echo "$name: no free window in ${max}s"; exit 3; }
    s=$(AWAKE_ONLY=1 "$phone/idle.sh" --wait "$need" "$left") || { echo "$name: no free window: $s"; exit 3; }
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
