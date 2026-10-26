#!/bin/bash
# test-hack-registry.sh - every HACK marker in the tree is listed in the registry (docs/REMOTE-POWOS.md §4).
#
# The rule (CLAUDE.md): a workaround is marked "HACK" + colon at the spot, with why and the real fix, and the
# commit that adds, moves or removes one updates the registry table in the same commit. Without a check the table
# rots the week it is written, so: per file, the number of markers in the tree must equal the number of registry rows
# naming that file. Counts, not line numbers: other edits move lines all the time, and a test that failed on every
# unrelated edit above a marker would be turned off.
#
# Scanned: tracked files (git grep; uncommitted new files are someone's work in progress). Not scanned: vendored code
# (targets/web/third_party/), the registry itself, this file. A mention of the convention in backticks is not a
# marker.
#
# Usage:  bash test/tier1/test-hack-registry.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REG=docs/REMOTE-POWOS.md

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

cd "$ROOT" || { echo "cannot cd to $ROOT"; exit 1; }

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "  skip - not a git checkout"
    echo ""
    echo "== Results: 0 passed, 0 failed =="
    exit 0
fi

echo "== HACK registry ($REG) =="

if [[ ! -f "$REG" ]] || ! grep -q '<!-- hack-registry:start -->' "$REG"; then
    bad "$REG has no registry section (<!-- hack-registry:start --> ... end)"
    echo ""
    echo "== Results: $PASS passed, $FAIL failed =="
    exit 1
fi

TAG='HACK'':'   # split so this file's own source never looks like a marker
tree=$(git grep -n -F "$TAG" -- . ':(exclude)targets/web/third_party' ":(exclude)$REG" \
        ':(exclude)test/tier1/test-hack-registry.sh' 2>/dev/null \
        | grep -v -F "\`$TAG\`" | cut -d: -f1 | sort | uniq -c | awk '{print $2" "$1}')
listed=$(sed -n '/<!-- hack-registry:start -->/,/<!-- hack-registry:end -->/p' "$REG" \
        | sed -n 's/^| `\([^`]*\):[0-9][0-9]*` |.*/\1/p' | sort | uniq -c | awk '{print $2" "$1}')

n_tree=$(echo "$tree" | awk 'NF{s+=$2} END{print s+0}')
n_listed=$(echo "$listed" | awk 'NF{s+=$2} END{print s+0}')

problems=$(join -a1 -a2 -e 0 -o 0,1.2,2.2 <(echo "$tree") <(echo "$listed") | awk '$2 != $3')
if [[ -z "$problems" ]]; then
    ok "$n_tree markers in the tree, $n_listed rows in the registry, every file's count matches"
else
    while read -r f t l; do
        [[ -n "$f" ]] || continue
        if (( t > l )); then
            bad "$f: $t marker(s) in the tree, $l in the registry - add a row per new marker to $REG §4"
        else
            bad "$f: $l registry row(s), $t marker(s) in the tree - remove the stale row(s) from $REG §4"
        fi
    done <<< "$problems"
fi

missing=""
while read -r f _; do
    [[ -n "$f" ]] || continue
    [[ -e "$f" ]] || missing="$missing $f"
done <<< "$listed"
if [[ -z "$missing" ]]; then
    ok "every file the registry names exists"
else
    for f in $missing; do bad "registry names $f, which doesn't exist (moved? update the row)"; done
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
