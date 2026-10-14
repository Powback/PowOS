#!/bin/bash
# Boots the probe (build.sh) under qemu-wasm in headless Chromium (?boot=probe) and shows what the kernel reported
# about crashes of systemd's unit loading (print-fatal-signals: PC, registers, library + offset).
set -euo pipefail
W=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$(mktemp -d)}
URL='https://powos-web.pow/?boot=probe' WAIT_FOR='probe done' TIMEOUT="${TIMEOUT:-1500}" "$W/test/boot.sh" "$OUT" || true
tr -d '\r' < "$OUT/serial.txt" | grep -E 'probe:|KILLED|unhandled|potentially unexpected fatal|pc :|lr :|sp :|x[0-9]+ :|Code:|esr|in [a-z.-]+\.so|systemd\[' | head -80
