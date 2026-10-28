#!/bin/bash
# Replays an FPS-meter recording (the bar's "Full data" file: fpsmeter.tsx, home's detail from ui/perfrec.ts) with the
# same start state, and traces it (replay.mjs does the work):
#   shell/dev/perf/replay.sh <recording.json> [--gate|--emu] [OUTDIR]
#   --gate (default): this tree's shell in the gate's headless Chromium (docker, like dev/shot.sh), at the recording's
#     viewport and dpr, the mock bridge seeded with its snapshot (stored settings, store keys, home layout, dock).
#   --emu: the emulator's home page over CDP (tools/phone/cdp.sh forwards it; POWOS_DEVICE=emu), the viewport
#     emulated, settings + store keys seeded, the page reloaded. Changes the emulator's state: emulator only.
# Then the recorded inputs at their original times under a CDP trace (devtools.timeline, blink). Prints the replayed
# long frames with their script / style / layout / paint / gc split; OUTDIR/replay-trace.json opens in Perfetto.
# A recording from before 2026-10-28 (no `home` field) has no inputs or snapshot: the shell just idles for its length.
# OUTDIR (default ~/.cache/powos-perf/replay-<time>) must be under $HOME (Colima mounts only the home folder).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
shell=$(cd "$here/../.." && pwd)
repo=$(cd "$shell/.." && pwd)
[ $# -ge 1 ] && [ -f "$1" ] || { sed -n '2,13p' "$0"; exit 2; }
rec=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); shift
mode=gate
[ "${1:-}" = --emu ] && { mode=emu; shift; }
[ "${1:-}" = --gate ] && shift
out=${1:-$HOME/.cache/powos-perf/replay-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"; out=$(cd "$out" && pwd)
if [ "$mode" = emu ]; then
  POWOS_DEVICE=emu "$repo/tools/phone/cdp.sh" pages >/dev/null # forwards the app's devtools socket to 127.0.0.1:9334
  MODE=emu REC="$rec" OUT="$out" CDP=http://127.0.0.1:9334 exec node --no-warnings "$here/replay.mjs"
fi
m=(-v "$shell:/shell:ro" -v "$here/replay.mjs:/usr/src/app/replay.mjs:ro" -v "$rec:/rec.json:ro" -v "$out:/out")
nerd=$(cd "$shell/fonts" 2>/dev/null && cd "$(dirname "$(readlink nerd_symbols.ttf)")" 2>/dev/null && pwd -P)/nerd_symbols.ttf
[ -f "$nerd" ] && m+=(-v "$nerd:/fonts/nerd_symbols.ttf:ro")
exec docker run --rm --platform linux/arm64 --shm-size 512m "${m[@]}" -e MODE=gate -e OUT_HOST="$out" \
  -w /usr/src/app --entrypoint node "${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}" replay.mjs
