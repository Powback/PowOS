#!/bin/bash
# shellcheck disable=SC2034  # lint fixture: unused names are the point
# lint fixture: each call below can end the set -e script with status 2 and no message (preview.sh 11-27)
set -euo pipefail
copy_in() {
  docker exec "$cid" find /work -mindepth 1 -delete || return 2
  tar -cf - . | docker exec -i "$cid" tar -xf - -C /work || return 2
}
pass() { # fails as silently: its last command is copy_in's
  copy_in; return
}
slot_take() { mkdir "$1" 2>/dev/null || return 1; slot=$1; }
copy_in
pass plan; echo "plan done"
if [ -n "${x:-}" ]; then pass measure; fi
slot_take /tmp/slot
