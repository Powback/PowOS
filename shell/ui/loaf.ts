/** A long-animation-frame entry as the FPS meter records it (fpsmeter.tsx for the bar, perfrec.ts for home). */
type Script = { invoker: string; type: string; src: string; fn: string; start: number; dur: number; forced: number; pause: number };
export type Loaf = { start: number; dur: number; blocking: number; render: number; style: number; firstUI: number; scripts: Script[] };

/** A long-animation-frame entry, times relative to t0, its scripts' attribution (shared with the bar's own observer). */
export function loafEntry(e: PerformanceEntry, t0: number): Loaf {
  const x = e as PerformanceEntry & { blockingDuration?: number; renderStart?: number; styleAndLayoutStart?: number; firstUIEventTimestamp?: number;
    scripts?: { invoker?: string; invokerType?: string; sourceURL?: string; sourceFunctionName?: string; startTime: number; duration: number; forcedStyleAndLayoutDuration?: number; pauseDuration?: number }[] };
  const rel = (v?: number) => (v ? Math.round(v - t0) : 0);
  return {
    start: Math.round(x.startTime - t0), dur: Math.round(x.duration), blocking: Math.round(x.blockingDuration ?? 0),
    render: rel(x.renderStart), style: rel(x.styleAndLayoutStart), firstUI: rel(x.firstUIEventTimestamp),
    scripts: (x.scripts ?? []).slice(0, 12).map((s) => ({
      invoker: String(s.invoker ?? "").slice(0, 120), type: s.invokerType ?? "", src: String(s.sourceURL ?? "").replace(/^.*\/\/[^/]+\//, "").slice(0, 120),
      fn: s.sourceFunctionName ?? "", start: Math.round(s.startTime - t0), dur: Math.round(s.duration),
      forced: Math.round(s.forcedStyleAndLayoutDuration ?? 0), pause: Math.round(s.pauseDuration ?? 0),
    })),
  };
}
