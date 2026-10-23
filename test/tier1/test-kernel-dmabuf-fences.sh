#!/bin/bash
# test-kernel-dmabuf-fences.sh - the phone kernel's dma-buf sync_file fences stay flat however many frames a game shows.
#
# targets/android/kernel/patches/0004 (DMA_BUF_IOCTL_IMPORT/EXPORT_SYNC_FILE backport) nested the buffer's fence one
# dma_fence_array deeper per imported frame; freeing the buffer at a game's close released that nest recursively and
# overflowed the kernel stack - the phone rebooted at every game close (2026-10-23). 0005 merges through upstream's
# __dma_fence_unwrap_merge. This cuts the SHIPPED dma_buf_resv_fence out of the patches (0004's alone = before, with
# 0005 = after) and runs it in dmabuf-fences/model.c: a userspace dma_fence / dma_fence_array / dma_resv model plus
# upstream's unwrap + merge copied from the phone's android13-5.15 tree. 1000 presented frames, then the buffer goes:
#   after (0005):  fence nested <= 1 deep, release recursion <= 3, nothing leaked, Xwayland's fence never early
#   before (0004): the model must catch it (recursion ~ the frame count) - proves the test sees the bug.
# Usage: bash test/tier1/test-kernel-dmabuf-fences.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
P=$ROOT/targets/android/kernel/patches
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
echo "== dma-buf sync_file fences (kernel patches 0004 + 0005) =="
CC=${CC:-cc}
if ! command -v "$CC" >/dev/null 2>&1; then echo "  skip - no C compiler"; echo; echo "== Results: 0 passed, 0 failed =="; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# fn <file with the function>: the text of dma_buf_resv_fence (its first line to the first "}" at column 0).
fn() { awk '/^static int dma_buf_resv_fence\(/ {f = 1} f {print} f && /^}$/ {exit}' "$1"; }
# 0004's version: its added lines. 0005's: the post-image of its hunks (context + added lines).
sed -n 's/^+//p' "$P"/0004-dma-buf-sync-file-import-export.patch | grep -v '^++ ' > "$T/before.c"
awk '/^@@/ {h = 1; next} h && /^[ +]/ {print substr($0, 2)} h && /^-/ {next}' "$P"/0005-dma-buf-sync-file-flat-fences.patch > "$T/after.c"

run() {  # run <name> <source with the function> <expect: pass|fail>
  local n=$1 out rc
  fn "$2" > "$T/resv_fence.inc"
  [ -s "$T/resv_fence.inc" ] || { bad "$n: no dma_buf_resv_fence in the patch"; return; }
  cp "$HERE/dmabuf-fences/model.c" "$T/model.c"
  if ! "$CC" -std=gnu11 -O1 -w -o "$T/model-$n" "$T/model.c" 2> "$T/cc-$n.txt"; then
    bad "$n: does not compile: $(head -3 "$T/cc-$n.txt" | tr '\n' ' ')"; return; fi
  out=$("$T/model-$n" 1000 2>&1); rc=$?
  echo "$out" | sed 's/^/         /'
  if [ "$3" = pass ]; then [ $rc = 0 ] && ok "$n: flat fences, bounded release, no leak" || bad "$n: $out"
  else [ $rc != 0 ] && ok "$n: the model catches the nesting it shipped with" || bad "$n: the model no longer sees 0004's bug"; fi
}
run after-0005 "$T/after.c" pass
run before-0004 "$T/before.c" fail
echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ $FAIL = 0 ]
