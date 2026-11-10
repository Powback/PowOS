#!/bin/bash
# lanes: phone
# Dedicated installed companion only. Never opens/removes/stops Termux or any user app.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
. "$here/window-lock.sh"
window_lock switcher-owned-bg 120
pkg=com.powos.verifybackground
nonce=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
sh_() { "$T/adb.sh" shell "$*" | tr -d '\r'; }
state() { sh_ "run-as $pkg cat files/run" 2>/dev/null || true; }
started_at=$(date +%s)
owned_pid=
cleanup() {
  local current
  current=$(state)
  # No package-only ownership: require our nonce and the PID that acknowledged this launch.
  if [ -n "$owned_pid" ] && [[ "$current" == "$nonce $owned_pid "* ]] && [ "$(sh_ "pidof $pkg")" = "$owned_pid" ]; then
    sh_ "am force-stop $pkg" >/dev/null
  fi
  [ "${LOCK_HELD:-0}" = 1 ] || rmdir "$HOME/.cache/powos-verify.lock" 2>/dev/null || true
}
trap cleanup EXIT
[ -n "$(sh_ "pm path $pkg")" ] || { echo 'SKIP: coordinator must install the registered background verification companion'; exit 5; }
[ -z "$(sh_ "pidof $pkg")" ] || { echo 'SKIP: companion already running; not adopted'; exit 5; }
tasks_snapshot() { sh_ 'dumpsys activity recents' | grep 'Recent #[0-9].*Task{' | grep -v "$pkg" | sed -E 's/^.*Task\{[^ ]+ #([0-9]+) .*$/\1/' | sort -n; }
tasks_before=$(tasks_snapshot)
termux_before=$(sh_ 'pidof com.termux' || true)
sh_ "am start -W -n $pkg/.StartActivity --es nonce $nonce"
for _ in $(seq 1 10); do
  current=$(state)
  if [[ "$current" == "$nonce "* ]]; then read -r _ owned_pid deadline ticks <<<"$current"; break; fi
  sleep 1
done
[ -n "$owned_pid" ] || { echo 'FAIL: companion did not acknowledge owned nonce'; exit 1; }
[ "$(sh_ "pidof $pkg")" = "$owned_pid" ] || { echo 'FAIL: companion PID differs from acknowledgment'; exit 1; }
# Two distinct heartbeats prove real running work, not an injected list row.
sleep 2
read -r n p d next_ticks <<<"$(state)"
[ "$n $p" = "$nonce $owned_pid" ] && [ "$next_ticks" -gt "$ticks" ] || { echo 'FAIL: owned workload heartbeat did not advance'; exit 1; }
# Leave enough of the 90-second lease that expiry cannot masquerade as Stop success.
[ $(( $(date +%s) - started_at )) -lt 45 ] || { echo 'SKIP: setup used too much of fixture lease'; exit 5; }
sh_ 'input keyevent KEYCODE_APP_SWITCH'; sleep 2
SHELL_CHECK_LIB=1 . "$here/shell-check.sh"
r=$(shell_check home device-checks.js switcherOwnedBackgroundNow 'PowOS Background Check')
echo "switcher-owned-bg: $r"
[ "$r" = '[]' ] || { echo "FAIL: $r"; exit 1; }
for _ in $(seq 1 10); do [ -z "$(sh_ "pidof $pkg")" ] && break; sleep 1; done
[ -z "$(sh_ "pidof $pkg")" ] || { echo 'FAIL: Stop did not end owned workload'; exit 1; }
[ "$(sh_ 'pidof com.termux' || true)" = "$termux_before" ] || { echo 'FAIL: Termux process identity changed during check'; exit 1; }
[ $(( $(date +%s) - started_at )) -lt 85 ] || { echo 'FAIL: cannot distinguish Stop from lease expiry'; exit 1; }
[ "$(tasks_snapshot)" = "$tasks_before" ] || { echo 'FAIL: pre-existing task identities changed'; exit 1; }
echo 'PASS: real owned background workload listed, optimistic Stop, host disappearance and process exit; Termux unchanged'
