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

const MAX_INPUTS = 4000, MAX_STATE = 2000, MAX_LOAF = 300, MAX_EVT = 300, MAX_REC_MS = 125_000, PART = 2500;
const STORE_KEYS = ["dock", "home.wide", "controls.launchers", "controls.layout", "glasses"];

let id = 0, t0 = 0, lastMove = -1e9, stopTimer = 0;
let inputs: (number | string)[][] = [], state: [number, string, unknown][] = [], loaf: Loaf[] = [], evt: unknown[] = [];
let snapshot: Record<string, unknown> = {}, offs: (() => void)[] = [];
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

export function begin(recId: number) {
  if (id) return;
  id = recId; t0 = performance.now(); lastMove = -1e9;
  inputs = []; state = []; loaf = []; evt = [];
  snapshot = snap();
  void Promise.all(STORE_KEYS.map(async (k) => [k, await powos.store.get(k).catch(() => null)] as const))
    .then((kv) => { (snapshot.store as Record<string, unknown>) = Object.fromEntries(kv); });
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
  startScan("rec"); resetScan(); // render scan (renderscan.ts): which components rendered, needless ones, per long frame
  offs.push(() => stopScan("rec"));
  stopTimer = window.setTimeout(() => end(), MAX_REC_MS);
}

/** Stops and sends the detail to the bar: { recPart: i, of: n, rec: id, data } over perf.publish. */
export function end() {
  if (!id) return;
  clearTimeout(stopTimer);
  const renders = rendersSection();
  offs.forEach((o) => o()); offs = [];
  const rec = id; id = 0;
  let json: string;
  try {
    json = JSON.stringify({ v: 1, durationMs: Math.round(performance.now() - t0), snapshot, inputs, state, loaf, evt, renders,
    capped: { inputs: inputs.length >= MAX_INPUTS, state: state.length >= MAX_STATE, loaf: loaf.length >= MAX_LOAF, evt: evt.length >= MAX_EVT } });
  } catch (e) { json = JSON.stringify({ v: 1, error: `home's detail could not be serialised: ${e}` }); } // still answer the bar
  inputs = []; state = []; loaf = []; evt = []; snapshot = {};
  send(rec, json);
}

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
export function onMeter(v: { on?: boolean; rec?: number; stop?: number } | null) {
  const r = Number(v?.rec) || 0;
  if (r && r !== id) restart(r);
  else if (!r && id) end();
  else if (!r && v?.stop) send(Number(v.stop), MISSED);
}
const MISSED = JSON.stringify({ v: 1, missed: "home was not recording this one (it missed the start or reloaded since)" });
function restart(r: number) {
  end();
  try { begin(r); } catch (e) { console.error("perfrec begin", e); } // id is set: the stop still answers
}
