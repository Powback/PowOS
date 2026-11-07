/**
 * JS stacks for a perf trace: the JS Self-Profiling API (new Profiler) samples the page's call stack every
 * SAMPLE_MS, so a long frame names the function that ran in it - "vendor/preact.js event-listener 72 ms" (what LoAF
 * alone says: Preact's delegated listener, no handler) becomes "end (ui/gesture.ts:980) < eventProxy (vendor/preact.js)".
 * Needs the page served with `Document-Policy: js-profiling` (ShellHost.kt, the gate's server); without it Profiler
 * throws and the trace says why instead.
 * Pre-roll: while the meter is on (perfrec.ts arms it) the profiler runs in CHUNK_MS chunks, the last finished one
 * kept, so a recording also covers the seconds BEFORE the record tap - the jank the user just saw. Off = no profiler.
 */
type Frame = { name?: string; resourceId?: number; line?: number; column?: number };
type Stack = { frameId: number; parentId?: number };
export type ProfTrace = { resources: string[]; frames: Frame[]; stacks: Stack[]; samples: { timestamp: number; stackId?: number }[] };
type ProfilerT = { stop(): Promise<ProfTrace>; addEventListener?(t: string, f: () => void): void };
type ProfilerCtor = new (o: { sampleInterval: number; maxBufferSize: number }) => ProfilerT;

export const SAMPLE_MS = 10;
const CHUNK_MS = 10_000, MAX_SAMPLES = 15_000;

let cur: ProfilerT | null = null, curStart = 0, prev: ProfTrace | null = null, chunkTimer = 0, why = "";

function make(maxSamples: number): ProfilerT | null {
  const P = (window as unknown as { Profiler?: ProfilerCtor }).Profiler;
  if (!P) { why = "no Profiler in this WebView (JS Self-Profiling API)"; return null; }
  try { return new P({ sampleInterval: SAMPLE_MS, maxBufferSize: maxSamples }); }
  catch (e) { why = `Profiler refused: ${e} (the page needs Document-Policy: js-profiling)`; return null; }
}

/** Starts sampling (no-op when already on). [preRoll]: rolling chunks, the last one kept for the next recording. */
export function startProfile(preRoll: boolean) {
  if (cur) return;
  cur = make(preRoll ? Math.ceil((CHUNK_MS * 2) / SAMPLE_MS) : MAX_SAMPLES); curStart = performance.now();
  // Rolled when the page is idle: a new Profiler costs the main thread ~20 ms (gate Chromium), never mid-gesture.
  if (cur && preRoll) chunkTimer = window.setInterval(() => requestIdleCallback(() => void roll(), { timeout: CHUNK_MS }), CHUNK_MS);
}
async function roll() {
  const p = cur;
  if (!p || !chunkTimer) return; // a recording's profiler (or none) took over since the idle callback was asked for
  cur = make(Math.ceil((CHUNK_MS * 2) / SAMPLE_MS)); curStart = performance.now();
  prev = await p.stop().catch(() => prev);
}
/** A recording starts: the pre-roll chunk ends here (kept), one long profiler takes over until stopProfile. */
export async function recordProfile() {
  clearInterval(chunkTimer); chunkTimer = 0;
  const p = cur;
  cur = make(MAX_SAMPLES); curStart = performance.now();
  if (p) { const t = await p.stop().catch(() => null); prev = merge(prev, t); }
}
/** Stops; the samples of the pre-roll and the recording in one trace (null: no profiler, see profileWhy). */
export async function stopProfile(): Promise<ProfTrace | null> {
  clearInterval(chunkTimer); chunkTimer = 0;
  const p = cur; cur = null;
  const t = p ? await p.stop().catch(() => null) : null;
  const all = merge(prev, t); prev = null;
  return all;
}
export const profileWhy = () => why;
export const profiling = () => !!cur;

