#!/bin/bash
# shellcheck disable=SC2034  # lint fixture: unused names are the point
# lint fixture: the same functions, each failure said or each call tested
set -euo pipefail
copy_in() {
  docker exec "$cid" find /work -mindepth 1 -delete || { echo "x: clearing /work failed" >&2; return 2; }
  tar -cf - . | docker exec -i "$cid" tar -xf - -C /work || return 2
}
validate() { [ -n "$1" ] || { echo "empty" >&2; return 1; }; }
run() { validate "$1" || return 1; echo "$1"; }   # a function of this file: it says why itself
copy_in || { echo "x: copy failed" >&2; exit 2; }
if copy_in; then echo ok; fi
run a
copy_in && echo ok
# lint-ok: silent-return - tar prints why
copy_in
set +e
