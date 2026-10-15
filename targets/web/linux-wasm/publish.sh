#!/bin/bash
# Publishes the Linux/Wasm build (build.sh) next to PowOS Web: https://powos-web.pow/linux-wasm/
# (the same nginx, so the same cross-origin isolation headers the runtime needs for SharedArrayBuffer).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
V=${LW_VARIANT:-wasm32_nommu}
I=$HERE/out/linux-wasm/install
D=$HERE/out/site/linux-wasm
rm -rf "$D" && mkdir -p "$D"
# Our runtime (linux-wasm/runtime: upstream's + the streamed disk's host side in linux-worker.js).
cp "$HERE"/linux-wasm/runtime/{index.html,linux.js,linux-worker.js,xterm.js,xterm.css,bright.css} "$D/"
# The disk the kernel streams (build-disk.sh), when built.
[ -f "$HERE/out/linux-wasm/powos.erofs" ] && cp "$HERE/out/linux-wasm/powos.erofs" "$D/"
cp "$I/kernel-$V/vmlinux.wasm" "$D/vmlinux-$V.wasm"
cp "$I/initramfs-$V/initramfs.cpio.gz" "$D/initramfs-$V.cpio.gz"
# Test hook: expose the page's terminal (test/linux-wasm.mjs reads it).
sed -i.bak 's#      term.open(document.getElementById("terminal"));#      term.open(document.getElementById("terminal")); window.lwTerm = term;#' "$D/index.html" && rm "$D/index.html.bak"
grep -q 'window.lwTerm' "$D/index.html" || { echo "test hook not applied (runtime changed?)" >&2; exit 1; }
ls -la "$D"
