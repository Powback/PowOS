#!/bin/bash
# test-bin-executable.sh - every shipped script in bin/ must be executable.
#
# Containerfile does `COPY bin/ /usr/bin/`, which preserves the source mode. A
# script committed 100644 therefore lands in /usr/bin non-executable, and any
# systemd unit whose ExecStart points at it fails with EACCES at boot — while
# the file is visibly present, which makes it look like a unit problem.
#
# This was not hypothetical: powos-install-wizard (the guided installer),
# powos-firstboot-apply, powos-firstboot-disk, powos-safemode and five others
# all shipped non-executable.
#
# Checks the GIT INDEX mode, not the working tree: a local chmod is not what
# gets built, the committed mode is.
#
# Usage:  bash test/tier1/test-bin-executable.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

cd "$ROOT" || { echo "cannot cd to $ROOT"; exit 1; }

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "  skip - not a git checkout (mode is only meaningful in the index)"
    echo ""
    echo "== Results: 0 passed, 0 failed =="
    exit 0
fi

echo "== bin/ file modes =="

non_exec=$(git ls-files -s bin/ | awk '$1=="100644"{print $4}')
if [[ -z "$non_exec" ]]; then
    ok "every file in bin/ is committed executable (100755)"
else
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        bad "$f is committed 100644 — will land in /usr/bin non-executable"
    done <<< "$non_exec"
    echo "         fix: git update-index --chmod=+x <file>"
fi

# Anything with a shebang is meant to be run; catch a file that is executable
# but somehow lost its interpreter line too.
echo ""
echo "== bin/ shebangs =="
missing=""
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -f "$f" ]] || continue
    head -1 "$f" | grep -q '^#!' || missing="$missing $f"
done < <(git ls-files bin/)
if [[ -z "$missing" ]]; then
    ok "every file in bin/ starts with a shebang"
else
    for f in $missing; do bad "$f has no shebang"; done
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
