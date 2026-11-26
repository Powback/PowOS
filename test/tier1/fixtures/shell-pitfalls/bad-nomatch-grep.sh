#!/bin/bash
# lint fixture: every grep below may match nothing; under set -e + pipefail the script then ends with no message
set -euo pipefail
changed=$(git status --porcelain | grep -v node_modules | sort)
n=$(grep -c TODO notes.txt)
grep -E '^(FAIL|ok)' gate.log | sort > /tmp/verdicts
r="kept $(echo "$first" | grep -o 'geom=[^ ]*') through fold"
cd /tmp && ls | grep -v '\.tmp$' | sort
find . -type f |
  grep -vE '^\./(dev|test)/' |
  sort
set +e
grep x f | sort
set -e
widgets=$(grep -l widget ./*.tsx | wc -l)
