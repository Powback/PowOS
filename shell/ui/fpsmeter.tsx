/**
 * Status-bar FPS meter + tap-to-record perf trace. Off by default (store "perf.meter" = {on:true}).
 * Stable by construction: the component renders its DOM once and is then only touched imperatively (a text node and a
 * canvas), never re-rendered per frame; fixed width + tabular digits; the rAF loop does no allocation (ring buffers);
 * text updates at 4 Hz from a 1 s window, the sparkline at 10 Hz on its own 2D canvas.
 * Asleep while the main shell says it is idle ({idle} samples, fpssample.ts): no rAF loop, no redraws - the bar's own
 * loop was a frame every vsync for a meter showing a home that drew nothing (10-30, the idle WebView load).
 */
import { useEffect, useRef } from "preact/hooks";
import { powos } from "../bridge.ts";
import { m as main, mring, MRING, mainFresh, onSample, beginMain, endMain } from "./fpsmain.ts";
import { loafEntry, type Loaf } from "./loaf.ts";
import type { FrontPresents, NativePerf } from "../types.ts";

// The first SETTLE_MS after the tap are the meter's own UI reacting (REC label, panel/graph opening): not recorded.
const SETTLE_MS = 300;
const RING = 90, MAX_REC_MS = 120_000, MAX_FRAMES = 20_000, MAX_EVENTS = 300, STORE = "perf.meter";
const ring = new Float32Array(RING);
let head = 0, filled = 0, last = 0, raf = 0, enabled = false;
const marks = new Float64Array(240); // frame end times of roughly the last second (ring, for fps)
let markHead = 0;

// Recording: preallocated, bounded.
let rec = false, recStart = 0, settleAt = 0, settleTimer = 0, recT = new Float32Array(0), recDt = new Float32Array(0), recN = 0;
let events: ({ kind: string; start: number; dur: number; blocking?: number } & Partial<Loaf>)[] = [];
// Home's side of the recording (perfrec.ts): started by {rec} in "perf.meter", its detail comes back in parts.
let recId = 0, homeParts: string[] = [], homeGot = 0, homeDone: (() => void) | null = null;
type Part = { rec?: number; recPart?: number; of?: number; data?: string };
/** A part of the current recording, with a sane count (at most 400 parts). */
function validPart(s: Part): s is Part & { of: number; data: string } {
  return s.rec === recId && Number(s.of) > 0 && Number(s.of) <= 400 && typeof s.data === "string";
}
function onPart(s: Part) {
  if (!validPart(s)) return;
  if (homeParts.length !== s.of) { homeParts = new Array(s.of).fill(""); homeGot = 0; }
  const i = Number(s.recPart);
  if (i >= 0 && i < s.of && !homeParts[i]) { homeParts[i] = s.data; homeGot++; }
  if (homeGot === s.of) homeDone?.();
}
/** What home's long frames were made of (the summary's few lines; the full list is in `home.loaf`). */
function attribution(home: { loaf?: Loaf[]; inputs?: unknown[]; state?: unknown[] } | undefined) {
  if (!home) return undefined;
  const top = [...(home.loaf ?? [])].sort((a, b) => b.dur - a.dur).slice(0, 5).map((l) => {
    const end = l.start + l.dur, s = [...l.scripts].sort((a, b) => b.dur - a.dur)[0];
    return { start: l.start, dur: l.dur, script: l.scripts.reduce((x, y) => x + y.dur, 0), styleLayout: l.style ? end - l.style : 0,
      render: l.render ? end - l.render : 0, top: s ? `${s.type} ${s.invoker} ${s.src}${s.fn ? ":" + s.fn : ""} ${s.dur}ms forced ${s.forced}ms` : "" };
  });
  return { longFrames: top, inputs: home.inputs?.length ?? 0, transitions: home.state?.length ?? 0 };
}
/** The summary's home entry: its attribution, or why there is none. */
function homeLine(home: (NonNullable<Parameters<typeof attribution>[0]> & { missed?: string; error?: string }) | undefined) {
  return home?.missed ?? home?.error ?? attribution(home) ?? "no detail from home (older shell there, or it didn't answer in 3 s)";
}
/**
 * The host's main-thread blocks (perf.native) on the recording's clock: `start` ms from the settle point like every other
 * time here (the host gives epoch ms). The UI thread is the WebView's draw thread, so these are the stalls with no script.
 */
