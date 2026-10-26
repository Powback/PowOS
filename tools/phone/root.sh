#!/bin/bash
# Run a local bash script as root INSIDE PowOS on the phone (chroot of /data/powos/root), output back here:
#   tools/phone/root.sh ./check.sh
# Never use `sudo` through powos-run.sh - it pops a password dialog on the user's screen. For the live session's
# environment (KWin, the user's apps) as the user instead: tools/phone/adb.sh shell su -c "sh /data/powos/powos-run.sh '<cmd>'"
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); s=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); n=powos-root-$$.sh
"$here/adb.sh" push "$s" /data/local/tmp/$n >/dev/null
"$here/adb.sh" shell "su -c 'cp /data/local/tmp/$n /data/powos/root/tmp/$n && rm /data/local/tmp/$n && chroot /data/powos/root /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root bash /tmp/$n; rc=\$?; rm -f /data/powos/root/tmp/$n; exit \$rc'"
