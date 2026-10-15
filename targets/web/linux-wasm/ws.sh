#!/bin/bash
# Runs a command inside the Linux/Wasm build workspace (out/linux-wasm/workspace.ext4 mounted at /ws), e.g. to read
# or patch sources: targets/web/linux-wasm/ws.sh 'sed -n 1,20p /ws/src/busybox/shell/hush.c'
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm --privileged -v "$HERE/out/linux-wasm:/out" -v "$HERE:/web:ro" -v "$HERE/reference/linux-wasm:/linux-wasm:ro" linux-wasm-base:dev bash -c '
  mkdir -p /ws && mount -o loop /out/workspace.ext4 /ws && trap "umount -l /ws" EXIT
  '"$1"
