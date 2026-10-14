#!/bin/bash
# Disassembles code in a library of PowOS's initramfs around an offset (from a probe crash: pc/lr - map start).
# Usage: targets/web/test/probe/disasm.sh <lib path in initramfs> <hex offset> [bytes before] [bytes after]
set -euo pipefail
W=$(cd "$(dirname "$0")/../.." && pwd)
docker run --rm --platform linux/arm64 -v "$W/out/disk:/disk:ro" -e LIB="$1" -e OFF="$2" -e BEFORE="${3:-0x80}" \
  -e AFTER="${4:-0x20}" debian:trixie bash -c '
  set -euo pipefail
  apt-get update -qq && apt-get install -y -qq binutils initramfs-tools-core zstd cpio gawk >/dev/null 2>&1
  unmkinitramfs /disk/initramfs.img /tmp/x >/dev/null 2>&1
  f=$(ls -d /tmp/x/main$LIB /tmp/x$LIB 2>/dev/null | head -1 || true)
  start=$(printf "0x%x" $(( OFF - BEFORE ))); stop=$(printf "0x%x" $(( OFF + AFTER )))
  echo "== $LIB $OFF"
  # The nearest exported symbol at or below the offset names the function.
  objdump -T "$f" | gawk -v o=$((OFF)) "/ DF /{a=strtonum(\"0x\"\$1); if (a<=o && a>best) {best=a; name=\$NF}} END {printf \"in %s (+0x%x)\n\", name, o-best}"
  objdump -d --no-show-raw-insn --start-address=$start --stop-address=$stop "$f" | tail -n +7'
