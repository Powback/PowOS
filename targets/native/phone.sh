#!/bin/bash
# OnePlus Open (xueying) bring-up helper, run on the Mac. NOTHING here writes to the phone:
#   info     model, build, slot, unlock state (adb or fastboot, whichever the phone is in)
#   backup   every partition under 1 GiB (ALL=1: also super) -> backup/<serial>/ (BACKUP_DIR=... elsewhere, e.g. the
#            NAS), sha256 checked on both ends (needs root, adb)
#            - covers persist, modemst1/2, fsg (IMEI/modem calibration: unrecoverable if lost) and the bootloaders
#   dump     the running stock device tree + cmdline + iomem -> backup/<serial>/, and writes
#            dts/sm8550-oneplus-xueying-board.dtsi (qcom,msm-id, qcom,board-id, splash framebuffer region)
#   boot     fastboot boot out/boot-bringup.img (RAM only; the next restart is Android again)
#   shell    root shell on the booted bring-up image (USB serial, or telnet 172.16.42.1)
# Flashing is deliberately not a verb here.
set -euo pipefail
cd "$(dirname "$0")"
EXPECT_MODEL=CPH2551

# Magisk's su: on PATH once Magisk finished its setup, always at /debug_ramdisk/su while it runs.
adb_su() { adb exec-out "$(adb shell 'command -v su || echo /debug_ramdisk/su' | tr -d '\r') -c '$1'"; }
serial() { adb get-serialno 2>/dev/null || fastboot devices | awk 'NR==1{print $1}'; }

case "${1:-}" in
info)
  if adb get-state > /dev/null 2>&1; then
    for p in ro.product.model ro.product.device ro.build.fingerprint ro.boot.slot_suffix ro.boot.verifiedbootstate \
             ro.boot.flash.locked ro.build.version.security_patch; do
      printf '%-36s %s\n' "$p" "$(adb shell getprop $p | tr -d '\r')"
    done
    model=$(adb shell getprop ro.product.model | tr -d '\r')
    [ "$model" = "$EXPECT_MODEL" ] || echo "WARNING: model $model, expected $EXPECT_MODEL (global OnePlus Open)"
  elif fastboot devices | grep -q .; then
    for v in product unlocked current-slot secure version-bootloader; do fastboot getvar $v 2>&1 | head -1; done
  else
    echo "no phone over adb or fastboot"; exit 1
  fi ;;
backup)
  s=$(serial); D=${BACKUP_DIR:-backup}/$s; mkdir -p "$D"
  adb_su id | grep -q 'uid=0' || { echo "needs root (Magisk) - see README day 1"; exit 1; }
  adb_su 'for p in /dev/block/by-name/*; do n=${p##*/}; s=$(blockdev --getsize64 $(readlink -f $p)); echo "$n $s"; done' \
    | tr -d '\r' > "$D/partitions.txt"
  # fd 3: adb reads stdin, and would otherwise eat the rest of the list after the first partition.
  # ALL=1 also takes the big ones (super: Android's system/vendor). Never userdata (encrypted with keys bound to this
  # phone - a copy is useless) or the whole-LUN nodes sda..sdf (containers of the partitions listed separately).
  while read -r n size <&3; do
    case $n in userdata|sd[a-z]) echo "skip $n"; continue ;; esac
    [ "$size" -lt 1073741824 ] || [ "${ALL:-}" = 1 ] || { echo "skip $n ($((size >> 20)) MiB; ALL=1 to include)"; continue; }
    [ -s "$D/$n.img" ] && [ -f "$D/$n.sha256" ] && continue
    adb_su "cat /dev/block/by-name/$n" > "$D/$n.img"
    want=$(adb_su "sha256sum /dev/block/by-name/$n" | awk '{print $1}')
    got=$(shasum -a 256 "$D/$n.img" | awk '{print $1}')
    [ "$want" = "$got" ] || { echo "CHECKSUM MISMATCH on $n - rerun backup"; rm -f "$D/$n.img"; exit 1; }
    echo "$got  $n.img" > "$D/$n.sha256"
    echo "ok $n $((size >> 10)) KiB"
  done 3< "$D/partitions.txt"
  for must in persist modemst1 modemst2 fsg; do
    ls "$D"/$must*.img > /dev/null 2>&1 || echo "WARNING: no $must partition found - check partitions.txt by hand"
  done
  echo "backup in $D - copy it off this Mac too (NAS) before going further" ;;
dump)
  s=$(serial); D=backup/$s; mkdir -p "$D"
  adb_su 'tar -C /sys/firmware/devicetree -c base' > "$D/device-tree.tar"
  adb_su 'cat /proc/cmdline' > "$D/cmdline.txt"
  adb_su 'cat /proc/iomem' > "$D/iomem.txt"
  adb shell wm size > "$D/wm-size.txt"
  python3 tools/board-dtsi.py "$D/device-tree.tar" > dts/sm8550-oneplus-xueying-board.dtsi
  cat dts/sm8550-oneplus-xueying-board.dtsi
  echo "dumped to $D; now ./build-kernel.sh && ./make-bootimg.sh" ;;
boot)
  [ -f out/boot-bringup.img ] || { echo "no out/boot-bringup.img (make-bootimg.sh)"; exit 1; }
  fastboot getvar unlocked 2>&1 | grep -q 'unlocked: yes' || { echo "phone not in fastboot or bootloader still locked"; exit 1; }
  fastboot boot out/boot-bringup.img
  echo "booting from RAM. In ~30 s: ./phone.sh shell   (restart into Android: hold power + volume down)" ;;
shell)
  tty=$(ls /dev/tty.usbmodem* 2>/dev/null | head -1 || true)
  if [ -n "$tty" ]; then echo "serial $tty (leave screen: ctrl-a k)"; exec screen "$tty" 115200; fi
  ping -c1 -t2 172.16.42.1 > /dev/null 2>&1 || { echo "no bring-up phone on USB (no serial port, 172.16.42.1 silent)"; exit 1; }
  if command -v telnet > /dev/null; then exec telnet 172.16.42.1; else exec nc 172.16.42.1 23; fi ;;
*)
  sed -n '2,10p' "$0"; exit 1 ;;
esac