/** Two traces as one (the second's ids shifted past the first's). */
function merge(a: ProfTrace | null, b: ProfTrace | null): ProfTrace | null {
  if (!a || !b) return a ?? b;
  const r = a.resources.length, f = a.frames.length, s = a.stacks.length;
  return {
    resources: [...a.resources, ...b.resources],
    frames: [...a.frames, ...b.frames.map((x) => ({ ...x, resourceId: x.resourceId == null ? undefined : x.resourceId + r }))],
    stacks: [...a.stacks, ...b.stacks.map((x) => ({ frameId: x.frameId + f, parentId: x.parentId == null ? undefined : x.parentId + s }))],
    samples: [...a.samples, ...b.samples.map((x) => ({ timestamp: x.timestamp, stackId: x.stackId == null ? undefined : x.stackId + s }))],
  };
}

/**
 * A module's file for its blob: URL (es-module-shims runs every module from one: the profile's resources are blobs).
 * HACK: es-module-shims' private registry (importShim._r, load records' .b), as index.html's boot.report does - it has no
 * public lookup; a new version may drop it and the stacks then say "blob:..." (still the function names). Real fix:
 * es-module-shims naming the source URL, or a loader of our own. Listed in docs/REMOTE-POWOS.md §4.
 */
function blobFiles(): Map<string, string> {
  const m = new Map<string, string>(), r = (window as unknown as { importShim?: { _r?: Record<string, { b?: string }> } }).importShim?._r;
  if (r) for (const k in r) if (r[k]?.b) m.set(r[k].b!, k);
  return m;
}
let files = new Map<string, string>();
const short = (u: string) => (files.get(u) ?? u).replace(/^.*\/\/[^/]+\//, "").replace(/\?.*$/, "");
/** "fn (file:line)" for a frame; anonymous functions keep their place. */
function frameName(t: ProfTrace, id: number) {
  const fr = t.frames[id];
  const res = fr.resourceId != null ? short(t.resources[fr.resourceId] ?? "") : "";
  return `${fr.name || "(anonymous)"}${res ? ` (${res}${fr.line ? ":" + fr.line : ""})` : ""}`;
}
/** The stack leaf-first, at most [depth] frames, as "leaf < caller < ...". */
function stackText(t: ProfTrace, id: number | undefined, depth: number) {
  const out: string[] = [];
  for (let s = id; s != null && out.length < depth; s = t.stacks[s]?.parentId) out.push(frameName(t, t.stacks[s].frameId));
  return out.join(" < ");
}
function top(m: Map<string, number>, n: number) {
  return [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => ({ ms: v * SAMPLE_MS, at: k }));
}
/**
 * The trace's "js" section: per window (a long frame, times on the recording's clock: page clock minus [t0]) the
 * stacks sampled in it, heaviest first (ms = samples x SAMPLE_MS); and over the whole trace the functions with the most
 * self time. Idle samples (no stack) are counted, not listed.
 */
export function profileReport(t: ProfTrace | null, windows: { start: number; dur: number }[], t0: number) {
  if (!t) return { error: why || "no profile" };
  files = blobFiles();
  const self = new Map<string, number>();
  let idle = 0;
  for (const s of t.samples) {
    if (s.stackId == null) { idle++; continue; }
    const k = frameName(t, t.stacks[s.stackId].frameId);
    self.set(k, (self.get(k) ?? 0) + 1);
  }
  const first = t.samples[0]?.timestamp ?? t0;
  const frames = windows.map((w) => {
    const stacks = new Map<string, number>();
    let n = 0;
    for (const s of t.samples) {
      const at = s.timestamp - t0;
      if (at < w.start || at > w.start + w.dur || s.stackId == null) continue;
      n++;
      const k = stackText(t, s.stackId, 7);
      stacks.set(k, (stacks.get(k) ?? 0) + 1);
    }
    return { start: w.start, dur: w.dur, jsMs: n * SAMPLE_MS, stacks: top(stacks, 4) };
  });
  return { v: 1, sampleMs: SAMPLE_MS, from: Math.round(first - t0), samples: t.samples.length, idle, selfTop: top(self, 15), frames };
}
