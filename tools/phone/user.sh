#!/bin/bash
# Run a local bash script inside PowOS on the phone AS THE SESSION USER (powos: its comms inbox, its spacetime token,
# its `powos ...`), output back here - root.sh's twin for what must not run as root:
#   tools/phone/user.sh ./mail.sh          (e.g. `powos comms send manager "..." --from pet`, `powos pet say ...`)
# Never `sudo` in it: through powos-run.sh that pops a password dialog on the user's screen.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); s=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); n=powos-user-$$.sh
"$here/adb.sh" push "$s" /data/local/tmp/$n >/dev/null
"$here/adb.sh" shell "su -c 'cp /data/local/tmp/$n /data/powos/root/tmp/$n && rm /data/local/tmp/$n && chmod 755 /data/powos/root/tmp/$n && sh /data/powos/powos-run.sh \"bash /tmp/$n\"; rc=\$?; rm -f /data/powos/root/tmp/$n; exit \$rc'"
