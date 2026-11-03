#!/bin/bash
# lanes: phone
# xwayland-install.sh MIN [OUT]: installs the newest built xwayland-kgsl package (here, a sibling worktree, or the shared
# build-inputs cache - kwin-install.sh's lookup) if it's newer than the installed one, restarts the session if the
# running Xwayland is a deleted (older) binary, and FAILs if the installed package ends up older than MIN.
# kwin-install.sh's twin for /usr/local/bin/Xwayland. PASS = the installed package's Xwayland runs and serves the
# session: an Xwayland pid whose /proc/<pid>/exe IS the package's file (not a deleted one) and an X client works on
# DISPLAY (xwininfo -root - KWin starts Xwayland lazily on the first X11 client, so the check starts that trivial
# client itself; never Steam or a game). NOT a new KWin: since the reattach work KWin outlives the session restart
# (11-03: kwin-install's "new KWin pid" test FAILed a good install, session 759 -> 760 with kwin=31069 kept), and
# so does its Xwayland - after the restart an old Xwayland still running gets SIGTERM, and KWin's Xwayland restart
# policy re-listens on the socket so the next client starts the installed binary. Queue it
# first against the board task, then the check that needs the new Xwayland:
#   queue.sh add <task> tools/phone/verify/xwayland-install.sh 24.1.13-4
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=${XW_TOOLS:-$here/..}   # XW_TOOLS: a stub tools/phone (test-xwayland-install.sh)
OUT=${2:-$HOME/.cache/powos-verify/xwayland-install-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
[ $# -ge 1 ] || { echo "usage: xwayland-install.sh MIN [OUT]"; exit 2; }
restore() { "$T/adb.sh" shell "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null" >/dev/null 2>&1; echo "restored"; }
. "$here/window-lock.sh"
. "$here/kwin-up.sh"   # _kw_rs/_kw_sh/_kw_us, KWIN_ROOT
window_lock xwayland-install.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$HOME/.cache/powos-verify.lock"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
log() { echo "$*"; }
min=$1
xw_installed() { _kw_rs 'pacman -Q xwayland-kgsl 2>/dev/null | cut -d" " -f2' | tail -1; }
# "xwayland=<pid|-> xwayland_new=<0|1> exe=<its /proc exe> pkgfile=<the package's Xwayland>" (new=1: it runs the
# installed package's file; a replaced binary reads "<path> (deleted)" and is 0)
xw_state() { _kw_rs 'f=$(pacman -Qlq xwayland-kgsl 2>/dev/null | grep "/bin/Xwayland$" | head -1); x=$(pgrep -x Xwayland | head -1); e=-; n=0
[ -n "$x" ] && e=$(readlink "/proc/$x/exe" | tr " " _)
[ -n "$x" ] && [ -n "$f" ] && [ "$e" = "$f" ] && n=1
echo "xwayland=${x:--} xwayland_new=$n exe=$e pkgfile=${f:--}"' | tail -1; }
xw_pid() { local p=${1#xwayland=}; echo "${p%% *}"; }
# "display=ok <root geometry>" or "display=fail <why>": a trivial X client on DISPLAY as the session user (its first
# connection is what makes KWin start Xwayland; XAUTHORITY is that Xwayland's -auth, so it retries once it's up)
xw_poke() { _kw_us 'export DISPLAY=${DISPLAY:-:0}; r="no X client ran"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  x=$(pgrep -x Xwayland | head -1)
  if [ -n "$x" ]; then a=$(tr "\0" "\n" < "/proc/$x/cmdline" | grep -A1 -x -- -auth | tail -1); [ -n "$a" ] && export XAUTHORITY=$a; fi
  r=$(timeout 10 xwininfo -root 2>&1)
  if grep -q "Width:" <<<"$r"; then echo "display=ok $(grep -E "Width:|Height:" <<<"$r" | tr -s " " | tr "\n" " ")"; exit 0; fi
  sleep 2
done
echo "display=fail $(tail -2 <<<"$r" | tr "\n" " ")"' | tail -1; }
# A fresh session, then the old Xwayland gone: the logout request (kwin_restart's stage 1), the session restart seen in
# /data/powos/session.log, and - KWin outliving the session, so its Xwayland too - SIGTERM to the old Xwayland pid.
xw_restart() {
  local old=$1 s0 s1 gone=0
  s0=$(_kw_sh "grep -c -- \"^--- \" /data/powos/session.log")
  _kw_us "android-request power logout"
  log "stage 1/3 request written: android-request power logout (session starts so far: ${s0:-?})"
  for _ in $(seq 24); do
    s1=$(_kw_sh "grep -c -- \"^--- \" /data/powos/session.log")
    [ "${s1:-0}" != "${s0:-0}" ] && break
    sleep 5
  done
  [ "${s1:-0}" != "${s0:-0}" ] && log "stage 2/3 session restarted: yes ($s0 -> $s1)" \
    || log "stage 2/3 session restarted: no (session.log stuck at $s0 starts) - replacing Xwayland under the running KWin"
  for _ in $(seq 5); do _kw_sh "[ -d /proc/$old ] && echo y" | grep -q y || { gone=1; break; }; sleep 2; done
  if [ $gone = 0 ]; then
    log "stage 3/3 the old Xwayland (pid $old) outlived the session (KWin kept running): SIGTERM - KWin re-listens on the socket"
    _kw_sh "kill $old"
    for _ in $(seq 10); do _kw_sh "[ -d /proc/$old ] && echo y" | grep -q y || { gone=1; break; }; sleep 1; done
    [ $gone = 1 ] || { XW_WHY="the old Xwayland (pid $old) is still running 10 s after SIGTERM"; return 1; }
  else log "stage 3/3 the old Xwayland (pid $old) is gone with the session"; fi
}

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
rb="(rollback: tar -xf /var/cache/powos/xwayland-kgsl-${had:-none}-files.tar -C /)"
st=$(xw_state); old=$(xw_pid "$st")
log "running Xwayland: $st"
if [ "$old" != - ] && [[ $st != *xwayland_new=1* ]]; then
  log "running Xwayland is not the installed $xv binary: restarting the session"
  xw_restart "$old" || fail "Xwayland wasn't replaced: $XW_WHY $rb"
else old=; fi
d=$(xw_poke); st=$(xw_state); x=$(xw_pid "$st")
log "X client on the display: $d; Xwayland now: $st"
[[ $d == display=ok* ]] || fail "no X client works on the display after the install ($d; Xwayland: $st) $rb"
[ "$x" != - ] && [[ $st == *xwayland_new=1* ]] || fail "the Xwayland serving the display isn't the installed $xv binary ($st) $rb"
[ -n "$old" ] && [ "$x" = "$old" ] && fail "Xwayland is still the old pid $old ($st) $rb"
echo "PASS: xwayland-kgsl $xv installed, its Xwayland serves the session ($st; $d)"
