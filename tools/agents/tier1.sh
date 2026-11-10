#!/usr/bin/env bash
# tools/agents/tier1.sh [test-name...] — one command to run test/tier1/run-all.sh (or matching tests) in a correct
# container, from any checkout.
#
# WHY: test/tier1/run-all.sh needs bash 4+ (declare -A, mapfile); the Mac's own /bin/bash is 3.2 and fails before a
# single test runs (friction f84). And the Mac's VM is the fleet's busiest CPU: ship-step tests timed out there only.
# So this is the tier1 job of tools/jobs/compose.yml (tools/jobs/job.sh): this checkout's working state (tracked +
# modified + untracked-not-ignored files) baked into an image on the Docker context POW_JOB_CONTEXT names (default
# pow58: .58; not answering within 5 s -> the hub, said so), run-all.sh run in it, its output here, its exit ours.
#
# Usage:
#   tools/agents/tier1.sh                 # full tier-1 suite
#   tools/agents/tier1.sh test-land.sh    # just the matching test(s) - substring filter, run-all.sh's own
#   tools/agents/tier1.sh --rebuild       # rebuild the image's deps layer too (after editing tools/jobs/tier1.Dockerfile)
#   POW_JOB_CONTEXT=colima tools/agents/tier1.sh   # on the hub (the Mac's Colima VM)
#
# Gotchas baked in (friction f84, f122): SHELL=/bin/bash in the container (script -qec fixtures fall back to dash
# otherwise, mangling $'...'). The job has its machine's engine socket (compose.yml): the docker-using tests (complexity's detekt/clippy
# lints, loopback-unix, publish-repo) run in it, their containers siblings of the job (tools/jobs/docker-sibling.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../jobs/job.sh"
ARGS=()
for a in "$@"; do
  case "$a" in
    --rebuild) export JOB_NO_CACHE=1 ;;
    *)         ARGS+=("$a") ;;
  esac
done
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "tier1.sh: cd into a PowOS checkout (any worktree) first" >&2; exit 1; }
t0=$(date +%s)
job_init tier1
src=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-jobs-src.XXXXXX")
trap 'job_cleanup; rm -rf "$src"' EXIT
trap 'exit 130' INT TERM HUP
job_stage "$src" || { echo "tier1.sh: staging the source failed" >&2; exit 2; }
job_build tier1 "$src" || exit 2
tb=$(date +%s)
set +e
job_run tier1 -- ${ARGS[@]+"${ARGS[@]}"}
rc=$?
echo "tier1.sh: exit $rc on $JOB_CTX in $(( $(date +%s) - t0 )) s (build $(( tb - t0 )) s)" >&2
exit $rc
