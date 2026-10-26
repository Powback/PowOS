#!/bin/bash
# Read-only checks and the module/podman tests for the containers kernel, run against the phone over adb
# (root via Magisk su). Nothing here flashes, writes a partition or reboots - the boot itself is the
# user's `fastboot boot` (docs/PHONE-KERNEL-CONTAINERS.md, "USB test").
#   ./phone-test.sh check      kernel, cgroup controllers, cpu.cfs_quota_us, vendor-module/driver health
#   ./phone-test.sh nft        push out/modules/ to /data/local/tmp/powos-nft and insmod them in order, then
#                              a throwaway nft table (removed again)
#   ./phone-test.sh limits     pids / cpu / memory enforcement: v2 pids, v1 cpu quota (cpuctl), v1 memcg -
#                              plain cgroup files, no podman
#   ./phone-test.sh podman     `podman run --pids-limit 10 --cpus 0.2 --memory 64m alpine` in the PowOS root
#                              (needs the controllers on cgroup v2: the -v2test boot image)
#   ./phone-test.sh containers the real runtime: `powos-container run` (hybrid: Android's v1 memcg/cpuctl, v2 pids)
#                              with --memory 64m --memory-swap 64m --cpus 0.2 --pids-limit 10, then pids, a CPU loop and
#                              a 200 MB hog through `powos-container exec`; any kernel (what it lacks: a warning)
# ADB="docker exec -i powos-vadb adb" ./phone-test.sh check     when the phone is only reachable through the VPN
set -euo pipefail
cd "$(dirname "$0")"
ADB=${ADB:-adb}
R=/data/powos/root
# Runs a root shell script on the phone (stdin), as Magisk's su.
su_sh() { $ADB shell "su -c sh" ; }

case "${1:-}" in
check)
  su_sh <<'EOF'
echo "== kernel";      uname -r; cat /proc/version | cut -c1-120; cat /proc/cmdline | tr ' ' '\n' | grep -E '^cgroup' || true
echo "== /proc/cgroups"; cat /proc/cgroups
echo "== v2 controllers: $(cat /sys/fs/cgroup/cgroup.controllers)"
echo "== cpu bandwidth (v1 cpuctl): $(ls /dev/cpuctl/cpu.cfs_quota_us /dev/cpuctl/cpu.cfs_period_us 2>&1 | tr '\n' ' ')"
echo "== modules loaded: $(cat /proc/modules | wc -l)"
dmesg | grep -iE 'disagrees about version|Unknown symbol|module verification failed|exec format' | head -5 || true
echo "== taint: $(cat /proc/sys/kernel/tainted)"
echo "== display/touch/wifi/modem/camera/fingerprint"
dumpsys SurfaceFlinger --display-id 2>/dev/null | head -3
getevent -pl 2>/dev/null | grep -c 'name:' | sed 's/^/input devices: /'
dumpsys wifi 2>/dev/null | grep -m1 -E '^Wi-Fi is'
dumpsys telephony.registry 2>/dev/null | grep -m1 -oE 'mVoiceRegState=[^,]*, mDataRegState=[^,]*'
dumpsys ims 2>/dev/null | grep -m1 -iE 'registered' || getprop | grep -m2 -i ims
dumpsys media.camera 2>/dev/null | grep -m1 -E 'Number of camera devices'
dumpsys fingerprint | grep -m1 -iE 'enrolled|prints' || true
EOF
  ;;
nft)
  [ -f out/modules/load-order.txt ] || { echo "no out/modules - run build-containers-kernel.sh" >&2; exit 1; }
  $ADB shell "rm -rf /data/local/tmp/powos-nft && mkdir -p /data/local/tmp/powos-nft"
  for m in $(cat out/modules/load-order.txt); do $ADB push -q out/modules/$m /data/local/tmp/powos-nft/; done
  $ADB push -q out/modules/load-order.txt /data/local/tmp/powos-nft/
  su_sh <<'EOF'
cd /data/local/tmp/powos-nft
for m in $(cat load-order.txt); do
  n=${m%.ko}
  grep -q "^$n " /proc/modules && continue
  insmod $m || { echo "insmod $m FAILED"; dmesg | tail -5; exit 1; }
done
echo "loaded: $(grep -cE '^(nf_tables|nft_)' /proc/modules) nftables modules"
chroot /data/powos/root /usr/bin/nft add table inet powos_test &&
chroot /data/powos/root /usr/bin/nft add chain inet powos_test c '{ type filter hook output priority 0; policy accept; }' &&
chroot /data/powos/root /usr/bin/nft add rule inet powos_test c meta l4proto tcp counter &&
chroot /data/powos/root /usr/bin/nft list table inet powos_test &&
chroot /data/powos/root /usr/bin/nft delete table inet powos_test && echo "nft: OK"
EOF
  ;;
limits)
  su_sh <<'EOF'
