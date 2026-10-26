#!/usr/bin/env bash
# tools/lib/need-docker.sh: find `docker` even when `brew upgrade` unlinked it (f34, f35). A docker formula
# upgrade removes and relinks /opt/homebrew/bin/docker while it installs the new Cellar version; for the window
# in between (sometimes minutes, if the upgrade stalls or the user's away) `command -v docker` fails and the
# ship gate ("gate: no docker") and the pre-push Kotlin complexity lint ("FAIL kotlin complexity: no docker")
# both refuse, even though the real binary is sitting right there in the Cellar the whole time.
#
# Source this (it only defines a function + reads PATH, never execs anything):
#   . "$ROOT/tools/lib/need-docker.sh"
#   need_docker || exit 1   # (or whatever exit code / message fits the caller)
#
# need_docker: 0 once `docker` resolves on PATH, after prepending the first known location that has it if a
# plain `command -v docker` didn't already find one. 1 (with a one-line fix on stderr) if it's nowhere at all -
# the caller decides what that means for its own exit code.
need_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  local p
  for p in /opt/homebrew/bin/docker /usr/local/bin/docker "$HOME/.colima/bin/docker" /opt/homebrew/Cellar/docker/*/bin/docker; do
    [ -x "$p" ] || continue
    PATH="$(dirname "$p"):$PATH"
    export PATH
    command -v docker >/dev/null 2>&1 && return 0
  done
  echo "need-docker: no docker CLI found (checked PATH, /opt/homebrew/bin, /usr/local/bin, ~/.colima/bin," \
       "/opt/homebrew/Cellar/docker/*/bin)." >&2
  echo "need-docker: fix: brew link docker   (a 'brew upgrade docker' unlinks it from /opt/homebrew/bin while" \
       "it relinks - this is that gap; the binary itself is still in the Cellar)" >&2
  return 1
}
