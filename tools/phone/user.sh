#!/bin/bash
# Run a local bash script inside PowOS on the phone AS THE SESSION USER (powos: its comms inbox, its spacetime token,
# its `powos ...`), output back here - root.sh's twin for what must not run as root:
#   tools/phone/user.sh ./mail.sh          (e.g. `powos comms send manager "..." --from pet`, `powos pet say ...`)
# Never `sudo` in it: through powos-run.sh that pops a password dialog on the user's screen.
# One adb call: the script goes over the shell's stdin (cat > file), not `adb push` - a push of a file outside $HOME
# (mktemp's, ww-lib's ww_us) goes through a throwaway container (adb.sh: docker create + cp + start), ~1.7 s of the
# ~3 s each call cost; the checks make dozens (docs/research/verify-queue-speed.md, 11-10). The script's own stdin is
# empty (it was the caller's; no caller passes any).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); s=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); n=powos-user-$$.sh
"$here/adb.sh" shell "su -c 'cat > /data/powos/root/tmp/$n && chmod 755 /data/powos/root/tmp/$n && sh /data/powos/powos-run.sh \"bash /tmp/$n\" </dev/null; rc=\$?; rm -f /data/powos/root/tmp/$n; exit \$rc'" < "$s"
