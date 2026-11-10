#!/bin/bash
# test-cdp-warm.sh - tools/phone/cdp.sh reuses one warm bun container (tools/phone/cdp-warm.sh) and falls back to the
# per-call `docker run` when it can't, with output and exit codes unchanged. Fakes for docker and adb: no daemon.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CDP="$ROOT/tools/phone/cdp.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# Fake adb: cdp.sh's devtools lookup answers pid=$FAKE_PID (no socket list: pidof's pid is used); forward succeeds.
cat >"$T/adb" <<'EOF'
#!/bin/bash
case "$1" in shell) echo "pid=${FAKE_PID-4242}"; exit "${FAKE_ADB_RC:-0}" ;; esac
exit 0
EOF
# Fake docker: state under $FAKE_D. Logs every call.
cat >"$T/docker" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_D/log"
case "$1" in
  inspect)
    shift; fmt=; [ "$1" = --format ] && { fmt=$2; shift 2; }
    rc=0
    for n in "$@"; do
      pre=; [ "${fmt#\{\{.Name\}\}}" != "$fmt" ] && pre="/$n|"
      if [ "$n" = powos-vadb ] && [ -s "$FAKE_D/vadb-id" ]; then echo "$pre|true|$(cat "$FAKE_D/vadb-id")"
      elif [ "$n" != powos-vadb ] && [ -d "$FAKE_D/c" ]; then echo "$pre$(cat "$FAKE_D/c/netns")|true${pre:+|cid}"
      else echo "Error: No such object: $n" >&2; rc=1; fi
    done; exit $rc ;;
  run)
    if [ "$2" = -d ]; then
      [ -n "${FAKE_RUN_FAIL:-}" ] && exit 125
      mkdir "$FAKE_D/c" 2>/dev/null || { echo "Conflict" >&2; exit 125; }
      for a in "$@"; do case "$a" in powos.cdp.netns=*) echo "${a#*=}" >"$FAKE_D/c/netns" ;; esac; done
      echo created >>"$FAKE_D/starts"
      sleep 0.2  # losers of a start race inspect the winner's container meanwhile
      echo newid; exit 0
    fi
    shift; while [ "$1" != oven/bun:1 ]; do shift; done; shift
    echo "cold: $*"; exit "${FAKE_RC:-0}" ;;
  exec)
    [ -n "${FAKE_EXEC_GONE:-}" ] && { echo "Error response from daemon: No such container" >&2; exit 1; }
    while [ "$1" != sh ]; do shift; done
    # sh -c '<wrapper>' sh <mark> <script> args...
    mark=$5 script=$6; shift 6
    touch "$CDP_WARM_DIR/$mark"
    [ -s "$CDP_WARM_DIR/$script" ] || { echo "no script $script"; exit 9; }
    echo "warm: bun /s/$script $*" | sed "s/cdp-[A-Za-z0-9_]*\\.ts/cdp.ts/"; exit "${FAKE_RC:-0}" ;;
  rm) rm -rf "$FAKE_D/c"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/adb" "$T/docker"

reset() { rm -rf "$T/d" "$T/w"; mkdir -p "$T/d"; echo vadb1 >"$T/d/vadb-id"; }
run() { env CDP_FWD_CACHE_S=0 CDP_WARM_OK_S=0 CDP_ADB="$T/adb" CDP_DOCKER="$T/docker" FAKE_D="$T/d" CDP_WARM_DIR="$T/w" CDP_WARM_NAME=warm-test "$@" "$CDP" eval home '1+1'; }
starts() { [ -f "$T/d/starts" ] && wc -l <"$T/d/starts" | tr -d ' ' || echo 0; }

echo "cdp warm runner"
reset
out=$(run) rc=$?
[ "$out" = "warm: bun /s/cdp.ts eval home 1+1" ] && [ $rc = 0 ] && [ "$(starts)" = 1 ] && ok "first call starts the warm container and runs there" || bad "first call: rc=$rc out=$out starts=$(starts)"
out=$(run) rc=$?
[ "$out" = "warm: bun /s/cdp.ts eval home 1+1" ] && [ "$(starts)" = 1 ] && ok "second call reuses it (no new container)" || bad "reuse: out=$out starts=$(starts)"
grep -q '^exec .*CDP_PORT=9333 warm-test' "$T/d/log" && ok "port reaches the exec" || bad "no CDP_PORT in exec"
out=$(run FAKE_RC=1) rc=$?
[ $rc = 1 ] && [ "$(grep -c '^run --rm' "$T/d/log")" = 0 ] && ok "cdp.ts's own rc 1 passes through, no fallback" || bad "rc passthrough: rc=$rc"
out=$(run FAKE_RC=124) rc=$?
[ $rc = 124 ] && ok "timeout rc 124 passes through" || bad "rc 124: $rc"
ls "$T/w" | grep -q '^run\.' && bad "run markers left behind" || ok "run markers cleaned up"