set -e
echo "== pids (cgroup v2)"
echo +pids > /sys/fs/cgroup/cgroup.subtree_control
mkdir -p /sys/fs/cgroup/powos-test && echo 5 > /sys/fs/cgroup/powos-test/pids.max
sh -c 'echo $$ > /sys/fs/cgroup/powos-test/cgroup.procs; for i in 1 2 3 4 5 6 7 8; do sleep 3 & done 2>&1; wait' 2>&1 | tail -2
echo "pids.events: $(cat /sys/fs/cgroup/powos-test/pids.events)   (max > 0 = forks were refused)"
rmdir /sys/fs/cgroup/powos-test
echo "== cpu quota 20% (cgroup v1 cpuctl)"
mkdir -p /dev/cpuctl/powos-test
echo 100000 > /dev/cpuctl/powos-test/cpu.cfs_period_us; echo 20000 > /dev/cpuctl/powos-test/cpu.cfs_quota_us
sh -c 'echo $$ > /dev/cpuctl/powos-test/tasks; timeout 5 sh -c "while :; do :; done"' || true
cat /dev/cpuctl/powos-test/cpu.stat     # nr_throttled > 0, throttled_time ~4s = capped at 20%
rmdir /dev/cpuctl/powos-test
echo "== memory 64M (cgroup v1 memcg - works on the stock kernel too)"
mkdir -p /dev/memcg/powos-test && echo 64M > /dev/memcg/powos-test/memory.limit_in_bytes
sh -c 'echo $$ > /dev/memcg/powos-test/cgroup.procs; head -c 209715200 /dev/zero | tail > /dev/null' && echo "NOT limited" || echo "killed at the limit: OK"
echo "failcnt: $(cat /dev/memcg/powos-test/memory.failcnt)"; rmdir /dev/memcg/powos-test
EOF
  ;;
podman)
  su_sh <<'EOF'
C=/sys/fs/cgroup
echo "v2 controllers: $(cat $C/cgroup.controllers)  (need: cpu memory pids - boot the -v2test image)"
for c in pids cpu memory; do echo +$c > $C/cgroup.subtree_control || echo "no $c on v2"; done
# vfs storage: the phone's /data is f2fs, which overlayfs can't use as its upper layer (real fix: an ext4 image or
# fuse-overlayfs as podman's storage).
B=/data/adb/magisk/busybox; $B unshare -m $B sh -c "$B mount --make-rprivate / && $B mount --bind /data/powos/root /data/powos/root && $B mount -t proc proc /data/powos/root/proc 2>/dev/null; $B mount --rbind /sys /data/powos/root/sys; $B mount --rbind /dev /data/powos/root/dev; exec $B chroot /data/powos/root /usr/bin/env PATH=/usr/bin:/bin TMPDIR=/var/tmp HOME=/root /bin/sh -s" <<'POD'
/usr/bin/podman --storage-driver=vfs --root /var/lib/containers/vfs --runroot /run/containers/vfs --cgroup-manager=cgroupfs run --rm --cgroups=enabled \
  --pids-limit 10 --cpus 0.2 --memory 64m docker.io/library/alpine sh -c '
  echo "pids.max=$(cat /sys/fs/cgroup/pids.max) cpu.max=$(cat /sys/fs/cgroup/cpu.max) memory.max=$(cat /sys/fs/cgroup/memory.max)"
  for i in $(seq 15); do sleep 2 & done 2>&1 | grep -c "can.t fork" | sed "s/^/refused forks: /"; wait
  timeout 5 sh -c "while :; do :; done"; grep -E "nr_throttled|throttled_usec" /sys/fs/cgroup/cpu.stat
  head -c 209715200 /dev/zero | tail > /dev/null; echo "memory hog exit: $? (137 = OOM-killed at 64m)"'
POD
EOF
  ;;
containers)
  su_sh <<'EOF'
P="chroot /data/powos/root /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root /usr/bin/powos-container"
$P check
$P rm -f -t 0 powos-limits-test >/dev/null 2>&1
$P run -d --name powos-limits-test --memory 64m --memory-swap 64m --cpus 0.2 --pids-limit 10 docker.io/library/alpine \
  sleep 300 >/dev/null || exit 1
tail -1 /data/powos/root/var/log/powos/containers.log
G=powos/powos-limits-test
echo "== pids 10: 15 forks"
$P exec powos-limits-test sh -c 'for i in $(seq 15); do sleep 3 & done 2>&1 | grep -c fork | sed "s/^/refused: /"; wait'
[ -f /sys/fs/cgroup/$G/pids.events ] && echo "pids.events: $(cat /sys/fs/cgroup/$G/pids.events)   (max > 0 = refused)"
echo "== cpu 0.2: a 5 s busy loop"
$P exec powos-limits-test timeout 5 sh -c 'while :; do :; done'
grep -E 'nr_periods|nr_throttled|throttled_time' /dev/cpuctl/$G/cpu.stat | tr '\n' ' '; echo
[ -f /dev/cpuctl/$G/cpu.cfs_quota_us ] || echo "(no CFS quota in this kernel: cpu.shares only, nothing is throttled)"
echo "== memory 64m, no swap: a 200 MB hog"
$P exec powos-limits-test sh -c 'head -c 209715200 /dev/zero | tail > /dev/null; echo "hog exit: $? (137 = OOM-killed)"'
grep oom_kill /dev/memcg/$G/memory.oom_control | tr '\n' ' '; echo
$P ps
$P rm -f -t 0 powos-limits-test >/dev/null
ls -d /dev/memcg/$G /dev/cpuctl/$G /sys/fs/cgroup/$G 2>/dev/null || echo "groups removed"
EOF
  ;;
*) sed -n 2,16p "$0"; exit 1 ;;
esac
