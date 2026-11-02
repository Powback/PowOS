/**
 * The render scan on a surface's own page (the shade, the launcher and the AI overlay's pull, the lock face, the
 * switcher alone, PowOS AI over an app: index.html?mode=shade|pull|lock|recents|assist): home has fpssample.ts +
 * perfrec.ts; these pages are their own WebViews, so a scan on home never saw them (the user: "must cover the shade,
 * launcher, lock, switcher, overlay too"). Each surface's root registers here (app.tsx) and follows the same store
 * key, "perf.meter", the host broadcasts to every shell page:
 * - {on, renders}: the live overlay (renderoverlay.ts) outlines this page's re-rendering components too.
 * - {on, rec}: a recording - the scan collects here as well ("rec:<surface>"); the page says hello at the start
 *   ({rec, surface, hello}) so the bar (fpsmeter.tsx) waits for it, and at the end ({rec} gone, or {stop}) sends its
 *   renders section in parts ({rec, surface, recPart, of, data}, each < the host's 8 KB per perf.publish). The bar
 *   files it under the trace's `surfaces.<surface>`.
 * Off = nothing: no hooks (renderscan.ts), no observers, one store listener.
 */
import { powos } from "../bridge.ts";
import { setOverlay } from "./renderoverlay.ts";
import { renderReport, reset as resetScan, scanClock, startScan, stopScan } from "./renderscan.ts";

const PART = 2500, MAX_LOAF = 300, MAX_REC_MS = 125_000;
type Meter = { on?: boolean; rec?: number; stop?: number; renders?: boolean } | null;

let surface = "", id = 0, t0 = 0, stopTimer = 0, po: PerformanceObserver | null = null, following = false;
let long: { start: number; dur: number }[] = [];

function publish(v: object) {
  void powos.perf?.publish?.(JSON.stringify(v))?.catch?.(() => {});
}

function begin(rec: number) {
  id = rec; t0 = performance.now(); long = [];
  startScan(`rec:${surface}`); resetScan();
  try {
    po = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) if (long.length < MAX_LOAF) long.push({ start: Math.round(e.startTime - t0), dur: Math.round(e.duration) });
    });
    po.observe({ type: "long-animation-frame", buffered: false });
  } catch { po = null; } // no LoAF: the totals and top lists still come
  stopTimer = window.setTimeout(() => end(), MAX_REC_MS);
  publish({ rec, surface, hello: true });
}

/** Stops and sends this surface's renders section to the bar. */
function end() {
  if (!id) return;
  clearTimeout(stopTimer);
  po?.disconnect(); po = null;
  let json: string;
  try { json = JSON.stringify(renderReport(long, scanClock() - t0)); } catch (e) { json = JSON.stringify({ error: `${surface}'s render scan: ${e}` }); }
  stopScan(`rec:${surface}`);
  const rec = id; id = 0; long = [];
  const n = Math.max(1, Math.ceil(json.length / PART));
  for (let i = 0; i < n; i++) publish({ rec, surface, recPart: i, of: n, data: json.slice(i * PART, (i + 1) * PART) });
}

/** The "perf.meter" value, as home's fpssample.ts + perfrec.ts read it. */
export function onMeter(v: Meter) {
  try { setOverlay(!!(v?.on && v.renders)); } catch (e) { console.error("render overlay", e); }
  const r = Number(v?.rec) || 0;
  if (r && r !== id) { end(); begin(r); }
  else if (!r && id) end();
}

/** This page's root is [name]'s: its renders count in the overlay and in the bar's recordings. */
export function followRenders(name: string) {
  if (following) return;
  following = true; surface = name;
  powos.on("perf.meter", onMeter);
  powos.store.get<Meter>("perf.meter").then((v) => setOverlay(!!(v?.on && v?.renders)), () => {});
}
