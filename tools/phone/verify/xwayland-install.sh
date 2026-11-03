#!/bin/bash
# lanes: phone
# xwayland-install.sh MIN [OUT]: installs the newest built xwayland-kgsl package (here, a sibling worktree, or the shared
# build-inputs cache - kwin-install.sh's lookup) if it's newer than the installed one, restarts the session if the
# running Xwayland is a deleted (older) binary, and FAILs if the installed package ends up older than MIN.
# kwin-install.sh's twin for /usr/local/bin/Xwayland (KWin starts it, so a fresh session runs the new one). Queue it
# first against the board task, then the check that needs the new Xwayland:
#   queue.sh add <task> tools/phone/verify/xwayland-install.sh 24.1.13-4
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
OUT=${2:-$HOME/.cache/powos-verify/xwayland-install-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
[ $# -ge 1 ] || { echo "usage: xwayland-install.sh MIN [OUT]"; exit 2; }
restore() { "$T/adb.sh" shell "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null" >/dev/null 2>&1; echo "restored"; }
. "$here/window-lock.sh"
. "$here/kwin-up.sh"   # _kw_rs/_kw_sh, kwin_restart (a fresh session = a fresh Xwayland)
window_lock xwayland-install.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$HOME/.cache/powos-verify.lock"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
log() { echo "$*"; }
min=$1
xw_installed() { _kw_rs 'pacman -Q xwayland-kgsl 2>/dev/null | cut -d" " -f2' | tail -1; }
# "xwayland=<pid|-> xwayland_stale=<0|1>" (1: its binary was replaced under it)
xw_state() { _kw_rs 'x=$(pgrep -x Xwayland | head -1); s=0; [ -n "$x" ] && readlink /proc/$x/exe | grep -q "(deleted)" && s=1; echo "xwayland=${x:--} xwayland_stale=$s"' | tail -1; }

pkg=${XWAYLAND_PKG:-$(ls -t "$KWIN_ROOT"/targets/android/out/pkgs/xwayland-kgsl-*.pkg.tar.xz \
  "$KWIN_ROOT"/../*/targets/android/out/pkgs/xwayland-kgsl-*.pkg.tar.xz \
  "${POWOS_BUILD_INPUTS_CACHE:-$HOME/.cache/powos-build-inputs}"/pkgs/xwayland-kgsl-*.pkg.tar.xz 2>/dev/null | head -1)}
want=$(basename "${pkg:-none}" | sed -E 's/^xwayland-kgsl-([^-]+-[^-]+)-.*/\1/')
had=$(xw_installed)
log "xwayland-kgsl installed ${had:-none}, newest package $want (${pkg:-none})"
if [ -n "${pkg:-}" ] && [ "$had" != "$want" ] && [ "$(_kw_rs "vercmp '$want' '${had:-0}'" | tail -1)" -gt 0 ] 2>/dev/null; then
  "$T/adb.sh" push "$pkg" /data/local/tmp/powos-xwayland.pkg.tar.xz >/dev/null
  _kw_sh "mv /data/local/tmp/powos-xwayland.pkg.tar.xz /data/powos/root/var/tmp/"
  _kw_rs "set -e; mkdir -p /var/cache/powos
pacman -Qlq xwayland-kgsl 2>/dev/null | while read -r f; do [ -f \"\$f\" ] && echo \"\$f\"; done | tar -cf /var/cache/powos/xwayland-kgsl-${had:-none}-files.tar -T -
pacman -U --noconfirm /var/tmp/powos-xwayland.pkg.tar.xz >/dev/null && rm -f /var/tmp/powos-xwayland.pkg.tar.xz
pacman -Q xwayland-kgsl" | tail -1 | while read -r l; do log "installed: $l"; done
fi
xv=$(xw_installed)
[ "$(_kw_rs "vercmp '$xv' '$min'" | tail -1)" -ge 0 ] 2>/dev/null || fail "the installed xwayland-kgsl $xv is older than $min"
st=$(xw_state)
if [[ $st == *xwayland_stale=1* ]]; then
  log "running Xwayland is the replaced binary ($st): restarting the session"
  kwin_restart || fail "the session didn't come back: $KWIN_WHY (rollback: tar -xf /var/cache/powos/xwayland-kgsl-${had:-none}-files.tar -C /)"
  st=$(xw_state)
  [[ $st == *xwayland_stale=1* ]] && fail "Xwayland still runs the replaced binary after the restart ($st)"
fi
echo "PASS: xwayland-kgsl $xv installed, running Xwayland current ($st)"
