#!/usr/bin/env bash
# Remove this measurement's containers, network and images from the job machine (results/ stay in the repo).
# Images: the tagged localhost/rmm/remoting plus the untagged build stages of this Dockerfile only (identified by
# its own steps in the image history); nothing else on the machine is pruned, shared build caches stay.
here=$(cd "$(dirname "$0")" && pwd); ctx=${POW_JOB_CONTEXT:-pow58}
"$here/dc" --profile criu down --remove-orphans -t 2
docker --context "$ctx" rmi localhost/rmm/remoting:latest >/dev/null 2>&1 || true
for i in $(docker --context "$ctx" images -a --filter dangling=true -q | sort -u); do
  h=$(docker --context "$ctx" history --no-trunc --format '{{.CreatedBy}}' "$i" 2>/dev/null | tr '\n' ' ') || continue
  case $h in *waypipe-v0.11.3*|*powos-research/1.0*|*"sway waypipe wtype"*) echo "$i" ;; esac
done | xargs -r docker --context "$ctx" rmi -f >/dev/null 2>&1 || true
echo "cleaned"