function nativeSection(n: NativePerf | true | null | undefined, from: number) {
  if (!n || n === true) return undefined;
  const zero = performance.timeOrigin + from, rel = (at: number) => Math.round(at - zero);
  return { thresholdMs: n.thresholdMs, blocks: n.blocks.map((b) => ({ start: rel(b.at), ...b })), frameGaps: n.frameGaps.map((g) => ({ start: rel(g.at), ...g })) };
}
/** Stops the host's side of the recording and reads it (undefined: an older host). */
async function stopNative(from: number) {
  return nativeSection(await powos.perf?.native?.(false).catch(() => null), from);
}
/** The summary's native entry: the longest blocks with their cause, or why there are none. */
function nativeLine(n: ReturnType<typeof nativeSection>) {
  if (!n) return "no native section (host without perf.native)";
  return { blocks: n.blocks.length, gaps: n.frameGaps.length, longest: [...n.blocks].sort((a, b) => b.ms - a.ms).slice(0, 5)
    .map((b) => ({ start: b.start, ms: b.ms, msg: b.msg, bridge: b.bridge ?? null, lastCall: b.lastCall ?? null, lastCallAgoMs: b.lastCallAgoMs ?? null, stack: b.stack?.split(" < ").slice(0, 8).join(" < ") ?? null })) };
}
let po: PerformanceObserver | null = null;
let ui: { root: HTMLElement; num: HTMLElement; cv: HTMLCanvasElement; ctx: CanvasRenderingContext2D | null; label: HTMLElement } | null = null;
let timer = 0, stopTimer = 0, busy = false;

function frame(t: number) {
  raf = requestAnimationFrame(frame);
  if (last) {
    const dt = t - last;
    ring[head] = dt; head = (head + 1) % RING; if (filled < RING) filled++;
    marks[markHead] = t; markHead = (markHead + 1) % marks.length;
    if (rec && t >= settleAt && recN < MAX_FRAMES) { recT[recN] = t - recStart; recDt[recN] = dt; recN++; }
  }
  last = t;
}

function fpsNow(): number {
  const now = performance.now();
  let n = 0, oldest = now;
  for (let i = 0; i < marks.length; i++) { const m = marks[i]; if (m && now - m <= 1000) { n++; if (m < oldest) oldest = m; } }
  if (n < 2) return 0;
  return Math.round((n - 1) * 1000 / Math.max(1, marks[(markHead + marks.length - 1) % marks.length] - oldest));
}

let shownFps = -1, shownRec = "";
// Resolve theme tokens outside the drawing loop; refresh when PowOS changes the theme.
let graphColors = ["", "", ""];
function readGraphColors() {
  const style = getComputedStyle(document.documentElement);
  graphColors = ["red", "yellow", "green"].map((name) => style.getPropertyValue(`--color-${name}`).trim());
}
function drawGraph(cv: HTMLCanvasElement, ctx: CanvasRenderingContext2D) {
  const w = cv.width, h = cv.height, bw = w / RING, fromMain = mainFresh();
  const r = fromMain ? mring : ring, hd = fromMain ? main.head : head, fl = fromMain ? main.filled : filled;
  ctx.clearRect(0, 0, w, h);
  for (let i = 0; i < fl; i++) {
    const dt = r[(hd - fl + i + MRING) % MRING];
    ctx.fillStyle = graphColors[dt > 33.5 ? 0 : dt > 18 ? 1 : 2];
    const bh = Math.max(1, Math.min(1, dt / 50) * h); // 50 ms = full height
    ctx.fillRect((RING - fl + i) * bw, h - bh, Math.max(1, bw - 0.4), bh);
  }
}

