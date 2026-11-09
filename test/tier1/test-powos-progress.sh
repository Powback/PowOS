#!/usr/bin/env bash
# powos-progress (targets/android/play/powos-progress, Powback/PowOS#11): a job's progress as run/progress-<id>.state
# for the app (engine Progress.java) - the line formats it reads, atomically written, a no-op where no app serves it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
P=$HERE/targets/android/play/powos-progress
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0 fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok   - $1"; else fail=$((fail + 1)); echo "  FAIL - $1"; fi; }
export XDG_RUNTIME_DIR=$W
bash "$P" steam-setup 10 20 "Downloading Steam"; rc=$?
ok "no app (no verbs file): succeeds, writes nothing" '[ $rc = 0 ] && [ ! -e "$W/progress-steam-setup.state" ]'
printf 'pack\nprogress\n' > "$W/android-request.verbs"
bash "$P" steam-setup 10 20 Downloading Steam
ok "progress: 'done total' then the title" '[ "$(cat "$W/progress-steam-setup.state")" = "10 20
Downloading Steam" ]'
bash "$P" steam-setup failed no network
ok "failed: its message" '[ "$(cat "$W/progress-steam-setup.state")" = "failed no network" ]'
bash "$P" steam-setup done
ok "done" '[ "$(cat "$W/progress-steam-setup.state")" = done ]'
ok "no temp file left" '[ -z "$(ls "$W" | grep tmp)" ]'
bash "$P" "../x" 1 2 t 2>/dev/null; rc=$?
ok "a bad id is refused" '[ $rc = 2 ] && [ ! -e "$W/../x" ]'
bash "$P" j 1 lots t 2>/dev/null; rc=$?
ok "non-numbers refused" '[ $rc = 2 ]'
bash -n "$HERE/targets/android/play/powos-steam"; ok "powos-steam parses" '[ $? = 0 ]'
echo "Results: $pass passed, $fail failed"
[ "$fail" = 0 ]
