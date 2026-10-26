/**
 * How fast home's icons come up, measured each time the page loads and logged once (logcat, tag PowosShell:
 * "iconperf ..."), so a cold start after an update, a home recreate or a fold can be compared without a debugger:
 * - paint: the page's first paint, ms from navigation start;
 * - shown: when every app icon in the page has its picture (none pulsing, none broken), and how many that was;
 * - fetched: /_icon/ requests in that time (unique / total: a URL asked twice means the list changed under it);
 * - slowest: the longest single icon request;
 * - snapshot: when index.html put home's last frame up (ui/snapshot.ts) and when every icon in it was in.
 * Later list changes (apps.changed) that make the page ask for icons again are logged as "iconperf refetch".
 * window.__iconperf holds the same numbers for CDP.
 */

interface IconPerf {
  paint: number | null;
  shown: number | null;
  icons: number;
  fetched: number;
  unique: number;
  slowest: number;
  fromSnapshot: boolean;
  snapshot: { at: number; icons: number; loaded: number; last: number } | null;
}

const perf: IconPerf = { paint: null, shown: null, icons: 0, fetched: 0, unique: 0, slowest: 0, fromSnapshot: false, snapshot: null };
(window as unknown as { __iconperf: IconPerf }).__iconperf = perf;

const iconRequests: PerformanceResourceTiming[] = [];
/** Told when icon requests came in (after the first measure: a refetch to log). */
let onIcons: (() => void) | null = null;
try {
  new PerformanceObserver((l) => {
    let any = false;
    for (const e of l.getEntries())
      if (e.name.includes("/_icon/")) {
        iconRequests.push(e as PerformanceResourceTiming);
        any = true;
      }
    if (any) onIcons?.();
  }).observe({ type: "resource", buffered: true });
  new PerformanceObserver((l) => {
    for (const e of l.getEntries()) if (e.name === "first-paint") perf.paint = Math.round(e.startTime);
  }).observe({ type: "paint", buffered: true });
} catch {
  // no observers here: the numbers stay empty
}
// Room for every icon request of a slow start (the default buffer of 250 was full before the list settled).
performance.setResourceTimingBufferSize?.(2000);

const imgs = () => [...document.querySelectorAll<HTMLImageElement>(".app-icon img")];
const ready = (i: HTMLImageElement) => i.complete && i.naturalWidth > 0;

/** Watches until every icon is in (or 15 s pass), then logs; [from] is where the first frame's icons came from. */
export function measureIcons(fromSnapshot: boolean) {
  perf.fromSnapshot = fromSnapshot;
  const start = performance.now();
  const tick = () => {
    const all = imgs();
    const pending = all.filter((i) => !ready(i) && !i.closest(".initials")).length;
    if (all.length && !pending) return done(all.length, 0);
    if (performance.now() - start > 15000) return done(all.length, pending);
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

function done(icons: number, pending: number) {
  perf.shown = Math.round(performance.now());
  perf.icons = icons;
  perf.fetched = iconRequests.length;
  perf.unique = new Set(iconRequests.map((e) => e.name)).size;
  perf.slowest = Math.round(Math.max(0, ...iconRequests.map((e) => e.duration)));
  const snap = (window as unknown as { __snapshot?: { at: number; icons: number; loaded: number; last: number } }).__snapshot;
  perf.snapshot = snap ? { at: Math.round(snap.at), icons: snap.icons, loaded: snap.loaded, last: Math.round(snap.last) } : null;
  console.info(
    `iconperf paint ${perf.paint}ms shown ${perf.shown}ms icons ${icons}${pending ? ` (${pending} never came)` : ""} fetched ${perf.unique}/${perf.fetched} slowest ${perf.slowest}ms` +
      (snap ? ` | snapshot up ${Math.round(snap.at)}ms, its icons ${snap.loaded}/${snap.icons} in by ${Math.round(snap.last)}ms` : " | no snapshot"),
  );
  // From here, a list change that asks for icons again is logged on its own, a second after its last request - when
  // requests come (the resource observer), never on a timer of its own: it was a 1 s interval for the page's whole
  // life, a wake-up a second on an idle home.
  let seen = iconRequests.length;
  let timer = 0;
  onIcons = () => {
    clearTimeout(timer);
    timer = window.setTimeout(() => {
      const batch = iconRequests.slice(seen);
      seen = iconRequests.length;
      if (batch.length) console.info(`iconperf refetch ${batch.length} icons, slowest ${Math.round(Math.max(0, ...batch.map((e) => e.duration)))}ms`);
    }, 1000);
  };
}