echo vadb2 >"$T/d/vadb-id"
out=$(run) rc=$?
grep -q '^rm -f warm-test' "$T/d/log" && [ "$(starts)" = 2 ] && [ "$(cat "$T/d/c/netns")" = vadb2 ] && ok "a recreated powos-vadb replaces the container" || bad "netns change: starts=$(starts)"

out=$(run FAKE_EXEC_GONE=1) rc=$?
[ "$out" = "cold: bun /t/cdp.ts eval home 1+1" ] && [ $rc = 0 ] && ok "exec never reached cdp.ts -> per-call fallback" || bad "exec gone: rc=$rc out=$out"

reset
out=$(run FAKE_RUN_FAIL=1 FAKE_RC=3) rc=$?
[ "$out" = "cold: bun /t/cdp.ts eval home 1+1" ] && [ $rc = 3 ] && ok "helper can't start -> per-call fallback, its rc kept" || bad "start fail: rc=$rc out=$out"
reset; run >/dev/null; : >"$T/d/vadb-id"
out=$(run) rc=$?
[ "${out#cold:}" != "$out" ] && ok "powos-vadb gone (warm one still up) -> fallback" || bad "no vadb: $out"
reset
out=$(run CDP_WARM=0) rc=$?
[ "${out#cold:}" != "$out" ] && [ "$(starts)" = 0 ] && ok "CDP_WARM=0 -> per-call path" || bad "CDP_WARM=0: $out"

reset
for i in 1 2 3 4 5 6; do run >"$T/par.$i" 2>&1 & done; wait
n=$(cat "$T"/par.* | grep -c '^warm: bun /s/cdp.ts eval home 1+1$')
[ "$n" = 6 ] && [ "$(starts)" = 1 ] && ok "6 concurrent first callers share one container" || { bad "concurrent: $n warm, starts=$(starts)"; cat "$T"/par.*; }

reset
out=$(run FAKE_PID= 2>&1) rc=$?
[ $rc = 1 ] && [ "$(starts)" = 0 ] && ok "app not running: rc 1 as before" || bad "not running: rc=$rc"
out=$(run FAKE_ADB_RC=3 2>&1) rc=$?
[ $rc = 2 ] && ok "adb failure: rc 2 as before" || bad "adb fail: rc=$rc"

# 11-10 caches (e2e journeys hit their 450 s budgets on per-eval docker/adb calls): the forward and the ensure are
# reused within their windows; a dead endpoint (cdp.ts rc 3) re-forwards once and runs the call again.
reset
run CDP_FWD_CACHE_S=60 CDP_WARM_OK_S=30 >/dev/null
n0=$(grep -c '^inspect' "$T/d/log")
out=$(run CDP_FWD_CACHE_S=60 CDP_WARM_OK_S=30 CDP_ADB=/nonexistent) rc=$?
[ $rc = 0 ] && [ "$out" = "warm: bun /s/cdp.ts eval home 1+1" ] && [ "$(grep -c '^inspect' "$T/d/log")" = "$n0" ] \
  && ok "cached forward + ensure: no adb, no inspect on the next call" || bad "cache: rc=$rc out=$out inspects $n0 -> $(grep -c '^inspect' "$T/d/log")"
out=$(run CDP_FWD_CACHE_S=60 CDP_WARM_OK_S=30 FAKE_RC=3) rc=$?
[ "$(grep -c '^exec' "$T/d/log")" = 4 ] && ok "rc 3 (stale forward): re-forwarded and run once more" || bad "rc 3 retry: $(grep -c '^exec' "$T/d/log") execs"

# The container's idle loop exits only once no bun runs and the last call is old.
loop=$(bash -c '. "$1"; printf %s "$cdp_warm_loop"' _ "$ROOT/tools/phone/cdp-warm.sh")
grep -q 'readlink $p/exe' <<<"$loop" && grep -q 'IDLE' <<<"$loop" && ok "idle loop keyed on bun processes + last-call age" || bad "idle loop"

[ $fail = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
