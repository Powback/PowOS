#!/usr/bin/env bash
# Experiment 1: waypipe window remoting on .58 (two containers, tc netem between them). One command:
#   tools/research/remoting/run-waypipe.sh                    # the full matrix below -> results/waypipe.jsonl
#   tools/research/remoting/run-waypipe.sh firefox gpu 3,2,1  # one run: APP MODE NET (NET = none | delay,jitter,loss)
# Builds the image on the job machine (POW_JOB_CONTEXT, default pow58), starts comp+app, runs, keeps the containers
# up for the next call; tools/research/remoting/cleanup.sh removes them. Report: report.py.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); dc="$here/dc"; res="$here/results"; mkdir -p "$res"
"$dc" build comp >/dev/null
"$dc" up -d comp app >/dev/null 2>&1
nets="none 3,2,0 3,2,1 8,4,0 8,4,1"
settle() { case $1 in firefox) echo 25 ;; *) echo 12 ;; esac; }
run_one() {
  local app=$1 mode=$2 net=$3 where=app
  [ "$mode" = local ] && where=comp
  echo "== $app $mode $net" >&2
  "$dc" exec -T comp net-set "$net" >/dev/null; "$dc" exec -T app net-set "$net" >/dev/null
  "$dc" exec -T -u u comp comp-start "$mode" >&2
  "$dc" exec -T -u u app sh -c 'rm -f /tmp/run/net.txt'
  "$dc" exec -T -u u $where app-start "$mode" "$app" >&2
  "$dc" exec -T -u u comp rm-drive.py "$app" "$(settle "$app")" >&2
  "$dc" exec -T -u u $where app-stop || true
  [ "$mode" = local ] || "$dc" exec -T app cat /tmp/run/net.txt | "$dc" exec -T comp sh -c 'cat > /tmp/run/net.txt'
  "$dc" exec -T comp rm-analyze.py app="$app" mode="$mode" net="$net" | tee -a "$res/waypipe.jsonl"
  "$dc" exec -T comp net-set none >/dev/null; "$dc" exec -T app net-set none >/dev/null
}
if [ $# -ge 3 ]; then run_one "$@"; exit; fi
for app in firefox kate dolphin; do
  run_one $app local none
  case $app in
    firefox) modes="shm gpu video-stock video" ;; kate) modes="shm gpu" ;; dolphin) modes="gpu" ;;
  esac
  for mode in $modes; do for net in $nets; do run_one $app $mode $net; done; done
done
