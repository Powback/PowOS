# tools/phone/verify/kwin-up.sh (sourced by the Linux window checks): the checks' KWin is the newest built one, and
# the running KWin is a process of it - a check of a fix on an older or stale KWin proves nothing (linux-touch.sh ran
# on 3.25 while named "kwin 3.26", 2026-10-23).
#   . "$here/kwin-up.sh"   (needs $T = tools/phone, $OUT; the caller's log/fail if defined)
#   kwin_install MIN        the newest built kwin pkg (KWIN_PKG, else targets/android/out/pkgs/kwin-* here, in a
#                           sibling worktree, or in the shared build-inputs cache - a build-pkgs.sh kwin build
#                           lands there too, friction f87/f116: a worktree kept alive only to hold a built
#                           package can be removed once it has) installed if newer than the installed one
#                           (rollback tar of the old files in /var/cache/powos); then FAIL if the installed one
#                           is older than MIN. KWIN_HAD = the version before.
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
  pkg=${KWIN_PKG:-$(ls -t "$KWIN_ROOT"/targets/android/out/pkgs/kwin-*.pkg.tar.xz "$KWIN_ROOT"/../*/targets/android/out/pkgs/kwin-*.pkg.tar.xz \
    "${POWOS_BUILD_INPUTS_CACHE:-$HOME/.cache/powos-build-inputs}"/pkgs/kwin-*.pkg.tar.xz 2>/dev/null | head -1)}
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
  # Reports each of the 4 stages as it's reached (f91: a bare "KWin didn't come back" hid that stage 1 (the request
  # never reached the app) was the real failure) - callers' FAIL then carries the stage, not just the symptom.
  local st0 k0 st k s0 s1 req seen gone=0
  st0=$(kwin_state); k0=${st0#kwin=}; k0=${k0%% *}
  s0=$(_kw_sh "grep -c -- \"^--- \" /data/powos/session.log")
  _kw_us "android-request power logout"
  req=$(_kw_sh "cat /data/user/0/com.powos.app/files/run/android-request")
  _kw_log "stage 1/4 request written: android-request power logout (file now holds '$req'); before: $st0, session starts so far: $s0"
  for _ in $(seq 10); do
    [ -n "$k0" ] && [ "$k0" != - ] && _kw_sh "[ -d /proc/$k0 ] && echo y" | grep -q y || { gone=1; break; }
    sleep 2
  done
  [ "$gone" = 1 ] && seen="yes - old kwin_wayland (pid ${k0:-none}) is gone" || seen="UNKNOWN - old kwin_wayland (pid ${k0:-none}) is still mapped after 20 s"
  _kw_log "stage 2/4 app saw it: $seen"
  for _ in $(seq 24); do
    st=$(kwin_state); k=${st#kwin=}; k=${k%% *}
    if [[ $st == *kwin_new=1* ]] && [ "$k" != "$k0" ] && [ "$k" != - ]; then
      s1=$(_kw_sh "grep -c -- \"^--- \" /data/powos/session.log")
      _kw_log "stage 3/4 session restarted: yes (session.log starts $s0 -> $s1)"
      _kw_log "stage 4/4 KWin new pid: $st"
      return 0
    fi
    sleep 5
  done
  s1=$(_kw_sh "grep -c -- \"^--- \" /data/powos/session.log")
  if [ "${s1:-0}" = "${s0:-0}" ]; then
    _kw_log "stage 3/4 session restarted: no (session.log: $s0 starts before and after)"
    KWIN_WHY="the logout request never reached the app, or it never acted on it - stage 2 ($seen), stage 3 no new session (session.log stuck at $s0 starts; request file: '$req')"
  else
    _kw_log "stage 3/4 session restarted: yes (session.log starts $s0 -> $s1)"
    _kw_log "stage 4/4 KWin new pid: NO ($st, was kwin=$k0)"
    KWIN_WHY="stage 4 failed - a new session started ($s0 -> $s1) but no new KWin of the installed package runs ($st, was kwin=$k0)"
  fi
  return 1
}

kwin_up() {
  kwin_install "$1"
  local st; st=$(kwin_state)
  if [[ $st == *kwin_new=1* ]]; then _kw_log "running KWin is the installed $(kwin_installed): $st"; return 0; fi
  kwin_restart || _kw_fail "KWin didn't come back as a new process on the installed package: $KWIN_WHY (rollback: tar -xf /var/cache/powos/kwin-$KWIN_HAD-files.tar -C /)"
}
