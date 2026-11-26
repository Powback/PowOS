#!/bin/bash
# The gate's slots (dev/gate.sh), with stub gates (GATE_STUB_SLEEP: hold the slot, no docker): 3 agents (2 run, 1
# waits), a ship gate jumping in (never waits; agents wait while it runs), a dead pid's slot reclaimed, the slot count by the job machine. ~25 s.
set -uo pipefail
G=$(cd "$(dirname "$0")" && pwd)/gate.sh
export XDG_CACHE_HOME; XDG_CACHE_HOME=$(mktemp -d); trap 'rm -rf "$XDG_CACHE_HOME"' EXIT
export GATE_SLOT_POLL_S=0.2 GATE_SLOTS=2 GATE_SHIP_EXCLUSIVE=1   # the pre-2026-10-28 behaviour, which this test pins
S=$XDG_CACHE_HOME/powos-gate/slots L=$XDG_CACHE_HOME/log
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=1; fi; }
gate() { GATE_STUB_SLEEP=$2 GATE_PRIORITY=${3:-} bash "$G" > "$L.$1" 2>&1 & }
started() { grep -q ' start$' "$L.$1"; }
# settle LOG...: until each gate has said it started or is waiting (10 s at most) - fixed sleeps failed at Mac load 40+.
settle() { local i f n; for i in $(seq 100); do n=0
  for f in "$@"; do grep -qE ' start$|waiting for a slot' "$L.$f" 2>/dev/null || n=1; done
  [ $n = 0 ] && return; sleep 0.1; done; }
n_agent() { ls -d "$S"/agent.* 2>/dev/null | wc -l | tr -d ' '; }

# 1. Three agents: two run, the third waits, then runs.
gate a1 4; gate a2 4; gate a3 2; settle a1 a2 a3
ok "3 agents: 2 hold slots" '[ "$(n_agent)" = 2 ]'
ok "3 agents: one waits, says so" '[ "$(grep -l "waiting for a slot (2 running" "$L".a* | wc -l | tr -d " ")" = 1 ]'
wait
ok "3 agents: all three ran" 'started a1 && started a2 && started a3'
ok "slots released" '[ -z "$(ls "$S")" ]'
rm -f "$L".*

# 2. A ship gate jumps in: starts at once beside two agents; a new agent waits until it ends.
gate b1 2; gate b2 2; settle b1 b2
gate ship 4 ship; settle ship
ok "ship: starts at once beside 2 agents" 'started ship'
gate b3 1; sleep 2.5   # b1, b2 done; the ship still runs
ok "ship: a new agent waits while it runs (free agent slots)" '! started b3 && [ "$(n_agent)" = 0 ]'
wait
ok "ship: the waiting agent ran after it" 'started b3'
rm -f "$L".*

# 3. Dead pids' slots are reclaimed.
mkdir -p "$S/agent.0" "$S/agent.1" "$S/ship.1"
bash -c 'exit 0' & dead=$!; wait $dead
for d in agent.0 agent.1 ship.1; do echo $dead > "$S/$d/pid"; done
gate c1 0.5; settle c1
ok "dead pid: an agent reclaims the slot at once" 'started c1 && ! grep -q waiting "$L.c1"'
wait
rm -f "$L".*

# 4. The slot count follows the gate job's machine (GATE_SLOTS unset): 6 when it answers, 2 on the hub.
fake=$XDG_CACHE_HOME/bin; mkdir -p "$fake"
printf '#!/bin/sh\nexit "${FAKE_DOCKER_RC:-0}"\n' > "$fake/docker"; chmod +x "$fake/docker"
slots_for() { (unset GATE_SLOTS; PATH=$fake:$PATH; export FAKE_DOCKER_RC=$1 POW_JOB_CONTEXT=$2
  for i in 1 2 3 4 5 6 7; do GATE_STUB_SLEEP=6 bash "$G" > "$L.d$i" 2>&1 & done; settle d1 d2 d3 d4 d5 d6 d7; n_agent; wait); }
ok "job machine answers: 6 agent slots" '[ "$(slots_for 0 pow58)" = 6 ]'
ok "job machine answers: the 7th waits, says 6 slots" 'grep -q "waiting for a slot (6 running, 6 agent slots)" "$L".d*'
rm -f "$L".*
ok "job machine down: 2 agent slots" '[ "$(slots_for 1 pow58)" = 2 ]'
ok "POW_JOB_CONTEXT=hub: 2 agent slots" '[ "$(slots_for 0 hub)" = 2 ]'
[ $fails = 0 ] && echo "gate-slots-test: pass" || echo "gate-slots-test: FAIL"
exit $fails
