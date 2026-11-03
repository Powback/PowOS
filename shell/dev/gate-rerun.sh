# shellcheck shell=bash
# gate.sh's rerun policy (sourced; test/tier1/test-gate-rerun.sh drives it with fake scene results).
#
# The full run starts ~300 scenes in parallel browsers; under Mac load 2-7 of them fail nearly every run and pass when
# run alone (11-02/03: 6 of 6 ship batches - switcher-home-swipe-*, one-bar-unfolded, term-scroll, ...), and the
# coordinator reran them by hand each time. So after the full run every failed scene is rerun ALONE (its own browser
# run, nothing else in it; same tree, same build) up to GATE_RERUN times (default 2):
#   - passes alone every time -> "FLAKY (passed alone 2/2)": it does not fail the gate, it is written to the flake
#     ledger (GATE_FLAKE_LEDGER, default ~/.cache/powos-gate/flakes.jsonl: scene, failure text, date, rerun results)
#     and named in the summary ("N flaky");
#   - fails alone even once -> FAIL, as before.
# GATE_RERUN=0 turns it off (gate.sh then keeps its older load-only retry). More than GATE_RERUN_MAX (default 10)
# failed scenes is a real break, not load: none are rerun.
#
# The caller defines gate_rerun_run REGEX LOG: one browser run of only the scenes REGEX names, its output in LOG, its
# exit status returned.

gr_failed_names() { grep '^FAIL ' "$1" 2>/dev/null | sed 's/^FAIL \([^:]*\):.*/\1/' | sort -u; }

# A scene's GATE_ONLY: its name literally, plus its "-launcher" companion page (as the load-only retry did).
gr_scene_re() { printf '%s' "$1" | sed 's/[][\.*+?^${}()|]/\\&/g; s/^/^(/; s/$/)(-launcher)?$/'; }

# One rerun's result: passed only if the run exited 0 and reported the scene ok.
gr_result() { [ "$1" = 0 ] && grep -qF "ok   $2 (" "$3" && echo pass || echo fail; }

# The verdict over a scene's rerun results ("pass pass" / "pass fail" / "fail"): flaky only if every one of the
# wanted N passed.
gr_verdict() {
  local want=$1; shift
  local n=0 r
  for r in "$@"; do [ "$r" = pass ] || { echo fail; return; }; n=$((n + 1)); done
  [ "$n" -ge "$want" ] && echo flaky || echo fail
}

gr_ledger() {   # scene failure-text results...
  local f=${GATE_FLAKE_LEDGER:-${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/flakes.jsonl}
  mkdir -p "$(dirname "$f")"
  python3 - "$f" "$@" <<'PY' || true
import json, sys, time, os
f, scene, failure, *results = sys.argv[1:]
row = {"date": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "scene": scene, "failure": failure[:1000], "reruns": results,
       "load": os.environ.get("GR_LOAD", ""), "throttle": os.environ.get("GATE_THROTTLE", ""),
       "priority": os.environ.get("GATE_PRIORITY", "agent"), "tree": os.environ.get("GR_TREE", ""),
       "head": os.environ.get("GR_HEAD", "")}
with open(f, "a") as o: o.write(json.dumps(row) + "\n")
PY
}

# gate_rerun FULL_LOG WORKDIR: rerun every scene that failed in FULL_LOG alone; WORKDIR/flaky.txt lists the flaky ones.
# Returns 0 when every failed scene came out flaky, 1 otherwise.
gate_rerun() {
  local log=$1 dir=$2 want=${GATE_RERUN:-2} max=${GATE_RERUN_MAX:-10}
  local names n i k=0 rc res verdict results text bad=0
  : > "$dir/flaky.txt"
  names=$(gr_failed_names "$log")
  [ -n "$names" ] || return 1
  if [ "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" -gt "$max" ]; then
    echo "gate: rerun: $(printf '%s\n' "$names" | wc -l | tr -d ' ') scenes failed (> GATE_RERUN_MAX $max): a real break, none rerun"
    return 1
  fi
  echo "gate: rerun: $(printf '%s\n' "$names" | paste -sd' ' -) failed in the full run - each rerun alone, up to $want time(s)"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    k=$((k + 1)) results=()
    for i in $(seq 1 "$want"); do
      echo "gate: rerun: $n alone ($i/$want)"
      gate_rerun_run "$(gr_scene_re "$n")" "$dir/rerun.$k.$i.log"; rc=$?
      res=$(gr_result "$rc" "$n" "$dir/rerun.$k.$i.log")
      results+=("$res")
      [ "$res" = pass ] || break
    done
    verdict=$(gr_verdict "$want" "${results[@]}")
    if [ "$verdict" = flaky ]; then
      echo "gate: rerun: $n FLAKY (passed alone $want/$want) - not a FAIL, in the flake ledger"
      printf '%s\n' "$n" >> "$dir/flaky.txt"
      text=$(grep -F "FAIL $n: " "$log" | head -5 | sed "s/^FAIL $n: //" | paste -sd'|' -)
      gr_ledger "$n" "$text" "${results[@]}"
    else
      echo "gate: rerun: $n FAIL (failed alone on rerun ${#results[@]}: ${results[*]})"
      grep -h '^FAIL ' "$dir/rerun.$k.${#results[@]}.log" 2>/dev/null | head -5 | sed 's/^/     alone: /'
      bad=1
    fi
  done <<< "$names"
  return $bad
}
