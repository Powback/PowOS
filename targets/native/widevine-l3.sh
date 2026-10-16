#!/system/bin/sh
# Netflix (and other Widevine apps) on the unlocked OnePlus Open: force Widevine's software L3.
#
# Why: Widevine L1 (hardware DRM in the Qualcomm TEE, /odm/lib64/liboemcrypto.so) gets its device certificate only
# when the phone proves its bootloader is locked. Unlocked, provisioning fails (OEMCrypto GenerateDerivedKeys
# status 25 -> provisioning status 342) and Netflix shows "could not reach the Netflix service (15001) (-93)" -
# it does not fall back by itself. With the L1 library hidden, Widevine uses its software L3 and Netflix plays,
# in SD (~480p: services only send HD to L1). HD needs a locked bootloader; root cannot change what the TEE reports.
#
# Installed by `rooted.sh widevine-l3` as /data/adb/post-fs-data.d/widevine-l3.sh: Magisk runs it at every boot
# before Android's services start, so the Widevine HAL starts without L1. Nothing on any partition changes (a bind
# mount over the library, in RAM). Undo: `rooted.sh widevine-l3 remove` (or umount the library, then restart the
# HAL / reboot).
L=/odm/lib64/liboemcrypto.so
E=/data/adb/powos/empty-liboemcrypto.so
[ -e "$L" ] || exit 0
grep -q " $L " /proc/mounts && exit 0
mkdir -p /data/adb/powos && : > "$E"
chcon "$(ls -Z "$L" | awk '{print $1}')" "$E"   # the library's own label (vendor_file), or the HAL can't open it
mount -o bind "$E" "$L"
# Run by hand after boot: restart the HAL so it drops L1 now (init restarts it).
[ "${1:-}" = now ] && pkill -f android.hardware.drm-service.widevine
exit 0
