#!/bin/bash
# Makes the snapshot the browser resumes instead of booting: native QEMU (build-qemu-native.sh - the same source as
# the browser's) boots PowOS on the machine of web/machine.json from the published disk, and at the login prompt
# tools/snapshot.py stops it and saves its state (QMP migrate to a file). Closing the disk saves the blocks the boot
# wrote as chunks + an overlay (qemu/block/chunked.c save-overlay), so the resumed machine sees the disk it booted.
#
# Output: out/disk/snapshots/<id>/{vm.state, overlay.bin, serial.log, screen.ppm} (+ the overlay's chunks in
# out/disk/chunks/). Every run gets a NEW directory: the published snapshot is being served from out/disk while this
# runs, and a build must never touch it. assemble.sh publishes the newest complete one.
# Usage: targets/web/build-snapshot.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
M=$HERE/web/machine.json
j() { python3 -c "import json,sys; print(json.load(open('$M'))['$1'])"; }
# The machine's devices (display + input): part of the machine, so the snapshot has them too.
DEVICES=$(python3 -c "import json; print(' '.join('-device ' + d for d in json.load(open('$M')).get('devices', [])))")
ID=$(date +%Y%m%d-%H%M%S)
mkdir -p "$HERE/out/disk/snapshots/$ID"
echo "snapshot: out/disk/snapshots/$ID"
# The guest prepares itself for the snapshot: tools/snapshot-prepare.sh (desktop up, settled, page cache dropped,
# memory reported, ready marker), run as root by systemd's run generator - no login. The script rides on the kernel
# command line itself, gzip+base64 (that alphabet is command-line safe; ~1 KB of the 2 KB limit): the ALARM kernel has
# no qemu_fw_cfg, and another disk would change the machine. systemd.unit=kernel-command-line.target: the generator
# hooks its command into default.target, which our explicit systemd.unit= bypasses; the script starts the targets.
# Only this run has these arguments; the browser's command line is machine.json's.
SCRIPT=$(python3 -c "import base64,gzip,sys; print(base64.b64encode(gzip.compress(open(sys.argv[1],'rb').read(), 9)).decode())" "$HERE/tools/snapshot-prepare.sh")
PREPARE="systemd.unit=kernel-command-line.target systemd.run_success_action=none systemd.run_failure_action=none systemd.run=\"/bin/sh -c 'echo $SCRIPT | base64 -d | gzip -dc | /bin/sh'\""
echo "snapshot: prepare script on the command line: ${#PREPARE} bytes"
docker run --rm -v "$HERE/out/disk:/disk" -v "$HERE/out/qemu-native:/q:ro" -v "$HERE/tools:/tools:ro" \
  -e MACHINE="$(j machine)" -e CPU="$(j cpu)" -e MEM="$(j memory)" -e KERNEL="$(j kernel)" -e INITRD="$(j initrd)" \
  -e APPEND="$(j append)" -e PREPARE="$PREPARE" -e DEVICES="$DEVICES" -e S="/disk/snapshots/$ID" powos-web-qemu-native bash -c '
  set -euo pipefail
  # The browser machine (args.js), natively; plus a QMP socket for the snapshot controller.
  /q/qemu-system-aarch64 -display none -M "$MACHINE" -cpu "$CPU" -m "$MEM" -accel tcg -nic none $DEVICES \
    -kernel "/disk/$KERNEL" -initrd "/disk/$INITRD" -append "$APPEND $PREPARE" \
    -drive if=none,id=disk0,format=raw,file.driver=chunked,file.url=/disk,file.save-overlay=$S/overlay.bin \
    -device virtio-blk-pci,drive=disk0 -qmp unix:/tmp/qmp.sock,server=on,wait=off \
    -chardev socket,id=con,path=/tmp/serial.sock,server=on,wait=off -serial chardev:con -monitor none \
    < /dev/null > /tmp/qemu.log 2>&1 &
  qemu=$!
  # The serial port is a socket (the controller logs in through it); the console backend is not machine state.
  python3 /tools/snapshot.py /tmp/serial.sock /tmp/serial.log /tmp/qmp.sock $S/vm.state \
    || { cp /tmp/serial.log $S/serial.log; tail -30 /tmp/serial.log; tail -5 /tmp/qemu.log; exit 1; }
  wait $qemu || true
  cp /tmp/serial.log $S/serial.log
  grep -a "chunked: saved overlay" /tmp/qemu.log
  grep -a -A3 "Mem:" /tmp/serial.log | head -4
  ls -la $S'
# The desktop as it was saved (QEMU's screendump, taken right before the migration).
[ -f "$HERE/out/disk/snapshots/$ID/screen.ppm" ] && echo "screen: $HERE/out/disk/snapshots/$ID/screen.ppm"
