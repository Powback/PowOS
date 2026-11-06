/**
 * The main shell's (home's) side of an FPS-meter recording: what happened while the bar's meter recorded, so a long
 * frame can be attributed and the recording replayed (shell/dev/perf/replay.sh). Started and stopped by the bar
 * (fpsmeter.tsx) through the "perf.meter" store key ({on, rec: id} while recording, the host broadcasts it); at the end
 * the detail goes back to the bar in parts over perf.publish (each < 8 KB, the host's limit) and the bar puts it into
 * the one saved recording as `home`.
 *
 * Detail: snapshot (what the page needs to look the same: viewport, mode, home layout, dock, stored settings, store
 * keys, open screens, data counts), inputs (pointer down/up every one, moves at most one per frame, keys), state (the
 * shell's signal transitions with t), loaf (long-animation-frame with its render/style split and scripts[]), evt
 * (event timing: input delay / processing / presentation). t = ms since the recording started (this page's clock).
 * Costs while recording: listeners and effects only, every list capped; nothing per frame.
 *
 * Pre-roll (the user: "i sent it like 10 times and nothing improves"): the jank is usually what made them tap record,
 * so it happened BEFORE the tap. While the meter is on (armed) the same listeners, LoAF/event observers and the JS
 * sampling profiler (jsprofile.ts) run into rings of the last PRE_MS; the record tap re-times them onto the
 * recording's clock (negative t) and keeps going. Meter off = nothing armed.
 * frames: the trace's verdict per long frame - JS / forced layout / render step / not JS - with the scripts, the
 * Preact handlers that ran (renderscan.ts), the components that rendered and the JS stacks sampled in it (jsprofile.ts):
 * docs/research/shell-perf-traces.md reads it.
 */
import { effect } from "@preact/signals";
import { powos } from "../bridge.ts";
import * as S from "../state.ts";
import * as G from "./gesture.ts";
import { wideHome } from "../hosts/wide.ts";
import { sessions } from "../agents.ts";
import { notifList } from "./notifications.tsx";
import { board } from "./powai.tsx";
import { loafEntry, type Loaf } from "./loaf.ts";
import { renderReport, reset as resetScan, scanClock, startScan, stopScan } from "./renderscan.ts";
import { profileReport, recordProfile, startProfile, stopProfile } from "./jsprofile.ts";

const MAX_INPUTS = 4000, MAX_STATE = 2000, MAX_LOAF = 300, MAX_EVT = 300, MAX_REC_MS = 125_000, PART = 2500;
/** How much of what happened before the record tap a recording keeps (the armed rings). */
export const PRE_MS = 8000;
const STORE_KEYS = ["dock", "home.wide", "controls.launchers", "controls.layout", "glasses"];

let id = 0, t0 = 0, lastMove = -1e9, stopTimer = 0;
let inputs: (number | string)[][] = [], state: [number, string, unknown][] = [], loaf: Loaf[] = [], evt: unknown[] = [];
let snapshot: Record<string, unknown> = {}, offs: (() => void)[] = [], armed = false, pruneTimer = 0, preMs = 0;
const now = () => Math.round((performance.now() - t0) * 10) / 10;

const POINTER_KIND: Record<string, string> = { pointerdown: "d", pointerup: "u", pointercancel: "c" };
/** Moves are thinned to one per 7 ms, and touch/pen moves without a button down are hover: skipped. */
function keepMove(e: PointerEvent, t: number) {
  if (t - lastMove < 7 || !e.buttons && e.pointerType !== "mouse") return false;
  lastMove = t;
  return true;
}
function onPointer(e: PointerEvent) {
  if (inputs.length >= MAX_INPUTS) return;
  const t = now(), k = POINTER_KIND[e.type] ?? "m";
  if (k === "m" && !keepMove(e, t)) return;
  inputs.push([t, k, Math.round(e.clientX * 10) / 10, Math.round(e.clientY * 10) / 10, e.pointerType, e.pointerId]);
}
function onKey(e: KeyboardEvent) { if (inputs.length < MAX_INPUTS) inputs.push([now(), "k", e.key, e.code]); }
const onResize = () => note("viewport", [innerWidth, innerHeight, devicePixelRatio]);

function note(k: string, v: unknown) { if (state.length < MAX_STATE) state.push([now(), k, v]); }

