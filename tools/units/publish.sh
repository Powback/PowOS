#!/bin/bash
# tools/units/publish.sh [all|mac|colima|phone] (Mac): every host's units to the PowOS AI page (powos units publish),
# so no host there is ever silently old. The launchd agent com.powos.units-publish runs `all` every 15 min
# (tools/units/publish-deploy.sh; unit units/mac/units-publish-mac.json); tools/phone/ship.sh runs `phone` after each
# ship to the phone (the phone's own loop, powos-periodic.sh, publishes it every 15 min as well).
#   mac     the Mac's units + PowStation's containers (the Docker the Mac runs, host "powstation")
#   colima  the Colima VM's, read over `colima ssh` and published from here (the VM has no PowOS of its own)
#   phone   both phone sides, through the phone's own publisher (one adb call)
#   all     mac + colima
# A host that can't be read is republished from its last good snapshot with `--failed <why>`: the page shows it
# "stale" with that reason instead of a silent age. The code is origin's current (fetched each pass, like
# board-sweep.sh), so a fix there reaches the timer without a reinstall; this checkout's copy if git can't.
# State + log: ~/.cache/powos-units-publish (snapshots, publish.log).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
S=${UNITS_PUBLISH_DIR:-$HOME/.cache/powos-units-publish}; mkdir -p "$S"
REF=${POWOS_UNITS_REF:-origin/worktree-powos-multiplatform}
# The checkout to fetch from: this script's own (the repo), or the one install recorded (the installed copy).
R=${POWOS_UNITS_REPO:-$(cat "$S/repo" 2>/dev/null || git -C "$here" rev-parse --show-toplevel 2>/dev/null)}
log() { echo "$(date '+%F %T') $*" >> "$S/publish.log"; }
# with_timeout SECS CMD...: macOS has no timeout(1).
with_timeout() { perl -e '$t = shift; $SIG{ALRM} = sub { kill 9, $p; exit 124 }; $p = fork // die;
  if (!$p) { exec @ARGV or exit 127 } alarm $t; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"; }

# One pass at a time (a stuck ssh must not stack up under launchd).
if ! mkdir "$S/lock" 2>/dev/null; then
  p=$(cat "$S/lock/pid" 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then exit 0; fi
  rm -rf "$S/lock"; mkdir "$S/lock" || exit 1
fi
echo $$ > "$S/lock/pid"; trap 'rm -rf "$S/lock"' EXIT

# The code: origin's lib/apps + lib/ai/agents (powos-units loads its siblings and finds the board's CLI from there).
src=$S/src
if [ -n "$R" ] && with_timeout 60 git -C "$R" fetch -q origin "${REF#origin/}" 2>/dev/null &&
   rm -rf "$src.new" && mkdir -p "$src.new" &&
   git -C "$R" archive "$REF" lib/apps lib/ai/agents | tar -x -C "$src.new" 2>/dev/null; then
  rm -rf "$src" && mv "$src.new" "$src"
elif [ ! -x "$src/lib/apps/powos-units" ] && [ -n "$R" ] && [ -x "$R/lib/apps/powos-units" ]; then
  rm -rf "$src" && mkdir -p "$src/lib/ai" && cp -R "$R/lib/apps" "$src/lib/" && cp -R "$R/lib/ai/agents" "$src/lib/ai/"
fi
U=$src/lib/apps/powos-units
[ -x "$U" ] || { log "no powos-units (no checkout at '$R')"; exit 1; }

# publish_snap HOST CMD...: CMD prints HOST's `list --json --check`; good -> kept and published, else the last good
# one is published --failed with the reason (its first error line).
publish_snap() {
  local h=$1; shift
  local out=$S/$h.json.new err=$S/$h.err rc=0 why
  with_timeout 240 "$@" > "$out" 2> "$err" || rc=$?
  if [ $rc = 0 ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("units") is not None else 1)' "$out" 2>/dev/null; then
    mv "$out" "$S/$h.json"
    with_timeout 180 python3 "$U" publish --stdin < "$S/$h.json" >> "$S/publish.log" 2>&1 || { log "$h: publish failed (rc $?)"; return 1; }
    return 0
  fi
  why=$( [ $rc = 124 ] && echo "reading $h timed out" || { grep -m1 . "$err" 2>/dev/null | cut -c1-160; } )
  why=${why:-"reading $h failed (rc $rc)"}
  log "$h: $why"
  [ -s "$S/$h.json" ] || echo "{\"host\": \"$h\", \"units\": []}" > "$S/$h.json"
  with_timeout 180 python3 "$U" publish --stdin --failed "$why" < "$S/$h.json" >> "$S/publish.log" 2>&1
  return 1
}

rc=0
what=${1:-all}
case $what in mac|colima|phone|all) ;; *) sed -n 2,14p "$0"; exit 2 ;; esac
if [ "$what" = mac ] || [ "$what" = all ]; then
  publish_snap mac python3 "$U" list --json --check || rc=1
fi
if [ "$what" = colima ] || [ "$what" = all ]; then
  if command -v colima >/dev/null; then publish_snap colima colima ssh -- sudo python3 - list --json --check < "$U" || rc=1
  else log "colima: no colima here"; rc=1; fi
fi
if [ "$what" = phone ]; then
  with_timeout 240 "$here/../phone/adb.sh" shell "su -c 'sh /data/powos/powos-periodic.sh publish'" >> "$S/publish.log" 2>&1 ||
    { rc=$?; log "phone: publish failed (rc $rc)"; }
fi
# The log kept small.
[ "$(wc -l < "$S/publish.log" 2>/dev/null || echo 0)" -gt 2000 ] && { tail -1000 "$S/publish.log" > "$S/publish.log.new"; mv "$S/publish.log.new" "$S/publish.log"; }
exit $rc
