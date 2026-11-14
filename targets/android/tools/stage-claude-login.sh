#!/bin/bash
# stage-claude-login.sh <dir> - claude-login's built ES module (dist/*.js: two plain files, no runtime dependencies) into
# <dir>, for both ways PowOS's code reaches a phone: the base image (build-rootfs.sh -> install-powos-android.sh) and the
# powos-core package (build-powos-core.sh), which is how an already installed phone gets it (the razr's 11-09 00:10 base
# predated claude-login in the image, and powos-core didn't carry it: "claude-login isn't installed", 11-14).
# Source: CLAUDE_LOGIN_DIR (default ~/Projects/claude-login) when it has dist/cli.js, else github.com/Powback/claude-login
# (private: this host's git credentials) cloned and built in a temporary folder. Exit 1 when neither works.
set -euo pipefail
dest=${1:?usage: stage-claude-login.sh <dir>}
CL=${CLAUDE_LOGIN_DIR:-$HOME/Projects/claude-login}
if [ ! -s "$CL/dist/cli.js" ]; then
  [ -n "${CLAUDE_LOGIN_NO_CLONE:-}" ] && { echo "stage-claude-login: no $CL/dist/cli.js" >&2; exit 1; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/claude-login.XXXXXX"); trap 'rm -rf "$t"' EXIT
  CL=$t/claude-login
  git clone -q --depth 1 https://github.com/Powback/claude-login "$CL" && (cd "$CL" && npm ci --silent && npx tsc) ||
    { echo "stage-claude-login: couldn't build github.com/Powback/claude-login" >&2; exit 1; }
fi
[ -s "$CL/dist/cli.js" ] || { echo "stage-claude-login: no dist/cli.js in $CL" >&2; exit 1; }
mkdir -p "$dest" && cp "$CL"/dist/*.js "$dest/"
