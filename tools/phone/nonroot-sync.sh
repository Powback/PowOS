#!/bin/bash
# tools/phone/nonroot-sync.sh: keep every registered non-root PowOS phone (tools/phone/devices.conf) as current as the
# main phone - the ship service runs it (tools/phone/ship.sh nonroot_kick), nothing else needs to.
#   nonroot-sync.sh            one pass over every device
#   nonroot-sync.sh --if-due   the service's call: at most every NONROOT_EVERY_S (60) s unless what's live moved
#   nonroot-sync.sh --dry-run  what a pass would do, per device (reads the device, changes nothing)
# Why (2026-11-09, the user on the razr fold): "the launcher seems way outdated ... Do we have everything latest" - the
# ship service shipped only to the main (rooted) phone; the razr kept the UI bundled in its last manual APK install.
#
# Per device, LAN/VPN only, through the Mac's adb (wireless debugging; its port changes, so the address comes from
# `adb mdns services` by the name prefix in devices.conf every pass):
#   1. APK: the last APK the service installed on the main phone (ship-apk.sh keeps a copy: <queue>/nonroot/powos.apk
#      + .commit) goes on when the device's own is older (its assets/shell/shell-build.txt commit). Only with the
#      screen off, or with the user's ~/.config/powos/ship-no-idle-wait on (as ship-apk's --now): an install restarts
#      the launcher. Never a downgrade, never an uninstall (a signature mismatch is logged, nothing else).
#   2. Shell: the shell files that differ between what the device serves (its APK's shell, or the tip last pushed to
#      it) and what's live on the main phone (<queue>/live), pushed with shell/push.sh into the app's files/shell -
#      the same override layer and hot reload the main phone has. Without root: the APK is debuggable, so push.sh's
#      `run-as com.powos.app` writes the app's own files (the supported non-root path; no su anywhere). The files
#      come from `git archive` of the live tip, so a push is exactly what the main phone runs. Not gated again: the
#      main phone's ship gated that tip (the same shell; the device's APK is the same or one install behind).
#      A changed APK (installed here or by hand) first resets the overrides (push.sh --reset), as ship-apk does: an
#      older override must never win over a newer APK's file.
# State: <queue>/nonroot/<name>/{apk-stamp,live}, the log <queue>/nonroot/log, one line per change in shipped.log.
# Tests: test/tier1/test-nonroot-sync.sh (NONROOT_ADB, NONROOT_CONF, NONROOT_REPO, SHIP_DIR, NONROOT_SCREEN override).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
Q=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}
NR=$Q/nonroot; mkdir -p "$NR"
CONF=${NONROOT_CONF:-$here/devices.conf}
REPO=${NONROOT_REPO:-$(cd "$here/../.." && pwd -P)}
ADB=${NONROOT_ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
[ -x "$ADB" ] || ADB=$(command -v adb || true)
PKG=com.powos.app
log() { echo "$(date '+%F %T') $*" >> "$NR/log"; }
note() { log "$*"; echo "$(date '+%F %T') nonroot $*" >> "$Q/shipped.log"; }
g() { git -C "$REPO" "$@"; }
[ -s "$CONF" ] || exit 0
[ -n "$ADB" ] || { log "no adb"; exit 0; }

dry=; [ "${1:-}" = --dry-run ] && dry=1   # --now (or nothing): a pass now
if [ "${1:-}" = --if-due ]; then
  live=$(cat "$Q/live" 2>/dev/null || true)
  { read -r lt ll < "$NR/last"; } 2>/dev/null || { lt=0; ll=; }
  [ "$ll" != "$live" ] || [ $(( $(date +%s) - ${lt:-0} )) -ge "${NONROOT_EVERY_S:-60}" ] || exit 0
fi
# One pass at a time (the runner kicks it from its loop).
L=$NR/lock
if ! mkdir "$L" 2>/dev/null; then
  p=$(cat "$L/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && exit 0
  rm -rf "$L"; mkdir "$L" 2>/dev/null || exit 0
fi
echo $$ > "$L/pid"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/powos-nonroot.XXXXXX")
trap 'rm -rf "$L" "$tmp"' EXIT
[ -n "$dry" ] || echo "$(date +%s) $(cat "$Q/live" 2>/dev/null)" > "$NR/last"
# push.sh's resets from a private copy: the service's checkout is reset under a running script.
cp "$REPO/shell/push.sh" "$tmp/push.sh" || exit 0

# The APK the main phone runs, for the others: ship-apk.sh copies it after each install. None yet (the copy came in
# after the last install): the build output, when it is exactly that installed build.
APK=$NR/powos.apk
if [ ! -s "$APK.commit" ]; then
  out=${NONROOT_BUILD_APK:-$HOME/Projects/android-app-dev/output/powos.apk}
  oc=$(unzip -p "$out" assets/shell/shell-build.txt 2>/dev/null | awk '{print $2}')
  ic=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
  if [ -n "$oc" ] && [ "$oc" = "$ic" ] && cp "$out" "$APK.tmp" 2>/dev/null; then mv "$APK.tmp" "$APK"; echo "$oc" > "$APK.commit"; fi
fi
want=$(cat "$APK.commit" 2>/dev/null || true)
tip=$(cat "$Q/live" 2>/dev/null || true)
known() { [ -n "$1" ] && g cat-file -e "$1^{commit}" 2>/dev/null; }

# resolve PREFIX: an already-connected serial with that prefix that answers, else the first mDNS address (ip:port)
# that answers after a connect, else the first mDNS address (logged as not answering). mDNS keeps a stale entry after
# wireless debugging restarts on a new port ("<name>" at the old port beside "<name> (2)" at the live one): taking
# the first entry left the razr without APK installs for hours on 11-14 ("192.168.50.18:33919 not answering").
resolve() { local a first=""
  a=$("$ADB" devices 2>/dev/null | awk -F'\t' -v p="$1" 'index($1, p) == 1 && $2 == "device" {print $1}' | while IFS= read -r d; do
    [ "$("$ADB" -s "$d" get-state 2>/dev/null | tr -d '\r')" = device ] && { echo "$d"; break; }; done)
  [ -z "$a" ] || { echo "$a"; return 0; }
  for a in $("$ADB" mdns services 2>/dev/null | awk -F'\t' -v p="$1" 'index($1, p) == 1 && $2 ~ /_adb-tls-connect/ {print $3}'); do
    [ -n "$first" ] || first=$a
    "$ADB" connect "$a" >/dev/null 2>&1
    [ "$("$ADB" -s "$a" get-state 2>/dev/null | tr -d '\r')" = device ] && { echo "$a"; return 0; }
  done
  [ -n "$first" ] && echo "$first"; }
# delta A B: shell files changed A -> B (no dev/test): "+f" to push, "-f" to remove. A unknown: every file at B.
delta() {
  if known "$1"; then g diff --name-only "$1" "$2" -- shell/; else g ls-tree -r --name-only "$2" -- shell/; fi |
    grep -vE '^shell/(dev|test)/' | while read -r f; do g cat-file -e "$2:$f" 2>/dev/null && echo "+${f#shell/}" || echo "-${f#shell/}"; done; }

sync_device() { local name=$1 prefix=$2 D=$NR/$1 s inst base d add gone n rc pc f out scr
  mkdir -p "$D"
  s=$(resolve "$prefix") || { log "$name: not on the network (no mDNS $prefix) - next pass"; return 0; }
  case "$s" in *:*) "$ADB" connect "$s" >/dev/null 2>&1 ;; esac
  ad() { "$ADB" -s "$s" "$@"; }
  [ "$(ad get-state 2>/dev/null | tr -d '\r')" = device ] || { log "$name: $s not answering - next pass"; return 0; }
  ad shell "run-as $PKG true" >/dev/null 2>&1 || { log "$name: run-as $PKG refused (not a debuggable PowOS APK?) - skipped"; return 0; }
  stamp() { ad shell "unzip -p \$(pm path $PKG | head -1 | sed s/package://) assets/shell/shell-build.txt" 2>/dev/null | tr -d '\r' | awk '{print $2}'; }
  inst=$(stamp)
  if [ -n "$dry" ]; then
    echo "$name: $s APK ${inst:-?} (service's ${want:-none}) apk-stamp $(cat "$D/apk-stamp" 2>/dev/null || echo -) live $(cat "$D/live" 2>/dev/null || echo -) tip ${tip:-none}"
    base=$(cat "$D/live" 2>/dev/null || true); [ "$(cat "$D/apk-stamp" 2>/dev/null)" = "$inst" ] && [ -n "$base" ] || base=$inst
    [ -n "$tip" ] && echo "$name: shell delta ${base:0:9}..${tip:0:9}: $(delta "$base" "$tip" | grep -c '^+') to push, $(delta "$base" "$tip" | grep -c '^-') to remove"
    return 0
  fi
  # 1. The APK: newer than the device's (or the device's unknown here), never older.
  if [ -n "$want" ] && [ -s "$APK" ] && [ "$want" != "$inst" ] && { ! known "$inst" || g merge-base --is-ancestor "$inst" "$want" 2>/dev/null; }; then
    scr=${NONROOT_SCREEN:-$(ad shell dumpsys power 2>/dev/null | tr -d '\r' | sed -n 's/.*mWakefulness=//p' | head -1)}
    if [ "$scr" != Awake ] || [ -e "$HOME/.config/powos/ship-no-idle-wait" ]; then
      if out=$(ad install -r "$APK" 2>&1) && echo "$out" | grep -q Success; then
        note "$name: APK ${want:0:9} installed (was ${inst:0:9})"; inst=$(stamp)
      else note "$name: APK ${want:0:9} install FAILED: $(echo "$out" | tail -1 | cut -c1-200)"; fi
    else log "$name: APK ${want:0:9} waits for the screen off (the user is on it)"; fi
  fi
  # A different APK than last pass: its own shell is the base, the old overrides go.
  if [ "$(cat "$D/apk-stamp" 2>/dev/null)" != "$inst" ]; then
    ( cd "$tmp" && ANDROID_SERIAL=$s PATH="$(dirname "$ADB"):$PATH" POWOS_SHIP_SERVICE=1 bash ./push.sh --reset ) >> "$NR/log" 2>&1 ||
      { log "$name: resetting the overrides failed - next pass"; return 0; }
    echo "$inst" > "$D/apk-stamp"; rm -f "$D/live"; log "$name: on APK ${inst:0:9}, overrides reset"
  fi
  [ -n "$tip" ] && known "$tip" || return 0
  base=$(cat "$D/live" 2>/dev/null || true); [ -n "$base" ] || base=$inst
  [ "$base" = "$tip" ] && return 0
  if known "$base" && g merge-base --is-ancestor "$tip" "$base" 2>/dev/null; then return 0; fi   # it's ahead (a newer APK)
  d=$(delta "$base" "$tip")
  add=$(echo "$d" | sed -n 's/^+//p'); gone=$(echo "$d" | sed -n 's/^-//p')
  rc=0
  if [ -n "$add" ]; then
    rm -rf "$tmp/t"; mkdir -p "$tmp/t"
    g archive "$tip" shell | tar -xf - -C "$tmp/t" || { log "$name: git archive ${tip:0:9} failed"; return 0; }
    pc=; for f in $add; do pc="$pc $f=$(g log -1 --format=%H "$tip" -- "shell/$f")"; done
    ( cd "$tmp/t/shell" && ANDROID_SERIAL=$s PATH="$(dirname "$ADB"):$PATH" POWOS_SHIP_SERVICE=1 POWOS_GATE_DONE=1 \
        POWOS_PUSH_COMMITS="$pc" POWOS_PUSH_LAYER="$(g log -1 --format='%ct %H' "$tip")" bash ./push.sh --silent $add ) >> "$NR/log" 2>&1 || rc=$?
  fi
  if [ $rc = 0 ] && [ -n "$gone" ]; then
    ( cd "$tmp" && ANDROID_SERIAL=$s PATH="$(dirname "$ADB"):$PATH" POWOS_SHIP_SERVICE=1 bash ./push.sh --reset $gone ) >> "$NR/log" 2>&1 || rc=$?
  fi
  n=$(echo "$add" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ $rc = 0 ]; then echo "$tip" > "$D/live"; note "$name: shell ${tip:0:9} live ($n file(s) pushed$([ -n "$gone" ] && echo ", $(echo "$gone" | wc -l | tr -d ' ') removed"), from ${base:0:9})"
  else note "$name: shell ${tip:0:9} push FAILED rc $rc - log $NR/log; next pass tries again"; fi
}

while read -r name prefix _; do
  case "$name" in ''|\#*) continue ;; esac
  sync_device "$name" "$prefix"
done < "$CONF"
exit 0