/** The shell's signals (state.ts, gesture.ts, wide.ts). Drag values change per frame: recorded as on/off only. */
const watched: [string, () => unknown][] = [
  ["page", () => S.page.value], ["drawer", () => S.drawer.value], ["pullKind", () => S.pullKind.value], ["notif", () => S.notif.value],
  ["panel", () => S.panel.value], ["chatting", () => S.chatting.value], ["editing", () => S.editing.value], ["folder", () => S.folder.value],
  ["screen", () => S.screen.value.key], ["menu", () => !!S.menu.value], ["session", () => S.sessionView.value?.name ?? null],
  ["carry", () => S.carry.value?.app ?? S.carry.value?.item?.key ?? null], ["dockDrag", () => !!S.dockDrag.value], ["windows", () => S.windows.value.length],
  ["wide", () => wideHome.value], ["drawerDrag", () => G.drawerDrag.value != null], ["notifDrag", () => G.notifDrag.value != null],
  ["pageDrag", () => G.pageDrag.value != null], ["held", () => G.held.value], ["shadeTakesHome", () => G.shadeTakesHome.value],
];

function snap(): Record<string, unknown> {
  const stored: Record<string, string> = {};
  try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i)!; if (k.startsWith("powos.")) stored[k] = (localStorage.getItem(k) ?? "").slice(0, 4000); } } catch { /* no storage */ }
  const root = document.documentElement, css: Record<string, string> = {};
  for (const p of Array.from(root.style)) if (p.startsWith("--")) css[p] = root.style.getPropertyValue(p).trim();
  const items = notifList.value.items ?? [];
  return {
    viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio }, url: location.search, mode: root.dataset.mode ?? "home",
    htmlClass: root.className, light: root.dataset.light, css, host: powos.host,
    state: Object.fromEntries(watched.map(([k, f]) => [k, f()])),
    home: S.home.value, dock: S.dock.value, desktopPages: S.desktopPages.value, stored, store: {} as Record<string, unknown>,
    counts: { apps: S.apps.value.length, notifications: items.length, agents: sessions.value.length, board: board.value.length, chat: S.chat.value.items.length, windows: S.windows.value.length },
    notifications: items.length <= 20 ? items.map((n) => ({ ...n, icon: undefined })) : undefined,
  };
}

export function recording() { return id !== 0; }

/** Every time in the lists moved by [d] ms (a new t0); 0 stays 0 (loafEntry's "none"). */
function shiftAll(d: number) {
  const m = (v: number) => (v ? Math.round((v + d) * 10) / 10 : v);
  for (const x of inputs) x[0] = m(x[0] as number);
  for (const x of state) x[0] = m(x[0]);
  for (const l of loaf) { l.start = m(l.start); l.render = m(l.render); l.style = m(l.style); l.firstUI = m(l.firstUI); for (const sc of l.scripts) sc.start = m(sc.start); }
  for (const e of evt as { start: number }[]) e.start = m(e.start);
}
/** Armed and not recording: what is older than PRE_MS goes. */
function prune() {
  const from = now() - PRE_MS;
  inputs = inputs.filter((x) => (x[0] as number) >= from); state = state.filter((x) => x[0] >= from);
  loaf = loaf.filter((l) => l.start + l.dur >= from); evt = evt.filter((e) => (e as { start: number }).start >= from);
}

/** The meter is on: listen into the pre-roll rings (no-op when already). */
function arm() {
  if (armed) return;
  armed = true; t0 = performance.now(); lastMove = -1e9;
  inputs = []; state = []; loaf = []; evt = [];
  listen();
  startProfile(true);
  pruneTimer = window.setInterval(() => { if (!id) prune(); }, 2000);
}
function disarm() {
  if (!armed || id) return;
  armed = false;
  clearInterval(pruneTimer);
  offs.forEach((o) => o()); offs = [];
  inputs = []; state = []; loaf = []; evt = [];
  void stopProfile();
}

