#!/bin/bash
# test-shellcheck-ratchet.sh - tools/lint/shellcheck-ratchet.py: every tracked shell script is linted, the baseline
# (tools/lint/shellcheck-baseline.txt) holds old debt per file and code, and it only goes down.
#
# A throwaway git repo with the real script: a new finding fails, a file that got worse fails, frozen debt passes,
# a fixed finding fails until --prune, a raised baseline fails unless the commit says [baseline-reset], and
# extensionless scripts with a sh shebang are found while other interpreters are not. A removed file's entries are
# CI's full --check's ("paid off"), not this test's: the tier-1 image leaves some tracked dirs out.
# Needs shellcheck 0.9.0 (the tier-1 image) or docker; without either it skips, saying so.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

# Under the cache dir, not /tmp: on the Mac the docker shellcheck sees only the VM's shared folders.
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}"; T=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/test-shellcheck.XXXXXX"); trap 'rm -rf "$T"' EXIT
cd "$T" && git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p tools/lint bin
cp "$ROOT/tools/lint/shellcheck-ratchet.py" tools/lint/
R() { SHELLCHECK_BASELINE_REF=HEAD python3 tools/lint/shellcheck-ratchet.py "$@"; }
# SC2034 (warning): an unused variable. Style/info findings (SC2086 here) are not tracked.
printf '#!/bin/bash\nunused=1\necho $1\n' > a.sh
printf '#!/bin/sh\necho ok\n' > bin/tool
printf '#!/usr/bin/env python3\nprint(1)\n' > bin/py
git add -A && git commit -qm init

out=$(R --report 2>&1); rc=$?
if [ $rc = 2 ]; then echo "  skip - $out"; echo "PASS: 0  FAIL: 0"; exit 0; fi
echo "$out" | grep -q "in 1 of 2 files" && ok "finds *.sh and the extensionless sh script, not the python one" \
  || bad "file discovery: $out"
echo "$out" | grep -q "SC2034 1" && ! echo "$out" | grep -q SC2086 && ok "warning level: SC2034 counted, style SC2086 not" \
  || bad "severity: $out"

R --check >/dev/null 2>&1; [ $? = 1 ] && ok "no baseline: the existing finding fails" || bad "no baseline passed"
R --write >/dev/null && grep -q "^a.sh SC2034 1$" tools/lint/shellcheck-baseline.txt && ok "--write freezes a.sh SC2034 1" \
  || bad "--write: $(cat tools/lint/shellcheck-baseline.txt)"
git add -A && git commit -qm baseline
out=$(R --check 2>&1) && ok "frozen debt passes" || bad "frozen debt failed: $out"

printf '#!/bin/bash\nunused=1\nother=2\n' > a.sh
out=$(R --check 2>&1); [ $? = 1 ] && echo "$out" | grep -q "a.sh SC2034: 2 > baseline 1" && ok "a file that got worse fails" \
  || bad "worse file: $out"
printf '#!/bin/bash\nunused=1\n' > a.sh; printf '#!/bin/sh\nx=1\n' > bin/tool
out=$(R --check 2>&1); [ $? = 1 ] && echo "$out" | grep -q "bin/tool SC2034: new finding" && ok "a new finding fails" \
  || bad "new finding: $out"
out=$(R --check a.sh 2>&1) && ok "a file list checks only those files" || bad "file list: $out"
git checkout -q bin/tool

printf '#!/bin/bash\necho fixed\n' > a.sh
out=$(R --check 2>&1); [ $? = 1 ] && echo "$out" | grep -q "paid off (1 -> 0)" && ok "a fixed finding fails until pruned" \
  || bad "stale entry: $out"
R --prune >/dev/null && ! grep -q "^a.sh" tools/lint/shellcheck-baseline.txt && out=$(R --check 2>&1) \
  && ok "--prune drops it and the check passes" || bad "prune: $out"
git add -A && git commit -qm fixed

printf '#!/bin/bash\nunused=1\n' > a.sh; echo "a.sh SC2034 1" >> tools/lint/shellcheck-baseline.txt
git add -A && git commit -qm "raise"
out=$(SHELLCHECK_BASELINE_REF=HEAD^ python3 tools/lint/shellcheck-ratchet.py --check 2>&1)
[ $? = 1 ] && echo "$out" | grep -q "baseline rose: a.sh SC2034 0 -> 1" && ok "raising the baseline fails" || bad "raise: $out"
git commit -q --amend -m "raise [baseline-reset]: deliberate"
out=$(SHELLCHECK_BASELINE_REF=HEAD^ python3 tools/lint/shellcheck-ratchet.py --check 2>&1) \
  && ok "[baseline-reset] in the commit allows it" || bad "reset marker: $out"

out=$(GATE_LINT=0 R --check 2>&1); [ $? = 2 ] && ok "GATE_LINT=0 skips, saying so" || bad "GATE_LINT=0: $out"

echo "PASS: $PASS  FAIL: $FAIL"
[ $FAIL = 0 ]