// Home away (a game in front): the front PowOS window's own rate - its surface's presents (native_consumer.c's
// queueBuffer count, host "perf.front"), polled at 1 Hz; -1 = none yet (a dash). Undrawn presents go in the tooltip.
let game = -1, gameUndrawn = 0, gameTimer = 0, gamePrev: FrontPresents | null = null;
/** Presents and undrawn per second between two samples of the same window, or undefined (another window, no time). */
function rates(p: FrontPresents, prev: FrontPresents | null) {
  const dt = prev ? p.at - prev.at : 0;
  if (!prev || p.id !== prev.id || dt <= 0 || p.presented < prev.presented) return undefined;
  return { fps: Math.round((p.presented - prev.presented) * 1000 / dt), undrawn: Math.round((p.undrawn - prev.undrawn) * 1000 / dt) };
}
function frontPresents(): Promise<FrontPresents | null> {
  const front = powos.perf?.front;
  return front ? front().catch(() => null) : Promise.resolve(null);
}
async function pollGame() {
  const p = await frontPresents();
  if (!gameTimer) return;
  const r = p && rates(p, gamePrev);
  if (!p) game = -1;
  else if (r) { game = r.fps; gameUndrawn = r.undrawn; }
  gamePrev = p;
  if (!ui) return;
  ui.root.title = p && game >= 0 ? `window ${p.id}: ${game} presents/s, ${gameUndrawn}/s not drawn` : "";
  drawText(ui);
}
function startGame() {
  if (gameTimer || !powos.perf?.front) return;
  gamePrev = null; game = -1;
  gameTimer = window.setInterval(() => void pollGame(), 1000);
  void pollGame();
}
function stopGame() {
  if (!gameTimer) return;
  clearInterval(gameTimer); gameTimer = 0; gamePrev = null; game = -1;
  if (ui) ui.root.title = "";
}

/** The number to show: home's, the bar's own, the front game's, or -2 = home away and no game rate yet (a dash). */
function shownNumber(): number {
  if (main.gone && !raf) return game >= 0 ? game : -2;
  return mainFresh() ? main.fps : fpsNow();
}

function drawText(u: NonNullable<typeof ui>) {
  const f = shownNumber();
  if (f !== shownFps) { shownFps = f; u.num.textContent = f < 0 ? "\u2007\u2007\u2013" : String(f).padStart(3, "\u2007"); }
  const label = rec ? `REC ${Math.floor((performance.now() - recStart) / 1000)}s` : busy ? "SEND" : "";
  if (label !== shownRec) { shownRec = label; u.label.textContent = label; u.root.classList.toggle("rec", rec); }
}

function tick(count: number) {
  if (!ui) return;
  if (ui.ctx) drawGraph(ui.cv, ui.ctx);
  if (count % 3 === 0) drawText(ui);
}

/** Home away (an app/game in front): not the bar's own frames - the front window's presents (pollGame). */
function followGame() {
  if (enabled && !document.hidden && main.gone && !rec) startGame(); else stopGame();
}

/** Home idle (and no recording): the meter shows 0 and its loop sleeps until home samples again. */
function follow() {
  followGame();
  if (!enabled || document.hidden) return;
  if ((!main.idle && !main.gone) || rec) return start();
  if (!raf) return;
  stopLoop();
  if (ui?.ctx) drawGraph(ui.cv, ui.ctx);
  if (ui) drawText(ui);
}

