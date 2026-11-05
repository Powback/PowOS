#!/bin/bash
# bf-cfg-phone.sh set <x86|arm64> | restore: (in the PowOS session as powos; bf-pacing.sh / bf-checker.sh `cfg:<x>`
# push and run it) run a Steam game (APP, default Broforce 274190) under one compat tool for ONE check, then put the
# user's choice back. The same swap as bf-coldstart-phone.sh's cfg: tokens: Steam closed (bf-stop.sh --steam),
# powos-steam-compat set <appid> <x86|arm64> (the copy the check pushed, /var/tmp/powos-steam-compat), and the
# per-architecture Proton prefix swapped in (compatdata/<id> <-> compatdata/<id>.powos-<family>: a prefix ARM64 Proton
# set up breaks x86 Proton's VC++ DLLs, Teardown 2026-10-23). `set` records the mode and family it found in
# ~/.cache/powos/bf-cfg-<appid> (only the first set of a check: a second one keeps the original); `restore` closes
# Steam, swaps the original prefix back, sets the recorded mode and removes the record. A record left by a killed
# check is restored by the next check's `set` first, so the user's pinned tool never stays changed.
set -uo pipefail
APP=${APP:-274190}
S=$HOME/.local/share/Steam CD0=$S/steamapps/compatdata/$APP REC=$HOME/.cache/powos/bf-cfg-$APP
CFG="python3 /var/tmp/powos-steam-compat"
fam() { cat "$CD0/powos-family" 2>/dev/null || { case $($CFG get "$APP") in *arm64*) echo arm64 ;; *) echo x86 ;; esac; }; }
use() {  # use <family>: that family's prefix at compatdata/<id>, the other kept beside it
  local cur; cur=$(fam); [ "$cur" = "$1" ] && return 0
  [ -d "$CD0" ] && { rm -rf "$CD0.powos-$cur.old"; [ -e "$CD0.powos-$cur" ] && mv "$CD0.powos-$cur" "$CD0.powos-$cur.old"; echo "$cur" > "$CD0/powos-family"; mv "$CD0" "$CD0.powos-$cur"; }
  if [ -d "$CD0.powos-$1" ]; then mv "$CD0.powos-$1" "$CD0"; else mkdir -p "$CD0"; fi
  echo "$1" > "$CD0/powos-family"; echo "   prefix: $1 (the $cur one kept as compatdata/$APP.powos-$cur)"
}
restore() {
  [ -f "$REC" ] || return 0
  local mode family; mode=$(sed -n 's/^mode=//p' "$REC"); family=$(sed -n 's/^family=//p' "$REC")
  bash /var/tmp/powos-bf-stop.sh --steam >/dev/null 2>&1
  use "$family"; $CFG set "$APP" "$mode" >/dev/null && rm -f "$REC"
  echo "cfg restored: $($CFG get "$APP"), mode $($CFG mode "$APP")"
}
case ${1:-} in
  set) case ${2:-} in x86 | arm64) ;; *) echo "FAIL cfg: x86 or arm64, not '${2:-}'"; exit 2 ;; esac
    restore  # a record from a killed check first
    mkdir -p "$(dirname "$REC")"; printf 'mode=%s\nfamily=%s\n' "$($CFG mode "$APP")" "$(fam)" > "$REC"
    bash /var/tmp/powos-bf-stop.sh --steam | head -1
    $CFG set "$APP" "$2" >/dev/null && use "$2" && echo "cfg $2: $($CFG get "$APP"), mode $($CFG mode "$APP")" ;;
  restore) restore ;;
  *) echo "usage: bf-cfg-phone.sh set <x86|arm64> | restore"; exit 2 ;;
esac