export function begin(recId: number) {
  if (id) return;
  arm();
  prune();
  const t1 = performance.now();
  preMs = Math.round(t1 - t0);
  shiftAll(t0 - t1);
  id = recId; t0 = t1;
  snapshot = snap();
  void Promise.all(STORE_KEYS.map(async (k) => [k, await powos.store.get(k).catch(() => null)] as const))
    .then((kv) => { (snapshot.store as Record<string, unknown>) = Object.fromEntries(kv); });
  startScan("rec"); resetScan(PRE_MS); // render scan (renderscan.ts): which components rendered, needless ones, per long frame; an overlay scan's last PRE_MS kept
  void recordProfile();
  stopTimer = window.setTimeout(() => end(), MAX_REC_MS);
}

function listen() {
  const opts = { capture: true, passive: true };
  for (const t of ["pointerdown", "pointermove", "pointerup", "pointercancel"]) window.addEventListener(t, onPointer as EventListener, opts);
  window.addEventListener("keydown", onKey, opts); window.addEventListener("resize", onResize);
  offs = [() => {
    for (const t of ["pointerdown", "pointermove", "pointerup", "pointercancel"]) window.removeEventListener(t, onPointer as EventListener, opts);
    window.removeEventListener("keydown", onKey, opts); window.removeEventListener("resize", onResize);
  }];
  for (const [k, f] of watched) {
    let first = true;
    offs.push(effect(() => { const v = f(); if (first) first = false; else note(k, v); }));
  }
  const mo = new MutationObserver(() => note("mode", document.documentElement.dataset.mode));
  mo.observe(document.documentElement, { attributes: true, attributeFilter: ["data-mode"] });
  offs.push(() => mo.disconnect());
  try {
    const po = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        if (e.entryType === "long-animation-frame") { if (loaf.length < MAX_LOAF) loaf.push(loafEntry(e, t0)); }
        else if (evt.length < MAX_EVT) {
          const x = e as PerformanceEventTiming;
          evt.push({ name: x.name, start: Math.round(x.startTime - t0), dur: Math.round(x.duration),
            delay: Math.round(x.processingStart - x.startTime), proc: Math.round(x.processingEnd - x.processingStart) });
        }
      }
    });
    try { po.observe({ type: "long-animation-frame", buffered: false }); } catch { /* not supported */ }
    try { po.observe({ type: "event", durationThreshold: 16, buffered: false } as PerformanceObserverInit); } catch { /* not supported */ }
    offs.push(() => po.disconnect());
  } catch { /* no PerformanceObserver */ }
}

/** Stops and sends the detail to the bar: { recPart: i, of: n, rec: id, data } over perf.publish. */
export async function end() {
  if (!id) return;
  clearTimeout(stopTimer);
  const renders = rendersSection();
  stopScan("rec");
  const rec = id, dur = Math.round(performance.now() - t0), tz = t0;
  const lists = { inputs, state, loaf, evt, snapshot };
  // Re-armed at once (meter still on): the next recording's pre-roll starts here, the lists above are this one's.
  armed = false; clearInterval(pruneTimer); offs.forEach((o) => o()); offs = [];
  inputs = []; state = []; loaf = []; evt = []; snapshot = {};
  id = 0;
  const prof = await stopProfile().catch(() => null);
  if (meterOn && !id) arm();
  let json: string;
  try {
    const js = profileReport(prof, longest(lists.loaf), tz);
    json = JSON.stringify({ v: 2, durationMs: dur, preRollMs: preMs, snapshot: lists.snapshot, inputs: lists.inputs, state: lists.state, loaf: lists.loaf, evt: lists.evt, renders,
      js, frames: frameVerdicts(lists.loaf, renders, js),
      capped: { inputs: lists.inputs.length >= MAX_INPUTS, state: lists.state.length >= MAX_STATE, loaf: lists.loaf.length >= MAX_LOAF, evt: lists.evt.length >= MAX_EVT } });
  } catch (e) { json = JSON.stringify({ v: 2, error: `home's detail could not be serialised: ${e}` }); } // still answer the bar
  send(rec, json);
}

/** The long frames worth reading: 50 ms and over, longest first, at most 12. */
function longest(l: Loaf[]) { return [...l].filter((x) => x.dur >= 50).sort((a, b) => b.dur - a.dur).slice(0, 12); }

