/**
 * The bar meter's copy of the main shell's frames (fpssample.ts publishes them, "perf.sample"): a ring for the graph,
 * the latest fps, and - while recording - every frame time in a preallocated array. No frames for FRESH_MS = the
 * main shell isn't reporting (older host, home not running): the meter falls back to the bar's own frames ("bar").
 */
export const MRING = 90, MAX = 20_000, FRESH_MS = 1500;
export const mring = new Float32Array(MRING);
export const m = { head: 0, filled: 0, fps: 0, at: 0, idle: false, gone: false, recDt: new Float32Array(0), recN: 0, recording: false };

export const mainFresh = () => m.idle || performance.now() - m.at < FRESH_MS;

/**
 * {idle: true}: the main shell went quiet (fpssample.ts samples only while something happens) - it draws nothing, so
 * 0 fps, and the bar stays asleep instead of measuring its own frames. {gone: true}: it was hidden (an app or game in
 * front): the bar sleeps too and shows a dash - its own frames were a 60 Hz WebView loop over the game (10-30 ABZU:
 * statusbar 60 rAF/s, ~24 ms script/s) measuring the bar, not the game. A recording still runs the loop. Any other sample ends idle.
 */
export function onSample(s: { fps?: number; dts?: number[]; idle?: boolean; gone?: boolean } | null) {
  if (!s) return;
  if (s.idle || s.gone) return quiet(!!s.idle);
  if (!Array.isArray(s.dts)) return;
  m.idle = false; m.gone = false;
  m.fps = Math.max(0, Math.min(999, Math.round(Number(s.fps) || 0))); m.at = performance.now();
  for (const d of s.dts) push(Number(d));
}
function quiet(idle: boolean) {
  m.idle = idle; m.gone = !idle; m.fps = 0; m.at = idle ? performance.now() : 0;
}
function push(x: number) {
  if (!(x > 0)) return;
  mring[m.head] = x; m.head = (m.head + 1) % MRING; if (m.filled < MRING) m.filled++;
  if (m.recording && m.recN < MAX) m.recDt[m.recN++] = x;
}
export function beginMain() { m.recDt = new Float32Array(MAX); m.recN = 0; m.recording = true; }
/** Frame times collected (and the times of their ends, cumulative) since beginMain. */
export function endMain() {
  m.recording = false;
  const dt = m.recDt.subarray(0, m.recN), t = new Float32Array(m.recN);
  let at = 0; for (let i = 0; i < m.recN; i++) { at += dt[i]; t[i] = at; }
  const out = { dt: new Float32Array(dt), t, n: m.recN };
  m.recDt = new Float32Array(0); m.recN = 0;
  return out;
}
