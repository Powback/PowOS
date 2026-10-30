/**
 * The main shell's side of the fps meter: this page (home) measures its own rAF frame times - the frames the user sees -
 * and sends them to the status bar's meter (fpsmeter.tsx) through the host (perf.publish -> "perf.sample"), ~4 Hz:
 * { fps, dts: the frame times since the last sample }. Only while the meter is on (store perf.meter, "perf.meter" event)
 * and the page is visible. The rAF callback allocates nothing (a ring); the sample is built 4x a second.
 *
 * Only while something happens (an input, a CSS animation or transition starting on the page, a recording) and IDLE_MS
 * after: a rAF loop is itself a frame every vsync - in an Android WebView it makes the view draw on each one (HWUI's
 * RenderThread, the in-process GPU and viz threads, the IO thread relaying BeginFrames), so a meter that sampled all the
 * time kept home drawing at the display rate while nothing changed (10-30: home and the bar both at rAF 60/s, 182
 * BeginFrames/s each, every other page 0). Going quiet it says {idle: true} once: the bar shows idle instead of falling
 * back to its own frames. Nothing moving draws nothing, so "idle" is the true frame rate then.
 */
import { powos } from "../bridge.ts";
import { onMeter } from "./perfrec.ts";
import { setOverlay } from "./renderoverlay.ts";

const SIZE = 512, SAMPLE_MS = 250, CAP = 40, IDLE_MS = 1500;
// What wakes the sampler: input anywhere on the page, and CSS motion starting (capture: events from any element).
const WAKE = ["pointerdown", "pointermove", "wheel", "keydown", "scroll", "animationstart", "transitionrun"];
const ring = new Float32Array(SIZE);
let head = 0, sent = 0, last = 0, raf = 0, timer = 0, on = false, active = 0, recording = false;
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
  publish({ fps, dts, at: Date.now() });
  if (!recording && performance.now() - active > IDLE_MS) { stop(); publish({ idle: true, at: Date.now() }); }
}

function publish(v: object) {
  void powos.perf?.publish?.(JSON.stringify(v))?.catch?.(() => {});
}

function stop() {
  cancelAnimationFrame(raf); clearInterval(timer); raf = timer = 0; marks.fill(0); last = 0;
}

function run() {
  if (!on || document.hidden) return stop();
  if (raf) return;
  sent = head; raf = requestAnimationFrame(frame); timer = window.setInterval(sample, SAMPLE_MS);
}

/** Something happened on the page: sample (again) until it has been quiet for IDLE_MS. */
function wake() {
  active = performance.now();
  if (on && !raf && !document.hidden) run();
}

/**
 * A meter recording ({rec} in "perf.meter"): perfrec.ts records inputs, state and long frames here. Imported statically:
 * home is the long-lived page, and an on-demand import() of a chunk from the bundle it loaded fails once the shell on
 * disk is updated (the bar, reloaded, runs the new one) - home then never recorded nor answered the bar's stop.
 */
function recorder(v: { on?: boolean; rec?: number; stop?: number; renders?: boolean } | null) {
  try { setOverlay(!!(v?.on && v.renders)); } catch (e) { console.error("render overlay", e); } // the meter's "rs" (renderoverlay.ts)
  // A recording measures every frame of it, idle or not.
  recording = !!v?.rec;
  if (recording) wake();
  try { onMeter(v); } catch (e) { console.error("perfrec", e); }
}

export function startSampler() {
  powos.on("perf.meter", (v: { on?: boolean; rec?: number; stop?: number; renders?: boolean } | null) => { on = !!v?.on; if (on) wake(); else stop(); recorder(v); });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) return wake();
    stop();
    if (on) publish({ gone: true }); // the bar measures its own frames while home is away
  });
  for (const t of WAKE) window.addEventListener(t, wake, { capture: true, passive: true });
  powos.store.get<{ on?: boolean; renders?: boolean }>("perf.meter").then((v) => { on = !!v?.on; if (on) wake(); setOverlay(!!(on && v?.renders)); }, () => {});
}
