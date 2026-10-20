#!/system/bin/sh
# The containers kernel's nftables modules (targets/android/kernel/build-containers-kernel.sh: nf_tables + nft_*,
# for netavark / nft in PowOS), loaded from the module's kernel-modules/ in load-order.txt order
# (docs/PHONE-KERNEL-CONTAINERS.md section 9 step 2). service.sh runs it in the background: nothing in Android's boot
# needs them, so a slow or failing insmod can never hold the boot up.
# They are signed with the containers kernel's key and carry its vermagic: on any other kernel (stock, after an OTA)
# the first insmod is refused cleanly ("disagrees about version" / "Exec format error") and the rest are skipped.
D=${0%/*}/kernel-modules
[ -f "$D/load-order.txt" ] || exit 0
n=0
for m in $(cat "$D/load-order.txt"); do
    grep -q "^${m%.ko} " /proc/modules && continue
    if ! insmod "$D/$m" 2>/dev/null; then
        log -t powos-system "kernel modules: insmod $m refused (kernel $(uname -r)): the rest skipped"
        exit 0
    fi
    n=$((n + 1))
done
log -t powos-system "kernel modules: $n loaded"
