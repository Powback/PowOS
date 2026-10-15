#!/bin/bash
# Boots the browser's disk natively and fast (macOS HVF / Linux KVM - minutes of TCG become seconds) on the browser's
# machine (web/machine.json), taking a screenshot every 15 s, to debug what the desktop actually shows.
#   python3 tools/unchunk-disk.py out/disk out/work/debug-disk.raw [out/disk/snapshots/<id>/overlay.bin]
#   test/debug-native.sh [seconds]        -> out/work/debug-<t>s.png, out/work/debug-serial.log
# SSH: localhost:2222 (powos/powos). Not for snapshots: HVF/KVM state doesn't load under the browser's TCG.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$HERE/out/work
SECS=${1:-150}
M=$HERE/web/machine.json
j() { python3 -c "import json; print(json.load(open('$M'))['$1'])"; }
DEVICES=$(python3 -c "import json; print(' '.join('-device ' + d for d in json.load(open('$M')).get('devices', [])))")
case "$(uname)" in Darwin) ACCEL="-accel hvf -cpu host";; *) ACCEL="-accel kvm -cpu host";; esac
rm -f "$W"/debug-*.png "$W/debug-qmp.sock"
qemu-system-aarch64 -M "$(j machine)" $ACCEL -m "${MEM:-$(j memory)}" -display none $DEVICES \
  -kernel "$HERE/out/disk/$(j kernel)" -initrd "$HERE/out/disk/$(j initrd)" -append "$(j append)" \
  -drive if=none,id=disk0,format=raw,file="$W/debug-disk.raw" -device virtio-blk-pci,drive=disk0 \
  -nic user,hostfwd=tcp::2222-:22 -serial file:"$W/debug-serial.log" -monitor none \
  -qmp unix:"$W/debug-qmp.sock",server=on,wait=off &
qemu=$!
trap 'kill $qemu 2>/dev/null || true' EXIT
for t in $(seq 15 15 "$SECS"); do
  sleep 15
  python3 - "$W/debug-qmp.sock" "$W/debug-${t}s.png" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw"); f.readline()
for cmd in ({"execute": "qmp_capabilities"}, {"execute": "screendump", "arguments": {"filename": sys.argv[2], "format": "png"}}):
    f.write(json.dumps(cmd) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: break
print(sys.argv[2], r.get("error", "ok"))
PY
done
