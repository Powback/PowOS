/**
 * The main shell's side of the fps meter: this page (home) measures its own rAF frame times - the frames the user sees -
 * and sends them to the status bar's meter (fpsmeter.tsx) through the host (perf.publish -> "perf.sample"), ~4 Hz:
 * { fps, dts: the frame times since the last sample }. Only while the meter is on (store perf.meter, "perf.meter" event)
 * and the page is visible. The rAF callback allocates nothing (a ring); the sample is built 4x a second.
 */
import { powos } from "../bridge.ts";

const SIZE = 512, SAMPLE_MS = 250, CAP = 40;
const ring = new Float32Array(SIZE);
let head = 0, sent = 0, last = 0, raf = 0, timer = 0, on = false;
const marks = new Float64Array(240);
let markHead = 0;

function frame(t: number) {
  raf = requestAnimationFrame(frame);
  if (last) { ring[head % SIZE] = t - last; head++; marks[markHead] = t; markHead = (markHead + 1) % marks.length; }
  last = t;
}

/** Frames in the last second, from the marks ring. */
function fpsNow(): number {
  const now = performance.now();
  let n = 0, oldest = now, newest = 0;
  for (let i = 0; i < marks.length; i++) {
    const m = marks[i];
    if (!m || now - m > 1000) continue;
    n++; oldest = Math.min(oldest, m); newest = Math.max(newest, m);
  }
  return n < 2 ? 0 : Math.round((n - 1) * 1000 / Math.max(1, newest - oldest));
}

function sample() {
  const fps = fpsNow();
  const from = Math.max(sent, head - CAP, head - SIZE);
  const dts: number[] = [];
  for (let i = from; i < head; i++) dts.push(Math.round(ring[i % SIZE] * 10) / 10);
  sent = head;
  void powos.perf?.publish?.(JSON.stringify({ fps, dts, at: Date.now() }))?.catch?.(() => {});
}

function run() {
  if (!on || document.hidden) {
    cancelAnimationFrame(raf); clearInterval(timer); raf = timer = 0; marks.fill(0); last = 0;
    return;
  }
  if (raf) return;
  sent = head; raf = requestAnimationFrame(frame); timer = window.setInterval(sample, SAMPLE_MS);
}

/** A meter recording ({rec} in "perf.meter"): perfrec.ts records inputs, state and long frames here, loaded on demand. */
let rec: Promise<typeof import("./perfrec.ts")> | null = null;
function recorder(v: { rec?: number } | null) {
  if (!v?.rec && !rec) return;
  rec ??= import("./perfrec.ts");
  void rec.then((m) => m.onMeter(v), (e) => console.error("perfrec", e));
}

export function startSampler() {
  powos.on("perf.meter", (v: { on?: boolean; rec?: number } | null) => { on = !!v?.on; run(); recorder(v); });
  document.addEventListener("visibilitychange", run);
  powos.store.get<{ on?: boolean }>("perf.meter").then((v) => { on = !!v?.on; run(); }, () => {});
}
