#!/bin/bash
# Copy evidence from PowOS's root (/data/powos/root) to the Mac, e.g. a screenshot or steps.txt a check wrote:
#   tools/phone/pull-root.sh home/powos/design-qa/e2e-appapi/r1 ~/evidence/
# adb pull is denied on /data/powos/root, so: su cp to a temp dir under /data/local/tmp, adb pull from there, rm it.
# <path> is relative to /data/powos/root (a leading /data/powos/root/ is accepted); no '..'. <mac-dest-dir> is created.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ $# -eq 2 ] || { echo "usage: pull-root.sh <path-under-/data/powos/root> <mac-dest-dir>" >&2; exit 2; }
src=${1#/}; src=${src#data/powos/root/}; src=${src%/}
case "$src" in ""|*..*) echo "pull-root.sh: bad path: $1" >&2; exit 2 ;; esac
dest=$2; mkdir -p "$dest"
tmp=/data/local/tmp/powos-pull-$$
rc=0
"$here/adb.sh" shell "su -c 'rm -rf $tmp && mkdir -p $tmp && cp -r /data/powos/root/$src $tmp/ && chmod -R a+rX $tmp'" || rc=$?
[ $rc -eq 0 ] && { "$here/adb.sh" pull "$tmp/$(basename "$src")" "$dest/" || rc=$?; }
"$here/adb.sh" shell "su -c 'rm -rf $tmp'" >/dev/null || true
exit $rc
