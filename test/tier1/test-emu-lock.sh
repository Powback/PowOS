#!/bin/bash
# Test: the emulator lock (tools/emu/emu.sh and tools/phone/verify/queue-emu.sh emu_lock_acquire): a live holder is
# waited for, a dead one is reclaimed, and pid 1 / junk is never a holder.
# Runs the REAL functions (extracted from both scripts) against a private XDG_CACHE_HOME: the old version of this test
# wrote "1 dead-holder" into the real ~/.cache/powos-emu.lock (found there 11-10, dated 11-08); as root (a container)
# pid 1 passes kill -0, so such a lock is never reclaimed there (docs/WINDOWS_FIX_PLAN.md 0.2).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export XDG_CACHE_HOME; XDG_CACHE_HOME=$(mktemp -d); trap 'rm -rf "$XDG_CACHE_HOME"' EXIT
lock=$XDG_CACHE_HOME/powos-emu.lock
fails=0
ok() { echo "ok - $*"; }
no() { echo "FAIL - $*"; fails=$((fails + 1)); }
die() { echo "die: $*"; return "${2:-1}"; }
# fn_of <file> <name>: the function's text (from "name() {" to the first line that is just "}").
fn_of() { awk -v n="$2" '$0 ~ "^"n"\\(\\) *\\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }

for src in tools/emu/emu.sh tools/phone/verify/queue-emu.sh; do
  body=$(fn_of "$ROOT/$src" emu_lock_acquire)
  [ -n "$body" ] || { no "$src: no emu_lock_acquire"; continue; }
  # 240 tries of 1 s -> 3 tries: a wrong verdict fails in seconds, not 4 minutes.
  eval "$(sed 's/seq 240/seq 3/' <<<"$body")"
  unset LOCK_HELD

  rm -rf "$lock"; mkdir "$lock"; echo 1 > "$lock/pid"; echo dead-holder > "$lock/label"
  ( emu_lock_acquire t ) >/dev/null 2>&1 && ok "$src: pid 1 isn't a holder" || no "$src: pid 1 blocked the lock"

  rm -rf "$lock"; mkdir "$lock"; echo junk > "$lock/pid"
  ( emu_lock_acquire t ) >/dev/null 2>&1 && ok "$src: a junk pid isn't a holder" || no "$src: a junk pid blocked the lock"

  rm -rf "$lock"; sleep 30 & dead=$!; kill "$dead"; wait "$dead" 2>/dev/null
  mkdir "$lock"; echo "$dead" > "$lock/pid"
  ( emu_lock_acquire t ) >/dev/null 2>&1 && ok "$src: a dead holder is reclaimed" || no "$src: a dead holder blocked the lock"

  rm -rf "$lock"; sleep 30 & live=$!
  mkdir "$lock"; echo "$live" > "$lock/pid"
  ( emu_lock_acquire t ) >/dev/null 2>&1 && no "$src: took a live holder's lock" || ok "$src: a live holder is waited for"
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$live" ] && ok "$src: the live holder keeps its lock" || no "$src: the live holder lost its lock"
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
done
rm -rf "$lock"
[ "$fails" = 0 ] && { echo "PASS test-emu-lock"; exit 0; }
echo "FAIL test-emu-lock: $fails"; exit 1
