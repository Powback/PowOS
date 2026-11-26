#!/bin/bash
# lint fixture: none of these is a hit - the no-match status is handled, tested, or can't end the script
set -euo pipefail
changed=$(git status --porcelain | grep -v node_modules | sort || true)
n=$(grep -c TODO notes.txt || :)
grep -E '^(FAIL|ok)' gate.log | sort > /tmp/verdicts || true
git status --porcelain | { grep -v node_modules || true; } | sort
if git status --porcelain | grep -q '^ M'; then echo dirty; fi
git status --porcelain | grep -q '^ M' && echo dirty
if [ -d .git ] && git status --porcelain | grep -q '^ M'; then echo dirty; fi
! ps ax | grep -q '[s]leep 99'
while ps ax | grep -q '[s]leep 99'; do sleep 1; done
has_change() { git status --porcelain | grep -q "$1"; }
f() {
  local x=$(grep -o 'a=[0-9]*' f)
  echo "$x"
}
echo "found: $(grep -o 'a=[0-9]*' f | head -1)"
for w in $(grep -l widget ./*.tsx | sort); do echo "$w"; done
while read -r l; do echo "$l"; done < <(grep -v '^#' list.txt)
x=$(grep -c y f | sort; echo done)
grep TODO notes.txt
out=$(git log | grep fix | head -3) || out=
grep x f | sort # lint-ok: fixture escape on the line itself
cat <<EOT
grep x f | sort
EOT
set +e
grep x f | sort
set -e
