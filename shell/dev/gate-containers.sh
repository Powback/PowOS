# The gate's local containers (f411): every `docker run` of dev/gate.sh and dev/preview.sh goes through these, so no
# Chromium container outlives the gate that started it - whatever kills the gate.
#  - --init: docker's init is PID 1 and reaps; without it a killed Chromium tree left a zombie PID 1 that `docker
#    stop` could not kill ("PID is zombie and can not be killed. Use the --init option").
#  - labels: powos-gate (all of them), powos-gate-run (this run, killed by the gate's EXIT trap), powos-gate-pid +
#    powos-gate-host (the gate's pid): a gate SIGKILLed past its traps leaves its containers to the next gate's start,
#    which removes every powos-gate container whose gate pid is gone (gc_reap).
#  - a hard cap inside the container: `timeout -s KILL` around the command, GATE_RUN_MS + 60 s, so it ends even if
#    everything outside it died (gate, its trap, the next gate never starting).
# Sourced; needs $$ of the gate (GATE_PARENT_PID is exported for dev/preview.sh run under it).
export GATE_PARENT_PID=${GATE_PARENT_PID:-$$}
export GATE_RUN_LABEL=${GATE_RUN_LABEL:-"powos-gate-run=$GATE_PARENT_PID-$(date +%s)"}
gc_host=$(hostname -s 2>/dev/null || hostname)
gc_cap_s=$(( ${GATE_RUN_MS:-900000} / 1000 + 60 ))
# `docker run "${gc_flags[@]}" ... --entrypoint timeout IMAGE "${gc_cap[@]}" node x.mjs`
gc_flags=(--init --stop-timeout 5 --label powos-gate=1 --label "$GATE_RUN_LABEL"
  --label "powos-gate-pid=$GATE_PARENT_PID" --label "powos-gate-host=$gc_host")
gc_cap=(-s KILL "$gc_cap_s")
# This run's containers.
gc_kill() { local ids; ids=$(docker ps -aq --filter "label=$GATE_RUN_LABEL" 2>/dev/null) || ids=""; [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1 || true; }
# Orphans: a powos-gate container of this host whose gate pid is no longer alive. Never touches anything unlabelled.
gc_reap() {
  local id pid host dead=""
  while read -r id pid host; do
    [ -n "$id" ] && [ "$host" = "$gc_host" ] && [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || dead+="$id "
  done < <(docker ps -a --filter label=powos-gate --format '{{.ID}} {{.Label "powos-gate-pid"}} {{.Label "powos-gate-host"}}' 2>/dev/null || true)
  [ -z "$dead" ] || { echo "gate: removing orphaned gate container(s) $dead(their gate is gone)"; docker rm -f $dead >/dev/null 2>&1 || true; }
  return 0
}
