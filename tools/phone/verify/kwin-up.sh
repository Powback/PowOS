# tools/phone/verify/kwin-up.sh (sourced by the Linux window checks): the checks' KWin is the newest built one, and
# the running KWin is a process of it - a check of a fix on an older or stale KWin proves nothing (linux-touch.sh ran
# on 3.25 while named "kwin 3.26", 2026-10-23).
#   . "$here/kwin-up.sh"   (needs $T = tools/phone, $OUT; the caller's log/fail if defined)
#   kwin_install MIN        the newest built kwin pkg (KWIN_PKG, else targets/android/out/pkgs/kwin-* here or in a
#                           sibling worktree) installed if newer than the installed one (rollback tar of the old files in
#                           /var/cache/powos); then FAIL if the installed one is older than MIN. KWIN_HAD = the version before.
#   kwin_restart            a fresh session (`android-request power logout`): returns 0 once a NEW kwin_wayland of the
#                           installed package runs (no deleted libkwin mapped); 1 with the reason in KWIN_WHY (whether the
#                           app took the request, whether a new session started - /data/powos/session.log).
#   kwin_up MIN             both: install, and restart only if the running KWin is stale (older package or old files).
#   kwin_state              "kwin=<pid|-> kwin_new=<0|1>" (1: its libkwin is the installed file, not a deleted one).
KWIN_ROOT=$(cd "$T/../.." && pwd)
_kw_sh() { "$T/adb.sh" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
_kw_rs() { printf '%s\n' "$1" > "$OUT/kw-r.sh"; "$T/root.sh" "$OUT/kw-r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
_kw_us() { printf '%s\n' "$1" > "$OUT/kw-u.sh"; "$T/user.sh" "$OUT/kw-u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
_kw_log() { if declare -F log >/dev/null; then log "$*"; else echo "$*"; fi; }
_kw_fail() { if declare -F fail >/dev/null; then fail "$*"; else echo "FAIL: $*"; fi; exit 1; }  # some callers' fail goes on
kwin_state() { _kw_rs 'k=$(pgrep -x kwin_wayland | head -1); n=0; [ -n "$k" ] && ! grep -q "libkwin.*(deleted)" /proc/$k/maps && n=1; echo "kwin=${k:--} kwin_new=$n"' | tail -1; }
kwin_installed() { _kw_rs 'pacman -Q kwin | cut -d" " -f2' | tail -1; }

kwin_install() {
  local min=$1 pkg want
  pkg=${KWIN_PKG:-$(ls -t "$KWIN_ROOT"/targets/android/out/pkgs/kwin-*.pkg.tar.xz "$KWIN_ROOT"/../*/targets/android/out/pkgs/kwin-*.pkg.tar.xz 2>/dev/null | head -1)}
  want=$(basename "${pkg:-none}" | sed -E 's/^kwin-([^-]+-[^-]+)-.*/\1/')
  KWIN_HAD=$(kwin_installed)
  _kw_log "kwin installed $KWIN_HAD, newest package $want (${pkg:-none})"
  if [ -n "${pkg:-}" ] && [ "$KWIN_HAD" != "$want" ] && [ "$(_kw_rs "vercmp '$want' '$KWIN_HAD'" | tail -1)" -gt 0 ] 2>/dev/null; then
    "$T/adb.sh" push "$pkg" /data/local/tmp/powos-kwin.pkg.tar.xz >/dev/null
    _kw_sh "mv /data/local/tmp/powos-kwin.pkg.tar.xz /data/powos/root/var/tmp/"
    _kw_rs "set -e; mkdir -p /var/cache/powos
pacman -Qlq kwin | while read -r f; do [ -f \"\$f\" ] && echo \"\$f\"; done | tar -cf /var/cache/powos/kwin-$KWIN_HAD-files.tar -T -
pacman -U --noconfirm /var/tmp/powos-kwin.pkg.tar.xz >/dev/null && rm -f /var/tmp/powos-kwin.pkg.tar.xz
pacman -Q kwin" | tail -1 | while read -r l; do _kw_log "installed: $l"; done
  fi
  local kv; kv=$(kwin_installed)
  [ "$(_kw_rs "vercmp '$kv' '$min'" | tail -1)" -ge 0 ] 2>/dev/null || _kw_fail "the installed KWin $kv is older than $min"
}

kwin_restart() {
  local st0 k0 st k s0 s1 req
  st0=$(kwin_state); k0=${st0#kwin=}; k0=${k0%% *}
  s0=$(_kw_sh "grep -c -- \"^--- \" /data/powos/session.log")
  _kw_log "fresh session (android-request power logout); before: $st0"
  _kw_us "android-request power logout"; sleep 20
  for _ in $(seq 30); do
    st=$(kwin_state); k=${st#kwin=}; k=${k%% *}
    [[ $st == *kwin_new=1* ]] && [ "$k" != "$k0" ] && [ "$k" != - ] && { _kw_log "after the restart: $st"; return 0; }
    sleep 5
  done
  s1=$(_kw_sh "grep -c -- \"^--- \" /data/powos/session.log")
  req=$(_kw_sh "cat /data/user/0/com.powos.app/files/run/android-request")
  if [ "${s1:-0}" = "${s0:-0}" ]; then
    KWIN_WHY="no new session started (session.log: $s0 starts before and after; the request file says '$req') - the app didn't act on the logout request"
  else
    KWIN_WHY="a new session started but no new KWin of the installed package runs ($st, was kwin=$k0)"
  fi
  _kw_log "after the restart: $st - $KWIN_WHY"
  return 1
}

kwin_up() {
  kwin_install "$1"
  local st; st=$(kwin_state)
  if [[ $st == *kwin_new=1* ]]; then _kw_log "running KWin is the installed $(kwin_installed): $st"; return 0; fi
  kwin_restart || _kw_fail "KWin didn't come back as a new process on the installed package: $KWIN_WHY (rollback: tar -xf /var/cache/powos/kwin-$KWIN_HAD-files.tar -C /)"
}
