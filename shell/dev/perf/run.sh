#!/bin/bash
# Headless drawer perf / behaviour probes in the gate's Chromium (shell/dev/shots.mjs, patched on the fly to print
# Chromium's metrics - layouts, style recalcs, script time - around the probe).
#   shell/dev/perf/run.sh <probe.js> [shell-dir] [scene]
#     probe.js: a file here (slow.js, drag.js, open.js, scroll.js, check.js) or any path; evaluated in the page once
#       it settled; its value and the metric deltas are printed per screen (folded, unfolded).
#     shell-dir: the shell to load (default: this tree's shell/, copied without node_modules); give another checkout's
#       shell/ (or an extracted `git archive`) for a before/after. scene: shots.mjs scene, default "home".
# The Mac's load skews the timings: run before and after back to back. Counts (LayoutCount, RecalcStyleCount) don't.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
shell=$(cd "$here/../.." && pwd)
probe=$1
[ -f "$probe" ] || probe=$here/$1
src=${2:-$shell}
scene=${3:-home}
mkdir -p "$HOME/.cache/powos-gate"
work=$(mktemp -d "$HOME/.cache/powos-gate/perf.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/shell" "$work/out"
(cd "$src" && tar --exclude ./node_modules -cf - .) | tar -xf - -C "$work/shell"
python3 - "$shell/dev/shots.mjs" "$work/perf.mjs" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = """        console.log(`probe ${name}-${sizeName}:`, JSON.stringify(await page.evaluate(process.env.SHOTS_PROBE).catch((e) => e.message)));"""
assert a in s, "shots.mjs's SHOTS_PROBE line changed: update run.sh"
s = s.replace(a, """      {
        const m0 = await page.metrics();
        const v = await page.evaluate(process.env.SHOTS_PROBE).catch((e) => e.message);
        const m1 = await page.metrics();
        const d = Object.fromEntries(["LayoutCount", "RecalcStyleCount", "LayoutDuration", "RecalcStyleDuration", "ScriptDuration"].map((k) => [k, +((m1[k] - m0[k]) * (k.endsWith("Duration") ? 1000 : 1)).toFixed(1)]));
        console.log(`probe ${name}-${sizeName}:`, JSON.stringify({ v, d }));
      }""")
open(sys.argv[2], "w").write(s)
PY
docker run --rm --platform linux/arm64 --shm-size 512m -v "$work/shell:/shell:ro" -v "$work/perf.mjs:/usr/src/app/shots.mjs:ro" \
  -v "$work/out:/out" -e SHOTS_ONLY="^$scene\$" -e SHOTS_PROBE="$(cat "$probe")" -w /usr/src/app --entrypoint node \
  "${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}" shots.mjs 2>&1 | grep '^probe '
