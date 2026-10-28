/**
 * Status-bar FPS meter + tap-to-record perf trace. Off by default (store "perf.meter" = {on:true}).
 * Stable by construction: the component renders its DOM once and is then only touched imperatively (a text node and a
 * canvas), never re-rendered per frame; fixed width + tabular digits; the rAF loop does no allocation (ring buffers);
 * text updates at 4 Hz from a 1 s window, the sparkline at 10 Hz on its own 2D canvas.
 */
import { useEffect, useRef } from "preact/hooks";
import { powos } from "../bridge.ts";

const RING = 90, MAX_REC_MS = 120_000, MAX_FRAMES = 20_000, MAX_EVENTS = 300, STORE = "perf.meter";
const ring = new Float32Array(RING);
let head = 0, filled = 0, last = 0, raf = 0, enabled = false;
const marks = new Float64Array(240); // frame end times of roughly the last second (ring, for fps)
let markHead = 0;

// Recording: preallocated, bounded.
let rec = false, recStart = 0, recT = new Float32Array(0), recDt = new Float32Array(0), recN = 0;
let events: { kind: string; start: number; dur: number; blocking?: number }[] = [];
let po: PerformanceObserver | null = null;
let ui: { root: HTMLElement; num: HTMLElement; cv: HTMLCanvasElement; ctx: CanvasRenderingContext2D | null; label: HTMLElement } | null = null;
let timer = 0, stopTimer = 0, busy = false;

function frame(t: number) {
  raf = requestAnimationFrame(frame);
  if (last) {
    const dt = t - last;
    ring[head] = dt; head = (head + 1) % RING; if (filled < RING) filled++;
    marks[markHead] = t; markHead = (markHead + 1) % marks.length;
    if (rec && recN < MAX_FRAMES) { recT[recN] = t - recStart; recDt[recN] = dt; recN++; }
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
function tick(count: number) {
  if (!ui) return;
  const { ctx, cv } = ui;
  if (ctx) {
    const w = cv.width, h = cv.height;
    ctx.clearRect(0, 0, w, h);
    const bw = w / RING;
    for (let i = 0; i < filled; i++) {
      const dt = ring[(head - filled + i + RING) % RING];
      const v = Math.min(1, dt / 50); // 50 ms = full height
      ctx.fillStyle = dt > 33.5 ? "#ff5a4f" : dt > 18 ? "#ffb02e" : "#5fd38a";
      const bh = Math.max(1, v * h);
      ctx.fillRect((RING - filled + i) * bw, h - bh, Math.max(1, bw - 0.4), bh);
    }
  }
  if (count % 3 === 0) {
    const f = fpsNow();
    if (f !== shownFps) { shownFps = f; ui.num.textContent = String(f).padStart(3, " "); }
    const label = rec ? `REC ${Math.floor((performance.now() - recStart) / 1000)}s` : busy ? "SEND" : "";
    if (label !== shownRec) { shownRec = label; ui.label.textContent = label; ui.root.classList.toggle("rec", rec); }
  }
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
  if (on && !document.hidden) start(); else stopLoop();
  window.dispatchEvent(new Event("fps-layout"));
}
document.addEventListener("visibilitychange", () => { if (enabled && !rec) { if (document.hidden) stopLoop(); else start(); } });

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
        events.push({ kind: e.entryType, start: Math.round(e.startTime - recStart), dur: Math.round(e.duration),
          blocking: (e as unknown as { blockingDuration?: number }).blockingDuration });
      }
    });
    for (const type of ["longtask", "long-animation-frame"]) { try { po.observe({ type, buffered: false }); } catch { /* not supported */ } }
  } catch { po = null; }
}

function pct(sorted: number[], p: number) { return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : 0; }

export function summarise(t: Float32Array, dt: Float32Array, n: number, evs: typeof events, durMs: number, mode: string) {
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
    longTasks: [...evs].sort((a, b) => b.dur - a.dur).slice(0, 10),
  };
}

async function toggleRecord() {
  if (busy) return;
  if (!rec) {
    recStart = performance.now(); recN = 0;
    recT = new Float32Array(MAX_FRAMES); recDt = new Float32Array(MAX_FRAMES);
    observe(); rec = true;
    if (!raf) start();
    stopTimer = window.setTimeout(() => void toggleRecord(), MAX_REC_MS);
    return;
  }
  rec = false; busy = true; clearTimeout(stopTimer); po?.disconnect(); po = null;
  const dur = performance.now() - recStart, n = recN;
  const mode = new URLSearchParams(location.search).get("mode") ?? "?";
  const sum = summarise(recT, recDt, n, events, dur, `${mode} window (${powos.host})`);
  const full = { summary: sum, when: new Date().toISOString(), ua: navigator.userAgent, dpr: devicePixelRatio,
    frameTimes: Array.from(recT.subarray(0, n), (x) => Math.round(x)), frameDeltas: Array.from(recDt.subarray(0, n), (x) => Math.round(x * 10) / 10), events };
  recT = new Float32Array(0); recDt = new Float32Array(0);
  let path: string | null = null;
  try { path = (await powos.perf?.save?.(JSON.stringify(full))) ?? null; } catch { path = null; }
  const text = `Perf trace (fps meter, tapped record/stop). ${path ? `Full data: ${path}` : "Full data could not be saved (host has no perf.save yet)."}\n` +
    "```json\n" + JSON.stringify(sum) + "\n```";
  try { await powos.ai.send(text, false); } catch (e) { console.error("perf send failed", e); }
  busy = false;
}

export function FpsMeter() {
  const root = useRef<HTMLButtonElement>(null), num = useRef<HTMLSpanElement>(null), cv = useRef<HTMLCanvasElement>(null), label = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    ui = { root: root.current!, num: num.current!, cv: cv.current!, ctx: cv.current!.getContext("2d"), label: label.current! };
    ui.root.hidden = !enabled;
    void readSetting();
    const poll = window.setInterval(() => { if (!rec) void readSetting(); }, 5000);
    return () => { clearInterval(poll); ui = null; };
  }, []);
  // Rendered always (hidden while off) so the node and canvas are stable; the bar never re-renders it per frame.
  return <button ref={root} class="fps-meter" data-action="fps" aria-label="FPS meter, tap to record a perf trace"
    onClick={() => void toggleRecord()}>
    <canvas ref={cv} width={90} height={16} aria-hidden="true" />
    <span class="fps-num" ref={num}>{"   "}</span><span class="fps-unit">fps</span>
    <span class="fps-rec" ref={label} />
  </button>;
}
