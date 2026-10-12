#!/bin/bash
# Fails when the Containerfile's `staging` stage copies a source that targets/android/layer.list
# neither copies (+) nor excludes (-), or when layer.list names a source that no longer exists there.
# Keeps the phone build in step with the desktop/Deck image without touching the Containerfile.
set -euo pipefail
cd "$(dirname "$0")/../.."

# COPY sources of the staging stage: from "FROM scratch AS staging" to the next FROM.
staging=$(awk '/^FROM scratch AS staging/{s=1;next} s&&/^FROM /{exit} s&&/^COPY /{print $2}' Containerfile | sort -u)
listed=$(awk '/^[+-] /{print $2}' targets/android/layer.list | sort -u)

missing=$(comm -23 <(echo "$staging") <(echo "$listed"))
stale=$(comm -13 <(echo "$staging") <(echo "$listed"))
rc=0
if [ -n "$missing" ]; then
  echo "layer.list does not account for these Containerfile staging sources (add as + or - with a reason):"
  echo "$missing" | sed 's/^/  /'
  rc=1
fi
if [ -n "$stale" ]; then
  echo "layer.list names sources the Containerfile staging stage no longer copies:"
  echo "$stale" | sed 's/^/  /'
  rc=1
fi
[ $rc = 0 ] && echo "layer.list in step with Containerfile staging ($(echo "$staging" | wc -l | tr -d ' ') sources)"
exit $rc
