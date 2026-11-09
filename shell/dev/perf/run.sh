#!/bin/bash
# Headless drawer perf / behaviour probes in the gate's Chromium (shell/dev/shots.mjs, patched on the fly to print
# Chromium's metrics - layouts, style recalcs, script time - around the probe).
#   shell/dev/perf/run.sh <probe.js> [shell-dir] [scene]
#     probe.js: a file here (slow.js, drag.js, open.js, scroll.js, check.js) or any path; evaluated in the page once
#       it settled; its value and the metric deltas are printed per screen (folded, unfolded).
#     shell-dir: the shell to load (default: this tree's shell/, copied without node_modules); give another checkout's
#       shell/ (or an extracted `git archive`) for a before/after. scene: shots.mjs scene, default "home".
# PERF_PLATFORM: the image's platform (default linux/arm64, the Mac; linux/amd64 on .58 - an idle box, true timings);
# PERF_TRACE=1: a trace (PERF_TRACE=inv: with what invalidated style, by class/attribute and node) over the probe too, each thread's busiest events (PERF_TRACE_TOP of them, default 25).
# PERF_RUN_ARGS: more `docker run` flags (.58's rootless podman: --userns keep-id, so the image reads the mounts).
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
        // Paints per layer while the probe runs (LayerTree.layerPainted): which layers redraw, how much of them.
        const cdp = await page.createCDPSession();
        const painted = new Map();
        cdp.on("LayerTree.layerPainted", ({ layerId, clip }) => {
          const e = painted.get(layerId) ?? { n: 0, px: 0 };
          e.n++; e.px += clip.width * clip.height; painted.set(layerId, e);
        });
        const names = new Map();
        cdp.on("LayerTree.layerTreeDidChange", ({ layers }) => (layers ?? []).forEach((l) => names.set(l.layerId, `${l.width}x${l.height}${l.backendNodeId ? " node " + l.backendNodeId : ""}`)));
        await cdp.send("LayerTree.enable");
        const m0 = await page.metrics();
        // PERF_TRACE=1: a trace over the probe, each thread's busiest events (total ms, longest), so a long frame
        // with no script in it (LoAF's) is named: style, layout, paint, raster, the compositor, the GPU.
        const tracing = !!process.env.PERF_TRACE;
        if (tracing) await page.tracing.start({ path: "/out/trace.json", categories: ["devtools.timeline", "disabled-by-default-devtools.timeline", "toplevel", "blink", "cc", "viz", "gpu", "benchmark", ...(process.env.PERF_TRACE === "inv" ? ["disabled-by-default-devtools.timeline.invalidationTracking"] : [])] });
        const v = await page.evaluate(process.env.SHOTS_PROBE).catch((e) => e.message);
        const m1 = await page.metrics();
        let threads;
        if (tracing) {
          const ev = JSON.parse(String(await page.tracing.stop())).traceEvents ?? [];
          const tn = new Map(ev.filter((e) => e.ph === "M" && e.name === "thread_name").map((e) => [`${e.pid}:${e.tid}`, e.args.name]));
          const by = new Map();
          for (const e of ev) {
            if (e.ph !== "X" || !e.dur) continue;
            const t = tn.get(`${e.pid}:${e.tid}`) ?? String(e.tid);
            const k = `${t}|${e.name}`;
            const x = by.get(k) ?? { n: 0, ms: 0, max: 0 };
            x.n++; x.ms += e.dur / 1000; x.max = Math.max(x.max, e.dur / 1000); by.set(k, x);
          }
          threads = [...by].filter(([k]) => !/ThreadControllerImpl|RunTask|MessageLoop|ThreadPool_RunTask/.test(k)).sort((a, b) => b[1].ms - a[1].ms).slice(0, +(process.env.PERF_TRACE_TOP || 25))
            .map(([k, x]) => `${k} ${x.n}x ${x.ms.toFixed(1)}ms max ${x.max.toFixed(1)}`);
          // Elements restyled: the biggest style recalcs (how much of the page one change touched).
          const st = ev.filter((e) => e.name === "UpdateLayoutTree" && e.args?.elementCount).map((e) => e.args.elementCount).sort((a, b) => b - a);
          // PERF_TRACE=inv: what invalidated style (the changed class/attribute/selector and the node), most first.
          const inv = new Map();
          for (const e of ev) {
            if (!/InvalidationTracking/.test(e.name)) continue;
            const a = e.args?.data ?? {};
            const k = `${e.name.replace("InvalidationTracking", "")} ${a.reason ?? ""} ${a.changedClass ?? a.changedAttribute ?? a.changedId ?? a.changedPseudo ?? ""} ${a.invalidatedSelectorId ?? a.selectorPart ?? ""} @${a.nodeName ?? ""}`;
            inv.set(k, (inv.get(k) ?? 0) + 1);
          }
          if (inv.size) threads.unshift(...[...inv].sort((a, b) => b[1] - a[1]).slice(0, 25).map(([k, n]) => `inv ${n}x ${k}`));
          threads.unshift(`restyled elements: ${st.reduce((a, b) => a + b, 0)} in ${st.length} recalcs, biggest ${st.slice(0, 8).join(" ")}`);
        }
        await cdp.send("LayerTree.disable").catch(() => {});
        const paints = [...painted].map(([id, e]) => ({ layer: names.get(id) ?? id, n: e.n, mpx: +(e.px / 1e6).toFixed(2) })).sort((a, b) => b.mpx - a.mpx).slice(0, 6);
        const d = Object.fromEntries(["LayoutCount", "RecalcStyleCount", "LayoutDuration", "RecalcStyleDuration", "ScriptDuration"].map((k) => [k, +((m1[k] - m0[k]) * (k.endsWith("Duration") ? 1000 : 1)).toFixed(1)]));
        console.log(`probe ${name}-${sizeName}:`, JSON.stringify({ v, d, paints, threads }));
      }""")
open(sys.argv[2], "w").write(s)
PY
docker run --rm ${PERF_RUN_ARGS:-} --platform "${PERF_PLATFORM:-linux/arm64}" --shm-size 512m -v "$work/shell:/shell:ro" -v "$work/perf.mjs:/usr/src/app/shots.mjs:ro" \
  -v "$shell/dev/agents-fleet.mjs:/usr/src/app/agents-fleet.mjs:ro" \
  -v "$work/out:/out" -e SHOTS_ONLY="^$scene\$" -e SHOTS_PROBE="$(cat "$probe")" -e PERF_TRACE="${PERF_TRACE:-}" -e PERF_TRACE_TOP="${PERF_TRACE_TOP:-}" -w /usr/src/app --entrypoint node \
  "${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}" shots.mjs 2>&1 | grep '^probe '