function start() {
  if (raf) return;
  last = 0; raf = requestAnimationFrame(frame);
  let c = 0; timer = window.setInterval(() => tick(c++), 100);
}
function stopLoop() {
  cancelAnimationFrame(raf); raf = 0; clearInterval(timer); timer = 0; shownFps = -1; marks.fill(0); filled = 0;
}
function setEnabled(on: boolean) {
  if (on === enabled) return;
  enabled = on;
  if (ui) ui.root.hidden = !on;
  if (on && !document.hidden) { start(); follow(); } else { stopLoop(); stopGame(); }
  window.dispatchEvent(new Event("fps-layout"));
}
document.addEventListener("visibilitychange", () => { if (enabled && !rec) { if (document.hidden) { stopLoop(); stopGame(); } else { start(); follow(); } } });

async function readSetting() {
  const v = await powos.store.get<{ on?: boolean }>(STORE).catch(() => null);
  setEnabled(!!v?.on);
}
/** Turn the meter on/off (persisted). Other windows pick it up within a few seconds. */
export function setMeter(on: boolean) { setEnabled(on); void powos.store.set(STORE, { on }).catch(() => {}); }

function observe() {
  events = [];
  try {
    po = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        if (events.length >= MAX_EVENTS) break;
        if (e.startTime < settleAt) continue; // the meter's own opening
        events.push(e.entryType === "long-animation-frame" ? { kind: e.entryType, ...loafEntry(e, recStart) }
          : { kind: e.entryType, start: Math.round(e.startTime - recStart), dur: Math.round(e.duration) });
      }
    });
    for (const type of ["longtask", "long-animation-frame"]) { try { po.observe({ type, buffered: false }); } catch { /* not supported */ } }
  } catch { po = null; }
}

function pct(sorted: number[], p: number) { return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : 0; }

export function summarise({ t, dt, n, evs, durMs, mode }: { t: Float32Array; dt: Float32Array; n: number; evs: typeof events; durMs: number; mode: string }) {
  const fps: number[] = [], worst: { at: number; ms: number }[] = [];
  for (let i = 0; i < n; i++) { fps.push(1000 / Math.max(1, dt[i])); worst.push({ at: Math.round(t[i]), ms: Math.round(dt[i] * 10) / 10 }); }
  fps.sort((a, b) => a - b);
  worst.sort((a, b) => b.ms - a.ms);
  const jank = (() => { let j = 0; for (let i = 0; i < n; i++) if (dt[i] > 33.4) j++; return j; })();
  const r = (x: number) => Math.round(x * 10) / 10;
  return {
    mode, durationMs: Math.round(durMs), frames: n, capped: n >= MAX_FRAMES,
    fps: { p50: r(pct(fps, 0.5)), p5: r(pct(fps, 0.05)), min: r(fps[0] ?? 0) },
    jank, worstFrames: worst.slice(0, 10),
    longTasks: [...evs].sort((a, b) => b.dur - a.dur).slice(0, 10).map(({ kind, start, dur, blocking }) => ({ kind, start, dur, blocking })),
  };
}

function beginRecord() {
  recStart = performance.now(); settleAt = recStart + SETTLE_MS; recN = 0;
  recT = new Float32Array(MAX_FRAMES); recDt = new Float32Array(MAX_FRAMES);
  observe(); rec = true;
  settleTimer = window.setTimeout(() => { if (rec) beginMain(); }, SETTLE_MS); // home's frames, from the same point
  recId = Date.now(); homeParts = []; homeGot = 0;
  void powos.store.set(STORE, { on: true, rec: recId }).catch(() => {});
  void powos.perf?.native?.(true).catch(() => null); // the host's main-thread blocks (MainStallWatch.kt), from now
  if (!raf) start();
  stopTimer = window.setTimeout(() => void toggleRecord(), MAX_REC_MS);
}

async function saveAndSend(full: object, sum: object) {
  let path: string | null = null;
  try { path = (await powos.perf?.save?.(JSON.stringify(full))) ?? null; } catch { path = null; }
  const text = `Perf trace (fps meter, tapped record/stop). ${path ? `Full data: ${path}` : "Full data could not be saved (host has no perf.save yet)."}\n` +
    "```json\n" + JSON.stringify(sum) + "\n```";
  try { await powos.ai.send(text, false); } catch (e) { console.error("perf send failed", e); }
}

