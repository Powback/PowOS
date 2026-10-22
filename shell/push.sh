#!/bin/bash
# Pushes shell files to the phone's override folder (the app's files/shell): the shell there hot-reloads them, no
# APK. A file pushed here wins over the one the APK ships until it's removed (--reset), so a later APK's version of it
# only shows after a reset.
#
# Usage: shell/push.sh --note "what changed, for the user" <file>...   paths relative to shell/ (e.g. ui/drawer.js)
#        shell/push.sh --silent <file>...   a change the user can't see (refactor, lint, tooling): no notification -
#        the manifest says "silent":true and comms only logs it (`powos comms quiet`)
#        shell/push.sh --reset [file...] remove overrides (all, or the files named)
#        --vpn first: through the VPN instead of a local adb (the wireguard container's network, as the Mac reaches
#        the phone: adb at 10.13.13.7:5555, or $POWOS_PHONE_ADDR).
# The note is the phone's quiet "update applied" notification (shade only, batched over 2 min with other deploys:
# targets/android/tools/deploy-note.sh): plain words - "Switcher now follows your finger" - never a file or a hash.
# ANDROID_SERIAL picks the phone when several are connected.
#
# The gate (shell/dev/gate.sh) runs first: tsc, then every page (home, lock, shade, assist, aod, recents) booted in a
# headless Chromium - the installed APK's shell (with --vpn; else the committed one) + the phone's current overrides +
# these files, as the phone will serve them.
# A page that doesn't load refuses the push, with the error. --force pushes anyway (the gate still runs and says so).
# A push writes a manifest (files/shell-push.json: when, which files, the note) and keeps the overrides it replaced
# (files/shell-prev/): a page that fails to boot within 2 min of it has that push rolled back by the app
# (ShellHost/ShellErrors.kt) and the manager told. Every shell error on the phone reaches the manager's comms inbox and
# files/shell-errors.log:
#        shell/push.sh --errors [N]   the phone's last N (default 40) shell errors (`powos shell errors` on the phone)
# Testing the safety net: break test/gate-test.tsx (the test-only page, ?mode=gate-test), never a live page, and push it
# with --test[=ROLE] (the manifest says so: its reports go to ROLE's inbox - default shelltest, a scratch role, never
# the manager or the user - as "[test]", low priority, read again after 2 min).
#        shell/push.sh --pre-gate <file>...   gate these files (the committed shell + them, no phone) and write a stamp
#        for exactly that file set and tree: prints "pre-gated <stamp>". Then, later, without gating again:
#        shell/push.sh --vpn --pre-gated=<stamp> --silent <file>...   (ship-apk: the push right after an install's reset)
# A push refuses a file whose live copy on the phone came from a commit your HEAD doesn't contain (files/
# shell-commits.txt on the phone: each pushed file's last commit): "<file> on the phone is from <sha> (newer than your
# base): rebase first". --force pushes anyway.
# Run by the ship service only (tools/phone/ship.sh: agents push to origin, then `ship.sh request`): anything else that
# changes the phone is refused unless --direct (an emergency, from origin's tip; logged to
# ~/.cache/powos-ship-queue/direct.log). --errors, --pre-gate and test/ pushes (--test) are free.
set -euo pipefail
cd "$(dirname "$0")"
force="" pregate="" pregated=""
for a in "$@"; do case "$a" in --force) force=1 ;; --pre-gate) pregate=1 ;; --pre-gated=*) pregated=${a#--pre-gated=} ;; esac; done
# The shell files among the arguments (not the flags, not --note's text).
shell_files() {
  local skip="" a
  for a in "$@"; do
    [ -n "$skip" ] && { skip=""; continue; }
    case "$a" in --note) skip=1 ;; --*) ;; *) [ -f "$a" ] && echo "$a" ;; esac
  done
}
reset_or_errors() { [[ " $* " == *" --reset "* || " $* " == *" --errors "* ]]; }
# One shipper (2026-10-23: agents pushing from their own worktrees raced each other and APK installs). Not inside the
# --vpn container's re-run (POWOS_GATE_DONE): checked once, here.
direct=""; da=(); for a in "$@"; do [ "$a" = --direct ] && direct=1 || da+=("$a"); done; set -- ${da[@]+"${da[@]}"}
only_test() { local f n=0; for f in $(shell_files "$@"); do case "$f" in test/*) n=1 ;; *) return 1 ;; esac; done; [ $n = 1 ]; }
if [ -z "${POWOS_GATE_DONE:-}" ] && [ -z "${POWOS_SHIP_SERVICE:-}" ] && [ -z "$pregate" ] && [[ " $* " != *" --errors "* ]] && ! only_test "$@"; then
  [ -n "$direct" ] || { echo "push.sh: refused - agents don't ship: push to origin, then tools/phone/ship.sh request --note \"...\" (the ship service pushes origin's tip; --direct only for an emergency, logged)" >&2; exit 3; }
  git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/worktree-powos-multiplatform 2>/dev/null)" ] ||
    { echo "push.sh: --direct refused - HEAD isn't origin/worktree-powos-multiplatform's tip (git pull --ff-only first)" >&2; exit 3; }
  dl=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}; mkdir -p "$dl"
  echo "$(date '+%F %T') push.sh --direct $(git rev-parse --short HEAD) $(basename "$(git rev-parse --show-toplevel)") pid $$: $*" >> "$dl/direct.log"
  echo "push.sh: --direct - outside the ship service (logged to $dl/direct.log)" >&2
fi
# A pre-gated push: the stamp must be for exactly these files at exactly this tree (HEAD's, the files unmodified) -
# anything else was never gated, and gates as any push.
if [ -n "$pregated" ] && [ -z "${POWOS_GATE_DONE:-}" ]; then
  want=$(printf 'tree %s\n' "$(git rev-parse 'HEAD^{tree}')"; shell_files "$@" | sort -u | sed 's/^/file /')
  have=$(grep -E '^(tree|file) ' "$pregated" 2>/dev/null | { read -r t; echo "$t"; sort -u; } || true)
  if [ "$want" != "$have" ] || [ -n "$(git status --porcelain -- $(shell_files "$@"))" ]; then
    echo "push.sh: refused - $pregated isn't a gate result for exactly these files at this tree ($(git rev-parse --short HEAD)); push without --pre-gated" >&2
    exit 1
  fi
fi
# What each file's push is from (its last commit in HEAD), for the phone's record (files/shell-commits.txt) - and,
# before it's replaced, the check that the phone's copy isn't from a commit this tree lacks.
if [ -z "${POWOS_GATE_DONE:-}" ] && ! reset_or_errors "$@" && [ -z "$pregate" ]; then
  POWOS_PUSH_COMMITS=""
  for f in $(shell_files "$@"); do
    c=$(git log -1 --format=%H HEAD -- "$f" 2>/dev/null || true)
    [ -n "$c" ] && POWOS_PUSH_COMMITS="$POWOS_PUSH_COMMITS $f=$c"
  done
  export POWOS_PUSH_COMMITS
fi
# check_newer RECORD FILE...: refuse FILE when the phone's copy came from a commit HEAD doesn't contain.
check_newer() {
  local rec=$1 f c bad=""; shift
  [ -s "$rec" ] || return 0
  for f in "$@"; do
    c=$(awk -v f="$f" '$1 == f { c = $2 } END { print c }' "$rec")
    [ -n "$c" ] || continue
    git merge-base --is-ancestor "$c" HEAD 2>/dev/null || bad="$bad$f on the phone is from ${c:0:9} (newer than your base): rebase first"$'\n'
  done
  [ -z "$bad" ] && return 0
  printf 'push.sh: refused - %s' "$bad" >&2
  [ -n "$force" ] && { echo "push.sh: pushing anyway (--force)" >&2; return 0; }
  return 1
}
[ -n "$pregated" ] && export POWOS_GATE_DONE=1
# Only origin's tip goes to the phone: a file is pushed whole, so a stale copy from one tree overwrites what another
# agent pushed in the same file (16:24: a shell.css without the drawer's newest rules, pushed after them - the drawer
# fell apart into one column on the phone). Each file must be exactly origin's version: commit, rebase, push to
# origin, then push here. The gate-test page (test/) is exempt; --force overrides. Checked first, before either path.
if [ -z "${POWOS_GATE_DONE:-}" ] && [ -z "$force" ] && [ -z "$pregate" ] && ! reset_or_errors "$@"; then
  git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
  stale=""; skip=""
  for a in "$@"; do
    [ -n "$skip" ] && { skip=""; continue; }
    case "$a" in --note) skip=1; continue ;; --*) continue ;; test/*) continue ;; esac
    [ -f "$a" ] || continue
    git show "origin/worktree-powos-multiplatform:shell/$a" 2>/dev/null | cmp -s - "$a" || stale="$stale $a"
  done
  [ -z "$stale" ] || { echo "push.sh: refused - not origin's version:$stale (commit, rebase onto origin/worktree-powos-multiplatform, push to origin, then push here)" >&2; exit 1; }
fi
# --pre-gate: the gate alone, on the committed shell + these files (what the phone runs after an install of this
# tree's parent build and a push of them - ship-apk's case), and a stamp for exactly them at exactly this tree.
if [ -n "$pregate" ]; then
  pf=($(shell_files "$@"))
  [ ${#pf[@]} -gt 0 ] || { echo "push.sh: --pre-gate which files?" >&2; exit 2; }
  [ -z "$(git status --porcelain -- "${pf[@]}")" ] || { echo "push.sh: --pre-gate: commit them first (only HEAD's files are stamped)" >&2; exit 1; }
  # Of origin's history (the tip, or behind it while origin moves on - ship-apk pushes what came later, gated).
  git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
  git merge-base --is-ancestor HEAD origin/worktree-powos-multiplatform 2>/dev/null || { echo "push.sh: --pre-gate: HEAD isn't on origin/worktree-powos-multiplatform" >&2; exit 1; }
  set +e
  out=$(dev/gate.sh "${pf[@]}" 2>&1); gate=$?
  if [ $gate -ne 0 ] && ! echo "$out" | grep '^FAIL' | grep -qv 'not ready'; then
    out=$(READY_MS=$(( ${READY_MS:-0} > 30000 ? ${READY_MS:-0} : 30000 )) dev/gate.sh "${pf[@]}" 2>&1); gate=$?
  fi
  set -e
  echo "$out"
  [ $gate -eq 0 ] || { echo "push.sh: pre-gate failed (above)" >&2; exit 1; }
  mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/pregated"
  stamp=$(mktemp "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/pregated/stamp.XXXXXX")
  { echo "tree $(git rev-parse 'HEAD^{tree}')"; echo "commit $(git rev-parse HEAD)"; printf '%s\n' "${pf[@]}" | sort -u | sed 's/^/file /'; } > "$stamp"
  echo "pre-gated $stamp"
  exit 0
fi
if [ "${1:-}" = "--vpn" ]; then
  shift
  addr=${POWOS_PHONE_ADDR:-10.13.13.7:5555}
  # The gate here, on the Mac (docker and git are here, not in the adb container): the committed shell + the phone's
  # current overrides (pulled through the adb container, as the local path pulls them) + the files pushed - the shell
  # the phone will run. Without the overrides it checked a shell the phone doesn't have (2026-10-21: a push that passed
  # was followed by a home error). Overrides that can't be pulled: the committed shell + the files, as before.
  if [ -z "${POWOS_GATE_DONE:-}" ] && [[ " $* " != *" --reset "* ]] && [[ " $* " != *" --errors "* ]]; then
    gf=(); for a in "$@"; do case "$a" in --*) ;; *) [ -f "$a" ] && gf+=("$a") ;; esac; done
    if [ ${#gf[@]} -gt 0 ]; then
      # Under $HOME: Colima mounts only the home folder into containers.
      mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate"
      ov=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/vpn-overrides.XXXXXX")
      ga=()
      # The installed APK's own shell (its assets/shell): what the phone runs under the overrides - not HEAD while the
      # APK lags behind (2026-10-21: HEAD's assist.tsx failed against the phone's overrides, and a fix that passed on
      # the phone's real shell couldn't go). Pulled once per install (cached by the APK's path and update time).
      cache="${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/installed"
      mkdir -p "$cache"
      # In the same call: the phone's live module schemas, for the bindings check below.
      if docker run --rm --network container:wireguard -v "$HOME/.android:/root/.android" -v "$ov:/ov" -v "$cache:/cache" \
        -e ANDROID_SERIAL="$addr" -e SCHEMAS="$(../tools/phone/bindings-check.sh --remote-cmd)" android-app-dev-android-builder:latest bash -c '
          adb connect "$ANDROID_SERIAL" >/dev/null 2>&1
          adb -s "$ANDROID_SERIAL" exec-out "su -c \"cd /data/data/com.powos.app/files && tar -cf - shell\"" | tar -xf - -C /ov || exit 1
          adb -s "$ANDROID_SERIAL" exec-out "su -c \"cat /data/data/com.powos.app/files/shell-commits.txt 2>/dev/null\"" > /ov/commits.txt 2>/dev/null
          adb -s "$ANDROID_SERIAL" shell "$SCHEMAS" | tr -d "\r" > /ov/schemas.txt
          apk=$(adb -s "$ANDROID_SERIAL" shell pm path com.powos.app | tr -d "\r" | head -1 | sed "s/^package://")
          key=$(adb -s "$ANDROID_SERIAL" shell dumpsys package com.powos.app | tr -d "\r" | grep -m1 lastUpdateTime | tr -cd "0-9")
          [ -n "$apk" ] && [ -n "$key" ] || exit 0
          [ -f "/cache/$key.apk" ] || { rm -f /cache/*.apk; adb -s "$ANDROID_SERIAL" exec-out "su -c \"cat $apk\"" > "/cache/$key.apk.part" && mv "/cache/$key.apk.part" "/cache/$key.apk"; }
          echo "$key" > /cache/current' \
        >/dev/null 2>&1 && [ -d "$ov/shell" ]; then
        check_newer "$ov/commits.txt" "${gf[@]}" || { rm -rf "$ov"; exit 1; }
        ga=(--overrides "$ov/shell")
        key=$(cat "$cache/current" 2>/dev/null || true)
        if [ -n "$key" ] && [ -f "$cache/$key.apk" ]; then
          [ -d "$cache/$key/shell" ] || { rm -rf "$cache"/[0-9]*/; mkdir -p "$cache/$key" && unzip -q -o "$cache/$key.apk" 'assets/shell/*' -d "$cache/$key" && mv "$cache/$key/assets/shell" "$cache/$key/shell"; }
          [ -d "$cache/$key/shell" ] && ga+=(--installed "$cache/$key/shell")
        fi
        [ ${#ga[@]} -gt 2 ] || echo "push.sh: couldn't read the installed APK's shell - gating the committed shell + overrides + these files" >&2
      else
        echo "push.sh: couldn't pull the phone's overrides - gating the committed shell + these files only" >&2
      fi
      set +e
      # The retry's wait: 30 s, or longer when asked (READY_MS=90000 shell/push.sh ... on a very busy Mac).
      slow=$(( ${READY_MS:-0} > 30000 ? ${READY_MS:-0} : 30000 ))
      out=$(dev/gate.sh ${ga[@]+"${ga[@]}"} "${gf[@]}" 2>&1)
      gate=$?
      # Only "not ready" timeouts, no error at all: the Mac was loaded (concurrent builds/gates - 2026-10-21 every page
      # timed out at ~10 s while the same composition passed in 16 s a minute later). Once more with a longer wait.
      if [ $gate -ne 0 ] && ! echo "$out" | grep '^FAIL' | grep -qv 'not ready'; then
        echo "push.sh: only boot timeouts - the Mac is busy? gating once more with READY_MS=$slow" >&2
        out=$(READY_MS=$slow dev/gate.sh ${ga[@]+"${ga[@]}"} "${gf[@]}" 2>&1)
        gate=$?
      fi
      echo "$out"
      # HEAD + the phone's overrides can be broken without this push (the APK on the phone isn't HEAD, other agents'
      # overrides are half a change): then only failures this push ADDS refuse it - the same gate without its files
      # is the baseline (failures compared without their timings).
      if [ $gate -ne 0 ] && [ ${#ga[@]} -gt 0 ]; then
        norm() { grep '^FAIL' | sed 's/ within [0-9]* ms//; s/([0-9]* ms)//' | sort -u; }
        base=$(READY_MS=$slow dev/gate.sh "${ga[@]}" 2>&1 | norm)
        added=$(comm -13 <(echo "$base") <(echo "$out" | norm))
        if [ -z "$added" ]; then
          echo "push.sh: those failures are the phone's already (the same without these files) - this push adds none" >&2
          gate=0
        else
          echo "push.sh: this push adds:" >&2; echo "$added" >&2
        fi
      fi
      # The bindings the phone will run (these files, its overrides, the installed APK's) against its live modules: a
      # table of another shape can't be decoded on home (local-pet, twice on 2026-10-21). Bindings ahead of the module
      # are published from this commit's module when it builds them; anything else refuses the push with the fix.
      if [ -s "$ov/schemas.txt" ]; then
        mkdir -p "$ov/pushed"; for f in "${gf[@]}"; do case "$f" in vendor/*.js) cp "$f" "$ov/pushed/" ;; esac; done
        bv=(--vendor "$ov/pushed" --vendor "$ov/shell/vendor")
        [ -n "${key:-}" ] && [ -d "$cache/$key/shell/vendor" ] && bv+=(--vendor "$cache/$key/shell/vendor")
        ../tools/phone/bindings-check.sh --schemas "$ov/schemas.txt" "${bv[@]}" --vendor vendor || gate=1
      else
        echo "push.sh: couldn't read the phone's module schemas - bindings not checked" >&2
      fi
      set -e
      rm -rf "$ov"
      if [ $gate -ne 0 ]; then
        [ -n "$force" ] || { echo "push.sh: refused - the gate failed (above). Fix it, or --force to push anyway." >&2; exit 1; }
        echo "push.sh: the gate failed - pushing anyway (--force)" >&2
      fi
    fi
  fi
  exec docker run --rm -i --network container:wireguard -v "$HOME/.android:/root/.android" -v "$PWD:/shell" \
    -e ANDROID_SERIAL="$addr" -e POWOS_GATE_DONE=1 -e POWOS_PUSH_COMMITS="${POWOS_PUSH_COMMITS:-}" android-app-dev-android-builder:latest \
    bash -c 'adb connect "$ANDROID_SERIAL" >/dev/null 2>&1; sleep 1; bash /shell/push.sh "$@"' _ "$@"
fi
note="" test="" test_to="" silent=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --note) note=${2:-}; shift 2 || shift ;;
    --note=*) note=${1#--note=}; shift ;;
    --force) shift ;;
    --silent) silent=1; shift ;;
    --pre-gated=*) shift ;;
    --test) test=1; test_to=shelltest; shift ;;
    --test=*) test=1; test_to=${1#--test=}; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}
if [ $# -gt 0 ] && [ "$1" != "--reset" ] && [ "$1" != "--errors" ] && [ -z "${note// }" ] && [ -z "$silent" ]; then
  echo "push.sh: --note \"what changed, for the user\" is required (the phone's update notification), or --silent for a change the user can't see" >&2
  exit 2
fi
pkg=com.powos.app
# As the app (run-as), or as root where run-as can't reach it: a privileged system app's data (the PowOS system module)
# is privapp_data_file, out of run-as's reach. Root writes files as the app's user so the app can still change them.
if adb shell "run-as $pkg true" >/dev/null 2>&1; then
  as_app() { adb shell "run-as $pkg sh -c '$1'"; }
else
  uid=$(adb shell "su -c 'stat -c %u /data/data/$pkg'" | tr -d '\r')
  as_app() { adb shell "su $uid -c 'cd /data/data/$pkg && $1'"; }
fi
# record_commits FILE...: the phone's files/shell-commits.txt ("<file> <commit>" per live override) without these
# files' lines, plus $POWOS_PUSH_COMMITS' ("file=commit ...") - merged here, written back whole.
record_commits() {
  local cur f kv b
  cur=$(as_app "cat files/shell-commits.txt 2>/dev/null" | tr -d '\r' || true)
  for f in "$@"; do cur=$(echo "$cur" | awk -v f="$f" '$1 != f && NF == 2'); done
  for kv in ${POWOS_PUSH_COMMITS:-}; do cur=$(printf '%s\n%s %s' "$cur" "${kv%%=*}" "${kv#*=}"); done
  b=$(echo "$cur" | awk 'NF == 2' | base64 | tr -d '\n')
  as_app "echo $b | base64 -d > files/shell-commits.txt" || echo "push.sh: couldn't update the phone's files/shell-commits.txt" >&2
}
if [ "${1:-}" = "--errors" ]; then
  as_app "tail -n ${2:-40} files/shell-errors.log 2>/dev/null || echo no shell errors logged"
  exit 0
fi
if [ "${1:-}" = "--reset" ]; then
  shift
  if [ $# -eq 0 ]; then
    # Its contents, not the folder: the shell watches the folder itself, and a new one would go unwatched. No push
    # left to roll back either. Between .pushing and its removal like a push: HotReload holds the deletions and the
    # pages reload once, on the APK's shell - not per file on a half-removed mix (home failed on one, 2026-10-21).
    as_app "cd files/shell && echo > .pushing && find . -mindepth 1 -maxdepth 1 ! -name .pushing -exec rm -rf {} + ; rm -f .pushing; rm -rf ../shell-push.json ../shell-prev ../shell-commits.txt"
  else
    m=""; for f in "$@"; do m="$m files/shell/$f"; done
    as_app "echo > files/shell/.pushing; rm -f$m; rm -f files/shell/.pushing"
    record_commits "$@"
  fi
  exit 0
fi
[ $# -gt 0 ] || { sed -n '2,23p' "$0"; exit 1; }
for f in "$@"; do
  [ -f "$f" ] || { echo "push.sh: no such shell file: $f" >&2; exit 1; }
  case "$f" in *"'"*|*" "*) echo "push.sh: no quotes or spaces in shell paths: $f" >&2; exit 1 ;; esac
done
# The gate: the shell the phone will run after this push - the committed shell, the phone's overrides (pulled in one
# call), these files - type-checked and every page booted (shell/dev/gate.sh).
if [ -z "${POWOS_GATE_DONE:-}" ]; then
  ov=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/overrides.XXXXXX" 2>/dev/null || mktemp -d)
  as_app "cd files && tar -cf - shell 2>/dev/null | base64" | tr -d '\r' | base64 -d 2>/dev/null | tar -xf - -C "$ov" 2>/dev/null || true
  as_app "cat files/shell-commits.txt 2>/dev/null" | tr -d '\r' > "$ov/commits.txt" || true
  check_newer "$ov/commits.txt" "$@" || { rm -rf "$ov"; exit 1; }
  set +e
  dev/gate.sh --overrides "$ov/shell" "$@"
  gate=$?
  set -e
  rm -rf "$ov"
  if [ $gate -ne 0 ]; then
    [ -n "$force" ] || { echo "push.sh: refused - the gate failed (above). Fix it, or --force to push anyway." >&2; exit 1; }
    echo "push.sh: the gate failed - pushing anyway (--force)" >&2
  fi
fi
# The push manifest, before the files (a page booting on the first of them already knows it's this push's), and the
# overrides it replaces kept (files/shell-prev/): what the app's rollback restores (ShellErrors.kt).
files_json=$(printf '"%s",' "$@"); files_json="[${files_json%,}]"
json_note=$(printf '%s' "$note" | tr -d '\n\r\t' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-300)
manifest=$(printf '{"at":%s,"files":%s,"note":"%s","from":"%s","test":%s,"testTo":"%s","silent":%s}' "$(date +%s)" "$files_json" "$json_note" "$(hostname -s 2>/dev/null || echo mac)" "$([ -n "$test" ] && echo true || echo false)" "$test_to" "$([ -n "$silent" ] && echo true || echo false)" | base64 | tr -d '\n')
as_app "rm -rf files/shell-prev && echo $manifest | base64 -d > files/shell-push.json"
# Atomic: every file staged on the phone first (one adb push of a tar, unpacked into files/shell-staging - the same
# filesystem as files/shell), then all of them renamed into files/shell in one call, between files/shell/.pushing
# written (echo, a CLOSE_WRITE - touch only opens it read-only) and removed. A page reloads once, on the whole push:
# ShellHost's HotReload holds every change while .pushing is there and sends them when it goes; an older APK sends
# each, and the renames all land within hot.ts's 300 ms debounce. File by file (each its own adb round trip, ~1 s), a
# page reloaded between an importer and the new module it imports, and the import 404'd (2026-10-20 02:59: gesture.ts
# landed, ui/keyboard.ts a second later).
tmp=/data/local/tmp/powos-shell-push.tar
tarf=$(mktemp "${TMPDIR:-/tmp}/powos-shell-push.XXXXXX")
tflags=(); tar --version 2>/dev/null | grep -q bsdtar && tflags=(--no-xattrs --no-mac-metadata --format ustar)
COPYFILE_DISABLE=1 tar ${tflags[@]+"${tflags[@]}"} -cf "$tarf" "$@"
adb push -q "$tarf" "$tmp"
rm -f "$tarf"
moves=""
for f in "$@"; do
  moves="$moves if [ -f shell/$f ]; then mkdir -p shell-prev/$(dirname "$f") && cp shell/$f shell-prev/$f; fi; mkdir -p shell/$(dirname "$f") && mv -f shell-staging/$f shell/$f || ok=0;"
done
as_app "cd files && rm -rf shell-staging && mkdir -p shell-staging && tar -xf $tmp -C shell-staging && echo > shell/.pushing && ok=1 && {$moves true; }; rm -f shell/.pushing; rm -rf shell-staging; [ \${ok:-0} = 1 ]" || {
  as_app "rm -f files/shell/.pushing; rm -rf files/shell-staging"; adb shell "rm -f $tmp"
  echo "push.sh: staging or moving the files on the phone failed" >&2; exit 1; }
adb shell "rm -f $tmp"
record_commits "$@"
for f in "$@"; do echo "pushed $f"; done
# The phone's "update applied" notification (as targets/android/tools/deploy-note.sh, which this folder alone - the
# --vpn container mounts only shell/ - can't reach): one su call, comms batches it with the other deploys.
# --silent: nobody told, only comms' quiet log (what landed: the files).
[ -n "$silent" ] && note="shell push (silent): $*"
b=$(printf '%s' "$note" | base64 | tr -d '\n')
adb shell "su -c \"sh /data/powos/powos-run.sh 'echo $b | base64 -d | powos comms notify --from deploy ${silent:+--silent} --priority low --batch deploy -'\"" >/dev/null ||
  echo "push.sh: the phone wasn't told (\"$note\")" >&2
