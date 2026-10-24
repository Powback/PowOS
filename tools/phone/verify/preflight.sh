#!/bin/bash
# preflight.sh <check-cmd...>: is the phone's ENVIRONMENT able to run this check? 0 = yes; else prints
# "ENV: <reason>" and exits 5 (queue.sh: "can't run", not a FAIL). Under 3 s, one adb call.
# A check declares what it needs in a header line (first 20 lines of the script):
#   # needs: kwin ship:apps ship:shell py:numpy macpy:numpy
#   kwin         the PowOS session's kwin_wayland is running (checks that drive Linux windows)
#   ship:KIND    the build on the phone is not older than origin's tip for the paths of KIND: apps (apps/, marker
#                apps-live), shell (shell/, marker live); a pending ship -> "waiting for ship of KIND"
#   py:MOD       python3 in the PowOS root imports MOD;  macpy:MOD  the Mac's python3 does
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P); phone=$(cd "$here/.." && pwd -P)
Q=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}
env_fail() { echo "ENV: $*"; exit 5; }

# needs_of <cmd...>: the declared needs of the first script among the args.
needs_of() { local a
  for a in "$@"; do [ -f "$a" ] || continue
    sed -n '1,20s/^# needs:[[:space:]]*//p' "$a" | tr '\n' ' '; return; done; }

# ship_pending KIND: prints the reason when KIND's shipped build lags origin's tip for its paths.
ship_pending() { local kind=$1 mark path base tip
  case "$kind" in apps) mark=apps-live path=apps ;; shell) mark=live path=shell ;; *) return ;; esac
  base=$(cat "$Q/$mark" 2>/dev/null) || return 0          # no record: can't judge, don't block
  tip=$(git rev-parse -q --verify "origin/${PREFLIGHT_BASE:-worktree-powos-multiplatform}" 2>/dev/null) || return 0
  [ "$base" = "$tip" ] && return 0
  git cat-file -e "$base^{commit}" 2>/dev/null || return 0
  git diff --quiet "$base" "$tip" -- ":(top)$path" 2>/dev/null || echo "waiting for ship of $kind (live ${base:0:9}, origin ${tip:0:9})"; }

# phone_probe: one adb call -> "kwin=<0|1>" and "py:<mod>=<0|1>" lines.
phone_probe() { local mods=("$@") m cmd
  cmd='pgrep -x kwin_wayland >/dev/null && echo kwin=1 || echo kwin=0;'
  for m in ${mods[@]+"${mods[@]}"}; do
    cmd+=" chroot /data/powos/root /usr/bin/env python3 -c 'import $m' >/dev/null 2>&1 && echo py:$m=1 || echo py:$m=0;"; done
  perl -e 'alarm shift; exec @ARGV' 12 "$phone/adb.sh" shell "su -c \"$cmd\"" 2>/dev/null | tr -d '\r'; }

main() { local needs t mods=() out rc=0 w
  [ "${POWOS_PREFLIGHT:-1}" = 0 ] && exit 0
  needs=$(needs_of "$@"); [ -n "$needs" ] || exit 0
  for t in $needs; do
    case "$t" in
      ship:*) w=$(ship_pending "${t#ship:}"); [ -z "$w" ] || env_fail "$w" ;;
      macpy:*) python3 -c "import ${t#macpy:}" 2>/dev/null || env_fail "python module '${t#macpy:}' missing on the Mac" ;;
      py:*) mods+=("${t#py:}") ;;
    esac
  done
  case " $needs " in *" kwin "*|*" py:"*) ;; *) exit 0 ;; esac
  out=$(phone_probe ${mods[@]+"${mods[@]}"}) || rc=$?
  [ -n "$out" ] || env_fail "phone unreachable over adb (rc $rc) - the VPN or adb server is down"
  case " $needs " in *" kwin "*) echo "$out" | grep -q '^kwin=1' || env_fail "no kwin_wayland running - the PowOS session is down or stale" ;; esac
  for t in ${mods[@]+"${mods[@]}"}; do
    echo "$out" | grep -q "^py:$t=1" || env_fail "python module '$t' missing in the PowOS root"; done
  exit 0; }
main "$@"