type Js = ReturnType<typeof profileReport>;
type Renders = ReturnType<typeof rendersSection>;
/**
 * Per long frame what it was made of and what to fix: "js" (script most of it; "forced layout" when a layout read in
 * the script waited for style/layout - a read after a write), "render" (the frame's own style/layout/paint step: a big
 * DOM or style change), or "not-js" (the page did little: the main thread waited - GPU/raster backpressure or the
 * Android UI thread: read the native section). With the scripts, the Preact handlers and components in it, and the
 * JS stacks sampled in it.
 */
export function frameVerdicts(l: Loaf[], renders: Renders, js: Js) {
  const rf = "jankyFrames" in (renders ?? {}) ? (renders as { jankyFrames: RF[] }).jankyFrames : [];
  const jf = ("frames" in js ? js.frames : undefined) ?? [];
  return longest(l).map((x) => frameRow(x, rf.find((f) => f.start === x.start), jf.find((f) => f.start === x.start)));
}
type RF = { start: number; components: string; renderMs: number; handlers?: string[] };
/** What the frame's time went to: script ("forced layout" when a third of it waited on layout), the render step, or neither. */
function verdictOf(dur: number, script: number, forced: number, renderStep: number) {
  if (script >= dur * 0.4) return forced >= script * 0.3 ? "js: forced layout" : "js";
  return renderStep >= dur * 0.4 ? "render" : "not-js";
}
function frameRow(x: Loaf, r: RF | undefined, p: { stacks: { ms: number; at: string }[] } | undefined) {
  const end = x.start + x.dur, script = x.scripts.reduce((a, b) => a + b.dur, 0), forced = x.scripts.reduce((a, b) => a + b.forced, 0);
  const renderStep = x.render ? end - x.render : 0, styleLayout = x.style ? end - x.style : 0;
  return { start: x.start, dur: x.dur, verdict: verdictOf(x.dur, script, forced, renderStep), script, forced, renderStep, styleLayout,
    scripts: scriptLines(x), ...inFrame(r), stacks: p?.stacks ?? [] };
}
const scriptLines = (x: Loaf) =>
  [...x.scripts].sort((a, b) => b.dur - a.dur).slice(0, 3).map((s) => `${s.type} ${s.invoker} ${s.src}${s.fn ? ":" + s.fn : ""} ${s.dur}ms forced ${s.forced}ms`);
/** The render scan's view of the frame: the handlers that ran, the components that rendered, their time. */
const inFrame = (r: RF | undefined) => ({ handlers: r?.handlers ?? [], components: r?.components ?? "", renderMs: r?.renderMs ?? 0 });

/** The render scan's report, each long frame's renders on this recording's clock (the scan may have started earlier: the overlay). */
function rendersSection() {
  try { return renderReport(loaf, scanClock() - t0); } catch (e) { return { error: String(e) }; }
}

/** The detail to the bar in parts (each < the host's 8 KB per perf.publish). */
function send(rec: number, json: string) {
  const n = Math.ceil(json.length / PART);
  for (let i = 0; i < n; i++)
    void powos.perf?.publish?.(JSON.stringify({ rec, recPart: i, of: n, data: json.slice(i * PART, (i + 1) * PART) }))?.catch?.(() => {});
}

/**
 * The "perf.meter" value: {on, rec} starts a recording here, rec gone ends it. The bar's stop carries {stop: id}: if
 * this page wasn't recording that one (it missed the start, or reloaded since), it still answers, saying so, instead
 * of leaving the bar to time out.
 */
let meterOn = false;
/** The meter on: the pre-roll armed; off: nothing runs. */
function follow(on: boolean) {
  meterOn = on;
  if (on) arm(); else disarm();
}
export function onMeter(v: { on?: boolean; rec?: number; stop?: number } | null) {
  follow(!!v?.on);
  record(v);
}
function record(v: { rec?: number; stop?: number } | null) {
  const r = Number(v?.rec) || 0;
  if (r && r !== id) restart(r);
  else if (!r && id) void end();
  else if (!r && v?.stop) send(Number(v.stop), MISSED);
}
const MISSED = JSON.stringify({ v: 1, missed: "home was not recording this one (it missed the start or reloaded since)" });
/** A new recording: at once when none runs (the tap's moment is the pre-roll's end), else after the old one is sent. */
function restart(r: number) {
  const go = () => { try { begin(r); } catch (e) { console.error("perfrec begin", e); } }; // id is set: the stop still answers
  if (!id) go(); else void end().then(go);
}
