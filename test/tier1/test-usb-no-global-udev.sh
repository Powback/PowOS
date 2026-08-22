#!/bin/bash
# The USB writer must never re-trigger udev for the WHOLE system.
#
# A bare `udevadm trigger --subsystem-match=block` re-triggers every block
# device on the machine. The desktop automounter then mounts unrelated disks —
# on a live desktop that meant six duplicate mounts of the running system's own
# ROOT partition, which broke systemd's mount namespacing: systemd-timedated
# and systemd-hostnamed both died with "/etc: No such file or directory",
# taking NTP and the clock with them. Writing a USB stick must not be able to
# do that to the machine doing the writing.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$ROOT/build/install-to-usb.sh"
P=0; FAIL=0
ok(){ echo -e "\033[0;32m✓\033[0m $1"; P=$((P+1)); }
bad(){ echo -e "\033[0;31m✗\033[0m $1"; [[ -n "${2:-}" ]] && echo "    $2"; FAIL=$((FAIL+1)); }

# Join backslash-continued lines first: the flags of a multi-line invocation
# belong to the same logical command, and checking raw lines would report a
# correctly-scoped call as unscoped.
while IFS= read -r cmd; do
    [[ "$cmd" =~ udevadm[[:space:]]+trigger ]] || continue
    if [[ "$cmd" == *"--sysname-match"* ]]; then
        ok "udevadm trigger is scoped to the target device"
    else
        bad "unscoped 'udevadm trigger' would re-probe every disk on the host" "$cmd"
    fi
done < <(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$F" | grep 'udevadm trigger')

grep -q 'trap _powos_cleanup_mounts EXIT' "$F" \
    && ok "temp mounts are cleaned up on exit, including on error" \
    || bad "no EXIT trap: a mid-script failure leaves the target's partitions mounted"

n=$(grep -c 'POWOS_TMP_MOUNTS+=' "$F")
m=$(grep -cE '^\s*(mp|mount_point)=\$\(mktemp -d\)' "$F")
[[ "$n" -ge "$m" && "$n" -gt 0 ]] \
    && ok "every mktemp mount point is registered for cleanup ($n)" \
    || bad "only $n of $m mount points registered for cleanup"

echo ""
echo "== Results: $P passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
