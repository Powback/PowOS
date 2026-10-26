#!/usr/bin/env bash
# tools/agents/tier1.sh [test-name...] — one command to run test/tier1/run-all.sh (or matching tests) in a
# correct container, from the Mac.
#
# WHY: test/tier1/run-all.sh needs bash 4+ (declare -A, mapfile); the Mac's own /bin/bash is 3.2 and fails
# before a single test runs (friction f84). This builds/reuses a small ubuntu:24.04 image (bash, python3,
# jq, shellcheck, git, tmux, node>=22.18), cached as `powos-tier1:latest`, and runs run-all.sh inside it,
# printing its summary.
#
# Usage:
#   tools/agents/tier1.sh                 # full tier-1 suite
#   tools/agents/tier1.sh test-land.sh    # just the matching test(s) - substring filter, run-all.sh's own
#   tools/agents/tier1.sh --rebuild       # force-rebuild the cached image (after editing Dockerfile.tier1)
#   TIER1_DOCKER=0 tools/agents/tier1.sh  # skip mounting the docker socket even for the full suite
#
# Gotchas baked in here so nobody re-learns them (friction f84, f108, f113, f122, f163, f185):
#   - the Mac's bash 3.2 can't run run-all.sh at all - that's the whole reason this wrapper exists (f84).
#   - a worktree's .git is a FILE pointing at <main-repo>/.git/worktrees/<name> (absolute path) - mount the
#     worktree root AND its main repo's real .git dir (git rev-parse --git-common-dir), both at the SAME
#     absolute path inside the container as on the host, or the worktree's gitdir pointer 404s inside
#     (f108, f113).
#   - SHELL must be /bin/bash inside the container: some tier-1 fixtures use `script -qec "..." /dev/null`,
#     and without $SHELL=/bin/bash that falls back to dash, which mangles $'...' ANSI-C-quoted fixtures
#     (f122).
#   - the Colima docker socket is mounted ONLY when a test in this run needs it (test-complexity.sh's Kotlin/
#     Rust clippy lints shell out to `docker run`; nothing else does) - auto-detected below, override with
#     TIER1_DOCKER=1/0. Mount /var/run/docker.sock - the socket's real path INSIDE the Colima VM (where
#     `docker run` containers actually execute), not the Mac-side relay path `docker context inspect` prints
#     on the Mac (~/.colima/default/docker.sock) - that path isn't present in the VM's filesystem at all and
#     fails to mount. Once mounted, remember any `-v host:...` a test passes to that NESTED `docker run`
#     resolves `host:` against the VM's own filesystem (f163) - host-absolute paths (which is exactly what
#     the mounts below use, since we mount the worktree/.git at the SAME absolute path) are what nest
#     correctly.
#   - everything mounted must live under $HOME - Colima only shares $HOME into the VM, so a worktree or
#     repo outside it (e.g. under /tmp or /private) can't be mounted at all (f185).

set -euo pipefail

IMAGE=powos-tier1:latest
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$HERE/Dockerfile.tier1"

REBUILD=false
ARGS=()
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=true ;;
    *)         ARGS+=("$a") ;;
  esac
done

# Resolve from CWD, like worktree.sh/land.sh do - never from $0 (worktree.sh's f124 note applies here too:
# $0 is wherever this script's bytes happen to sit, not necessarily the worktree you want to test).
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) ||
  { echo "tier1.sh: cd into a PowOS checkout (any worktree) first" >&2; exit 1; }
GCD=$(git rev-parse --path-format=absolute --git-common-dir)

case "$TOPLEVEL" in
  "$HOME"/*) ;;
  *) echo "tier1.sh: $TOPLEVEL is outside \$HOME - Colima only shares \$HOME into the VM, so it can't be mounted (friction f185)" >&2; exit 1 ;;
esac
case "$GCD" in
  "$HOME"/*) ;;
  *) echo "tier1.sh: $GCD is outside \$HOME - Colima only shares \$HOME into the VM, so it can't be mounted (friction f185)" >&2; exit 1 ;;
esac

MOUNTS=(-v "$TOPLEVEL:$TOPLEVEL")
# A worktree's .git FILE points at an absolute path under the main repo's real .git dir - mount that too, at
# the same absolute path, or the pointer 404s inside the container (f108, f113). A plain (non-worktree)
# checkout has GCD == $TOPLEVEL/.git, already covered by the mount above.
if [ "$GCD" != "$TOPLEVEL/.git" ]; then
  MOUNTS+=(-v "$GCD:$GCD")
fi

# Most tier-1 tests never touch docker; mount the Colima socket only when the selected test(s) need it
# (currently just test-complexity.sh - its Kotlin/Rust lints run clippy/detekt via `docker run`). Full-suite
# runs (no filter) include it, so they need the socket too. TIER1_DOCKER=1/0 overrides the auto-detect.
NEED_DOCKER=false
if [ "${#ARGS[@]}" -eq 0 ]; then
  NEED_DOCKER=true
else
  for a in "${ARGS[@]}"; do
    case "$a" in *complexity*) NEED_DOCKER=true ;; esac
  done
fi
case "${TIER1_DOCKER:-}" in 1) NEED_DOCKER=true ;; 0) NEED_DOCKER=false ;; esac

HOME_ENV=()
if $NEED_DOCKER; then
  MOUNTS+=(-v /var/run/docker.sock:/var/run/docker.sock)
  # The docker-using lints (targets/android/lint-complexity.sh, tools/lint/rust-complexity.sh) cache into
  # $HOME/.cache and hand that path to a NESTED `docker run -v` of their own. That nested mount resolves
  # against the VM, same as the f163 note above - so our own container's $HOME must equal the Mac's real
  # $HOME (mounted at that same absolute path), not the container-default /root, or the nested sibling
  # writes into a disconnected, unmounted directory on the VM that we never see back ("detekt didn't run").
  mkdir -p "$HOME/.cache"
  MOUNTS+=(-v "$HOME/.cache:$HOME/.cache")
  HOME_ENV=(-e "HOME=$HOME")
fi

if $REBUILD || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "tier1.sh: building $IMAGE (one-time; cached after this) ..." >&2
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$HERE" >&2
fi

exec docker run --rm \
  "${MOUNTS[@]}" \
  -e SHELL=/bin/bash \
  ${HOME_ENV[@]+"${HOME_ENV[@]}"} \
  -w "$TOPLEVEL" \
  "$IMAGE" \
  bash test/tier1/run-all.sh ${ARGS[@]+"${ARGS[@]}"}