async function endRecord() {
  rec = false; busy = true; clearTimeout(stopTimer); clearTimeout(settleTimer); po?.disconnect(); po = null;
  const durMs = Math.max(0, performance.now() - settleAt), n = recN;
  const mode = new URLSearchParams(location.search).get("mode") ?? "?";
  const mn = endMain(), fromMain = mn.n > 1;
  const native = await stopNative(settleAt);
  void powos.store.set(STORE, { on: true, stop: recId }).catch(() => {}); // home stops and sends its detail (or why not)
  await new Promise<void>((r) => { homeDone = r; setTimeout(r, homeGot && homeGot === homeParts.length ? 0 : 3000); });
  homeDone = null;
  let home: ({ loaf?: Loaf[]; inputs?: unknown[]; state?: unknown[]; missed?: string; error?: string } & Record<string, unknown>) | undefined;
  try { home = homeGot && homeGot === homeParts.length ? JSON.parse(homeParts.join("")) : undefined; } catch { home = undefined; }
  homeParts = []; homeGot = 0;
  const sum = fromMain ? summarise({ ...mn, evs: events, durMs, mode: `main shell (home), ${mode} bar recorded` })
    : summarise({ t: recT, dt: recDt, n, evs: events, durMs, mode: `${mode} window only, main shell not reporting (${powos.host})` });
  Object.assign(sum, { settle: SETTLE_MS, home: homeLine(home), native: nativeLine(native) });
  const full = { summary: sum, main: fromMain ? { frameDeltas: Array.from(mn.dt, (x) => Math.round(x * 10) / 10) } : undefined, when: new Date().toISOString(), ua: navigator.userAgent, dpr: devicePixelRatio,
    frameTimes: Array.from(recT.subarray(0, n), (x) => Math.round(x)), frameDeltas: Array.from(recDt.subarray(0, n), (x) => Math.round(x * 10) / 10), events, home, native };
  recT = new Float32Array(0); recDt = new Float32Array(0);
  await saveAndSend(full, sum);
  busy = false;
  if (ui && !raf) drawText(ui); // the loop may sleep (home idle): clear the SEND label
}

async function toggleRecord() {
  if (busy) return;
  if (rec) await endRecord(); else beginRecord();
}

export function FpsMeter() {
  const root = useRef<HTMLButtonElement>(null), num = useRef<HTMLSpanElement>(null), cv = useRef<HTMLCanvasElement>(null), label = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    ui = { root: root.current!, num: num.current!, cv: cv.current!, ctx: cv.current!.getContext("2d"), label: label.current! };
    readGraphColors();
    const themeChanges = new MutationObserver(readGraphColors);
    themeChanges.observe(document.documentElement, { attributes: true, attributeFilter: ["style", "class"] });
    ui.root.hidden = !enabled;
    void readSetting();
    const poll = window.setInterval(() => { if (!rec) void readSetting(); }, 30000); // backstop; the host pushes changes
    const offs = [powos.on("perf.meter", (v: { on?: boolean } | null) => setEnabled(!!v?.on)), powos.on("perf.sample", (s: ({ recPart?: number } & Parameters<typeof onSample>[0]) | null) => s && "recPart" in s ? onPart(s) : (onSample(s), follow()))];
    return () => { themeChanges.disconnect(); clearInterval(poll); offs.forEach((o) => o()); ui = null; };
  }, []);
  // Rendered always (hidden while off) so the node and canvas are stable; the bar never re-renders it per frame.
  return <button ref={root} class="fps-meter" data-action="fps" aria-label="FPS meter, tap to record a perf trace"
    onClick={() => void toggleRecord()}>
    <canvas ref={cv} width={90} height={16} aria-hidden="true" />
    <span class="fps-num" ref={num}>{"   "}</span><span class="fps-unit">fps</span>
    <span class="fps-rec" ref={label} />
  </button>;
}
