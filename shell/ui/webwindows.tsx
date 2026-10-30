// Web windows: an Android app's window over home (unfolded; off unless Settings.Global powos_web_windows = 1).
// The user, 2026-10-29: "the powos home typescript should deal with the windows and their content", "it should be
// pinned to a page properly natively". This file is the windows' MODEL: page, position, size, scale, z-order (list
// order), minimised/maximised. The host (WebWindows.kt) draws each window natively ABOVE home's surface: the app's own
// buffers (the display's mirror) plus a native frame and title bar (icon, title, minimise, full screen, close), as one
// layer stack - the user, 2026-10-30: "nobody asked for the cutoff" (the old page mask), widgets under a window are
// never altered. The page renders each window as an INVISIBLE element at its place (gesture exclusions, the body's
// touches to the app); the host moves, resizes and scales the window itself under the finger (title bar, edges, two
// fingers) and tells this file where it ended ("webwindows.moved"), so the bar and the content can't lag each other.
import { signal } from "@preact/signals";
import { useRef } from "preact/hooks";
import { native, nextFrameId, send } from "../apps/port.ts";
import { powos } from "../bridge.ts";
import { wideHome } from "../hosts/wide.ts";

const TITLE = 36;
const RADIUS = 12;

export interface WebWin {
  id: number;
  key: string;
  label: string;
  /** The home page (its number, as pages lists them) it's pinned to. */
  page: number;
  /** Its frame in the page, CSS px. */
  x: number;
  y: number;
  w: number;
  h: number;
  /** Two fingers on its bar or edge zoom the whole window (the host's layer matrix; the app keeps its resolution). */
  scale?: number;
  /** Off its page, in the dock (a tap on the dock icon brings it back: openWebWindow). */
  minimised?: boolean;
  /** Filling the work area (above the dock); the frame to go back to. */
  restore?: { x: number; y: number; w: number; h: number };
  /**
   * Its app is a real full-screen app on the main display now (its bar's full screen button, WebWindows.fullScreen):
   * the window is hidden, its place kept; "Back to window" on its switcher card brings it back here.
   */
  full?: boolean;
  /** Its app's task, once the host told it ("webwindows.full"). */
  task?: number;
  /** In a tile (see "Tiles" below): the floating frame it had before, where "float" puts it back. */
  untiled?: { x: number; y: number; w: number; h: number };
}

/** The home page on screen (its number), as state.ts knows it: where the switcher's split screen tiles. */
let shownPage = () => 1;
export function setShownPage(f: () => number) {
  shownPage = f;
}

/** Bottom first: the last one is on top. */
export const webWins = signal<WebWin[]>([]);

let checkedAt = 0;
let on = false;

async function enabled(): Promise<boolean> {
  const ww = powos.webwindows;
  if (!ww) return false;
  if (Date.now() - checkedAt > 5000) {
    on = await ww.enabled().catch(() => false);
    checkedAt = Date.now();
  }
  return on;
}

/** Web windows can open here (unfolded, the setting on): the switcher's split screen tiles instead of Android's split. */
export async function webWindowsOn(): Promise<boolean> {
  return wideHome.value && (await enabled());
}

/** Opens an Android app as a home element on [page] (unfolded, the setting on): false leaves the launch to the caller. */
export async function openWebWindow(key: string, label: string, page: number): Promise<boolean> {
  return (await openWindow(key, label, page)) != null;
}

/** [openWebWindow], with the window's id (null: not a window). A page tiling with an empty tile puts it there. */
export async function openWindow(key: string, label: string, page: number): Promise<number | null> {
  if (!wideHome.value || !key.startsWith("a:") || !(await enabled())) return null;
  // Already a window: it comes to this page, on top - never a second display for the same app (its task would move).
  const open = webWins.value.find((w) => w.key === key);
  // A full-screen app now: it comes to the front as one (never a second window).
  if (open?.full && powos.webwindows?.fullScreen) {
    void powos.webwindows.fullScreen(open.id);
    return open.id;
  }
  if (open) {
    update(open.id, { page, minimised: false });
    raise(open.id);
    return open.id;
  }
  const n = webWins.value.length;
  const w = Math.round(innerWidth * 0.5);
  const h = Math.round(innerHeight * 0.6);
  const x = 48 + 32 * (n % 6);
  const y = 72 + 32 * (n % 6);
  // Its first rect is a guess; the element reports its real one on its first frame.
  const id = await powos.webwindows!.open(key, { left: x, top: y + TITLE, width: w, height: h - TITLE }).catch(() => -1);
  if (id < 0) return null;
  webWins.value = [...webWins.value, { id, key, label, page, x, y, w, h }];
  fillEmptyTile(page, id);
  return id;
}

/** The pointer kept by its element (a synthetic or already-ended pointer can't be: the drag still works). */
function capture(e: PointerEvent) {
  try {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  } catch {}
}

export function update(id: number, change: Partial<WebWin>) {
  webWins.value = webWins.value.map((w) => (w.id === id ? { ...w, ...change } : w));
}

export function raise(id: number) {
  const list = webWins.value;
  if (list[list.length - 1]?.id === id) return;
  const win = list.find((w) => w.id === id);
  if (!win) return;
  webWins.value = [...list.filter((w) => w.id !== id), win];
}

powos.on("webwindows.closed", (id: number) => {
  untile(id, "gone");
  webWins.value = webWins.value.filter((w) => w.id !== id);
});
/** Home to a page (by its number, as pages lists them): state.ts sets it (it imports this file, not the reverse). */
let toPage: (page: number) => void = () => {};
export function onWebWindowPage(f: (page: number) => void) {
  toPage = f;
}

/** Window [id] shown where it was: not minimised, on top, home on its page. */
function bringBack(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  update(id, { minimised: false });
  raise(id);
  toPage(w.page);
}

/** Its app became a full-screen app (the window hides, its place kept) or is back in the window (shown on its page). */
powos.on("webwindows.full", (m: { id: number; on: boolean; task?: number }) => {
  // A tile going full screen leaves its tile (the others close up); back in a window, it floats at its old frame.
  if (m.on) untile(m.id, "float");
  update(m.id, { full: m.on, task: m.task ?? webWins.value.find((w) => w.id === m.id)?.task, minimised: false });
  if (!m.on) bringBack(m.id);
});
/** Its switcher card tapped (ShellBridge.openTask): back where it was, floating, on its page. */
powos.on("webwindows.show", (id: number) => bringBack(id));

// ---- the work area, and the host's events ----------------------------------------------------------------------------

/**
 * Where windows may be, viewport CSS px: the screen above home's foot (the dock and the bar - windows never cover
 * them, a desktop's reserved dock strip). Maximise fills it; the host clamps moves and resizes to it and crops a window
 * at its bottom.
 */
export function workArea(): { left: number; top: number; right: number; bottom: number } {
  let bottom = innerHeight;
  for (const el of document.querySelectorAll<HTMLElement>(".home > .dock, .home > .bar")) {
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.top > innerHeight / 2) bottom = Math.min(bottom, r.top);
  }
  return { left: 0, top: 0, right: innerWidth, bottom };
}

/**
 * Where tiles go: the work area below the status bar (a window's own bar under it couldn't be grabbed - the status
 * bar is a window above home's) and a gap above the dock.
 */
export function tileArea(): Area {
  const a = workArea();
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 0;
  return { ...a, top: Math.max(a.top, inset), bottom: a.bottom - TILE_GAP };
}

/** The page element's top left on screen (windows are page-local): the page on screen's. */
function pageOrigin(): { x: number; y: number } {
  const r = document.querySelector(".page:not(.away)")?.getBoundingClientRect();
  return r ? { x: r.left, y: r.top } : { x: 0, y: 0 };
}

/** Fills the work area, or goes back to where it was. */
export function toggleMaximise(id: number) {
  // A tile goes full screen as a free window (its tile closes up); restore brings back its floating frame.
  if (tiledOn(id) != null) untile(id, "float");
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  if (w.restore) return update(id, { ...w.restore, restore: undefined });
  const a = workArea();
  const o = pageOrigin();
  update(id, { x: a.left - o.x, y: a.top - o.y, w: a.right - a.left, h: a.bottom - a.top, scale: 1, restore: { x: w.x, y: w.y, w: w.w, h: w.h } });
  raise(id);
}

export function minimise(id: number) {
  if (tiledOn(id) != null) return untile(id, "minimise");
  update(id, { minimised: true });
}

const isResized = (m: { dw?: number; dh?: number }) => !!m.dw || !!m.dh;

/** The host's move/resize/zoom under the finger ended (CSS px deltas): the model takes the place it left the window at. */
powos.on("webwindows.moved", (m: { id: number; dx: number; dy: number; dw?: number; dh?: number; scale?: number }) => {
  const w = webWins.value.find((v) => v.id === m.id);
  if (!w) return;
  const moved = m.dx !== 0 || m.dy !== 0 || isResized(m);
  // Dragged out of its tile (not onto an edge: that's "webwindows.tile"): a free window where it was let go.
  if (moved && tiledOn(m.id) != null) untile(m.id, "keep");
  update(m.id, {
    x: w.x + m.dx,
    y: w.y + m.dy,
    w: w.w + (m.dw ?? 0),
    h: w.h + (m.dh ?? 0),
    scale: m.scale ?? w.scale,
    // Moved or resized out of its maximised frame: a free window again (its size kept), as Android's.
    restore: moved ? undefined : w.restore,
  });
});
/** A press on its native bar or edge: on top. */
powos.on("webwindows.raise", (id: number) => raise(id));
/** Its bar's minimise / full screen buttons, or a double tap on the bar. */
powos.on("webwindows.control", (m: { id: number; action: string }) => {
  if (m.action === "minimise") minimise(m.id);
  else if (m.action === "maximise") toggleMaximise(m.id);
});

/** The windows pinned to home page [page] (not minimised), and its tiles' dividers: invisible elements in that page. */
export function WebWindowsOn({ page }: { page: number }) {
  const here = webWins.value.filter((w) => w.page === page && !w.minimised && !w.full);
  if (!here.length) return null;
  const t = tilings.value[page];
  const o = pageOrigin();
  return (
    <>
      {here.map((w) => (
        <WebWindowEl key={w.id} win={w} z={webWins.value.indexOf(w)} />
      ))}
      {t && dividers(t, tileArea()).map((d) => <DividerEl key={d.axis} page={page} d={d} o={o} />)}
    </>
  );
}

// ---- tiles -------------------------------------------------------------------------------------------------------------
//
// PowOS's own split screen (the user, 2026-10-30: "lets take full control and replace that too so we can unlock our
// own splitscreen capabilities maybe with like 3 of 4 apps at once"). A tiling is a state of one page's windows: a
// layout and which window is in which tile (a window in one is "tiled", the rest float above or below as usual). The
// windows' frames are the tiles' rects (the model stays x/y/w/h, so the host needs nothing new to place them); the
// dividers between tiles are the host's (native, like the bar): it moves them under the finger and reports the new
// split ("webwindows.divider"). docs/WEB_WINDOWS.md "Tiles".

/** "2h" left | right, "2v" top / bottom, "3" one big left + two stacked right, "4" a 2x2 grid. */
export type Layout = "2h" | "2v" | "3" | "4";
export interface Tiling {
  layout: Layout;
  /** Window per tile, in [SLOTS] order; null: an empty tile (the next window opened on the page goes there). */
  ids: (number | null)[];
  /** The vertical divider's place (share of the work area's width) and the horizontal one's (of its height). */
  rx: number;
  ry: number;
}
export type Slot = "left" | "right" | "top" | "bottom" | "tl" | "tr" | "bl" | "br" | "grid" | "float";
const SLOTS: Record<Layout, string[]> = { "2h": ["left", "right"], "2v": ["top", "bottom"], "3": ["left", "rtop", "rbottom"], "4": ["tl", "tr", "bl", "br"] };
/** Between tiles (CSS px): home shows through, the host's divider handle sits in it. */
export const TILE_GAP = 8;

/** Per home page (its number, as pages lists them). */
export const tilings = signal<Record<number, Tiling>>({});

interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}
type Area = ReturnType<typeof workArea>;

/**
 * Two apps split left | right unless the work area is clearly portrait: the unfolded screen (2268x2440) is portrait by
 * a hair and the user wants left | right there (2026-10-29: "two on top and bottom instead of one on the left, one on
 * the right" was the complaint about Android's split).
 */
const portrait = (a: Area) => a.bottom - a.top > 1.3 * (a.right - a.left);
const layoutFor = (n: number, a: Area): Layout => (n >= 4 ? "4" : n === 3 ? "3" : portrait(a) ? "2v" : "2h");

/** Each tile's rect, viewport CSS px, in [SLOTS] order. */
export function tileRects(t: Tiling, a: Area): Box[] {
  const g = TILE_GAP / 2;
  const xs = a.left + (a.right - a.left) * t.rx;
  const ys = a.top + (a.bottom - a.top) * t.ry;
  const r = (l: number, top: number, right: number, b: number): Box => ({ x: l, y: top, w: right - l, h: b - top });
  if (t.layout === "2h") return [r(a.left, a.top, xs - g, a.bottom), r(xs + g, a.top, a.right, a.bottom)];
  if (t.layout === "2v") return [r(a.left, a.top, a.right, ys - g), r(a.left, ys + g, a.right, a.bottom)];
  if (t.layout === "3") return [r(a.left, a.top, xs - g, a.bottom), r(xs + g, a.top, a.right, ys - g), r(xs + g, ys + g, a.right, a.bottom)];
  return [r(a.left, a.top, xs - g, ys - g), r(xs + g, a.top, a.right, ys - g), r(a.left, ys + g, xs - g, a.bottom), r(xs + g, ys + g, a.right, a.bottom)];
}

/**
 * A divider (viewport CSS px): a vertical one ("x") is the line at [pos] from [from] for [len]; [lo]..[hi] is the span
 * its ratio is of. [before]/[after]: the windows whose right (bottom) and left (top) edges follow it.
 */
export interface Divider {
  axis: "x" | "y";
  pos: number;
  from: number;
  len: number;
  lo: number;
  hi: number;
  before: number[];
  after: number[];
}

export function dividers(t: Tiling, a: Area): Divider[] {
  const at = (slots: number[]) => slots.map((i) => t.ids[i]).filter((v): v is number => v != null);
  const W = a.right - a.left;
  const H = a.bottom - a.top;
  const xs = a.left + W * t.rx;
  const ys = a.top + H * t.ry;
  const v = (before: number[], after: number[]): Divider => ({ axis: "x", pos: xs, from: a.top, len: H, lo: a.left, hi: a.right, before: at(before), after: at(after) });
  const h = (from: number, len: number, before: number[], after: number[]): Divider => ({ axis: "y", pos: ys, from, len, lo: a.top, hi: a.bottom, before: at(before), after: at(after) });
  if (t.layout === "2h") return [v([0], [1])];
  if (t.layout === "2v") return [h(a.left, W, [0], [1])];
  if (t.layout === "3") return [v([0], [1, 2]), h(xs + TILE_GAP / 2, a.right - xs - TILE_GAP / 2, [1], [2])];
  return [v([0, 2], [1, 3]), h(a.left, W, [0, 1], [2, 3])];
}

/** The page whose tiling holds window [id], or null (it floats). */
export function tiledOn(id: number): number | null {
  for (const [p, t] of Object.entries(tilings.value)) if (t.ids.includes(id)) return Number(p);
  return null;
}

function setTiling(page: number, t: Tiling | null) {
  const next = { ...tilings.value };
  if (t && t.ids.some((v) => v != null)) next[page] = t;
  else delete next[page];
  tilings.value = next;
  if (t) relayout(page);
}

/** The page's tiled windows put at their tiles (full size, unzoomed, shown). */
function relayout(page: number) {
  const t = tilings.value[page];
  if (!t) return;
  const o = pageOrigin();
  const rects = tileRects(t, tileArea());
  webWins.value = webWins.value.map((w) => {
    const i = t.ids.indexOf(w.id);
    if (i < 0) return w;
    const r = rects[i];
    const untiled = w.untiled ?? w.restore ?? { x: w.x, y: w.y, w: w.w, h: w.h };
    return { ...w, x: Math.round(r.x - o.x), y: Math.round(r.y - o.y), w: Math.round(r.w), h: Math.round(r.h), scale: 1, restore: undefined, minimised: false, untiled };
  });
}

/** Floating windows on [page] other than [skip], topmost first. */
const floatingOn = (page: number, skip: number[]) =>
  webWins.value.filter((w) => w.page === page && !w.minimised && !w.full && !skip.includes(w.id)).map((w) => w.id).reverse();

/**
 * Window [id] into tile [slot] of its page (the title bar's tile menu, a drag to a screen edge or corner): a half makes
 * a 2-split, a corner a 2x2 grid, "grid" tiles it with the page's other windows (2-4: the layout follows the count),
 * "float" takes it out. The page's other tiled windows keep a tile while there is one; an empty half of a new 2-split
 * takes the page's topmost floating window (two windows, one split - as Android's), an empty corner stays empty.
 */
export function tile(id: number, slot: Slot) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  if (slot === "float") return untile(id, "float");
  const page = w.page;
  const others = (tilings.value[page]?.ids ?? []).filter((v): v is number => v != null && v !== id);
  const { layout, ids } = slot === "grid" ? gridOf(page, id, others) : slotOf(page, id, slot, others);
  // Tiled windows that found no tile float again.
  const left = others.filter((o) => !ids.includes(o));
  setTiling(page, { layout, ids, rx: 0.5, ry: 0.5 });
  for (const o of left) refloat(o);
  console.info(`[tiles] page ${page}: ${layout} [${ids.join(",")}] (${slot} for window ${id})`);
}

/**
 * The switcher's split screen with web windows on (the user, 2026-10-30: "like 3 of 4 apps at once"): [apps] (2-4, by
 * key) opened as web windows on the home page on screen and tiled in that order. False when one can't be a web window
 * (not resizeable, ...): the caller uses Android's split.
 */
export async function tileApps(apps: { key: string; label: string }[]): Promise<boolean> {
  const page = shownPage();
  const ids: number[] = [];
  for (const a of apps.slice(0, 4)) {
    const id = await openWindow(a.key, a.label, page);
    if (id == null) {
      console.info(`[tiles] ${a.key} can't be a web window: Android's split instead`);
      return false;
    }
    // A full-screen app out of a window: back into it first, then tiled.
    if (webWins.value.find((w) => w.id === id)?.full && powos.webwindows?.toWindow) {
      await powos.webwindows.toWindow(id).catch(() => false);
      update(id, { full: false });
    }
    ids.push(id);
  }
  tileWindows(page, ids);
  return true;
}

/** "grid": [id] first, then the page's tiled windows, then its floating ones (topmost first), up to 4. */
function gridOf(page: number, id: number, others: number[]): { layout: Layout; ids: (number | null)[] } {
  const all = [id, ...others, ...floatingOn(page, [id, ...others])].slice(0, 4);
  const layout = all.length >= 2 ? layoutFor(all.length, tileArea()) : "4";
  return { layout, ids: SLOTS[layout].map((_, i) => all[i] ?? null) };
}

const HALVES: Record<string, Layout> = { left: "2h", right: "2h", top: "2v", bottom: "2v" };

/** A half or a corner: [id] there, the other tiled windows in the rest (a half: then the topmost floating one). */
function slotOf(page: number, id: number, slot: Slot, others: number[]): { layout: Layout; ids: (number | null)[] } {
  const layout = HALVES[slot] ?? "4";
  const ids: (number | null)[] = SLOTS[layout].map((s) => (s === slot ? id : null));
  const fill = layout === "4" ? others : [...others, ...floatingOn(page, [id, ...others])];
  for (const o of fill) {
    const i = ids.indexOf(null);
    if (i < 0) break;
    ids[i] = o;
  }
  return { layout, ids };
}

/** Windows [ids] (2-4, in order) tiled on page [page]: the switcher's split screen. */
export function tileWindows(page: number, ids: number[]) {
  const list = ids.slice(0, 4);
  if (!list.length) return;
  const layout = layoutFor(Math.max(2, list.length), tileArea());
  for (const id of list) update(id, { page });
  setTiling(page, { layout, ids: SLOTS[layout].map((_, i) => list[i] ?? null), rx: 0.5, ry: 0.5 });
  console.info(`[tiles] page ${page}: ${layout} [${list.join(",")}] (split screen)`);
}

/** Back to its floating frame, on top. */
function refloat(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  update(id, { ...(w.untiled ?? {}), untiled: undefined });
  raise(id);
}

/**
 * Window [id] out of its tiling: "float" back to its floating frame, "minimise" to the dock (its frame the floating
 * one), "keep" where it is now (dragged out), "gone" (closed). The others close up: 2-4 take the layout for their
 * count, a last one alone fills the work area (as Android's split ending: the other app full screen; restore gives
 * its floating frame back).
 */
function untile(id: number, how: "float" | "minimise" | "keep" | "gone") {
  const page = tiledOn(id);
  if (page == null) return;
  const t = tilings.value[page];
  const rest = t.ids.filter((v): v is number => v != null && v !== id);
  leave(id, how);
  if (rest.length >= 2) closeUp(page, t, rest);
  else {
    setTiling(page, null);
    if (rest.length) fillArea(rest[0]);
  }
  console.info(`[tiles] window ${id} out of page ${page}'s tiles (${how}); ${rest.length} left`);
}

/** The leaving window's own frame (see [untile]). */
function leave(id: number, how: "float" | "minimise" | "keep" | "gone") {
  const w = webWins.value.find((v) => v.id === id);
  if (how === "float") refloat(id);
  else if (how === "minimise") update(id, { ...(w?.untiled ?? {}), untiled: undefined, minimised: true });
  else if (how === "keep") update(id, { untiled: undefined });
}

/** The [rest] (2-3) of [t] closed up: a 2-split keeps its direction, the split stays where it was if nothing moved. */
function closeUp(page: number, t: Tiling, rest: number[]) {
  const two = rest.length === 2 && (t.layout === "2h" || t.layout === "2v");
  const layout = two ? t.layout : layoutFor(rest.length, tileArea());
  const keep = layout === t.layout && !t.ids.includes(null);
  setTiling(page, { layout, ids: SLOTS[layout].map((_, i) => rest[i] ?? null), rx: keep ? t.rx : 0.5, ry: keep ? t.ry : 0.5 });
}

/** The last window of a split fills the work area (restore: its floating frame). */
function fillArea(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  const a = workArea();
  const o = pageOrigin();
  update(id, { x: a.left - o.x, y: a.top - o.y, w: a.right - a.left, h: a.bottom - a.top, restore: w.untiled ?? { x: w.x, y: w.y, w: w.w, h: w.h }, untiled: undefined });
}

/** A new window on [page] takes the first empty tile of its tiling. */
function fillEmptyTile(page: number, id: number) {
  const t = tilings.value[page];
  const i = t?.ids.indexOf(null) ?? -1;
  if (!t || i < 0) return;
  const ids = [...t.ids];
  ids[i] = id;
  setTiling(page, { ...t, ids });
}

/** A divider snaps to a third, a half or two thirds; dragged within this share of an edge, the squeezed side goes. */
const SNAPS = [1 / 3, 1 / 2, 2 / 3];
export const DROP_SHARE = 0.12;
export const snapRatio = (r: number) => SNAPS.reduce((b, s) => (Math.abs(s - r) < Math.abs(b - r) ? s : b), 0.5);

/**
 * The host's divider drag ended: "<page>:<axis>" at [ratio] (already snapped), or [drop]: the windows squeezed to an
 * edge. Those go to the dock (minimised, alive: a tap on their dock icon brings them back floating), the rest close
 * up. Not closed (the app's state would go) and not floated on top (it would cover the tile the user just widened);
 * the user asked the same of Android's split, 2026-10-29: dragging it to the edge should tuck it away, not close it.
 */
powos.on("webwindows.divider", (m: { key: string; ratio: number; drop?: number[] }) => {
  const [p, axis] = m.key.split(":");
  const page = Number(p);
  const t = tilings.value[page];
  if (!t) return;
  if (m.drop?.length) {
    for (const id of m.drop) untile(id, "minimise");
    return;
  }
  const r = Math.min(1 - DROP_SHARE, Math.max(DROP_SHARE, m.ratio));
  setTiling(page, axis === "x" ? { ...t, rx: r } : { ...t, ry: r });
});
/** The bar's tile menu, or a window let go at a screen edge or corner. */
powos.on("webwindows.tile", (m: { id: number; slot: Slot }) => tile(m.id, m.slot));

/** A divider's place in its page (invisible): it moves with a page swipe, and home's swipes leave it alone. */
function DividerEl({ page, d, o }: { page: number; d: Divider; o: { x: number; y: number } }) {
  const vertical = d.axis === "x";
  const style = {
    position: "absolute",
    left: `${(vertical ? d.pos - TILE_GAP / 2 : d.from) - o.x}px`,
    top: `${(vertical ? d.from : d.pos - TILE_GAP / 2) - o.y}px`,
    width: `${vertical ? TILE_GAP : d.len}px`,
    height: `${vertical ? d.len : TILE_GAP}px`,
    zIndex: 60,
  } as const;
  return <div class="webwindow ww-divider" data-div={`${page}:${d.axis}`} style={style} />;
}

// ---- geometry to the host ----------------------------------------------------------------------------------------------

const px = (v: number) => (Math.round(v * 100) / 100).toString();
let lastGeometry = "";
let lastArea = "";
let lastTheme = "";
let themeAt = 0;
let raf = 0;

const onScreen = (left: number, top: number, w: number, h: number) => w > 0 && h > 0 && left + w > 0 && left < innerWidth && top + h > 0 && top < innerHeight;

/**
 * One window's entry, or null (its page isn't in the DOM): "<id> <frame x y w h> <body x y w h> <radius> <visible>
 * <scale> <maximised>", viewport CSS px. The frame's place is measured (a page swipe moves it); its size is the
 * model's, unscaled (the host scales the layer; the app's display stays at the body's real size).
 */
function entry(w: WebWin): string | null {
  const el = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${w.id}"]`);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const s = w.scale ?? 1;
  const frame = `${px(r.left)} ${px(r.top)} ${px(w.w)} ${px(w.h)}`;
  const body = `${px(r.left)} ${px(r.top + TITLE)} ${px(w.w)} ${px(Math.max(1, w.h - TITLE))}`;
  return `${w.id} ${frame} ${body} ${RADIUS} ${onScreen(r.left, r.top, w.w * s, w.h * s) ? 1 : 0} ${px(s)} ${w.restore ? 1 : 0}`;
}

/**
 * One divider's entry, measured from its element (a page swipe moves it): "<page:axis> <x|y> <pos> <from> <len> <lo>
 * <hi> <before ids,|-> <after ids,|->", viewport CSS px; lo/hi shifted with the page as pos is.
 */
function dividerEntries(): string[] {
  const a = tileArea();
  return Object.entries(tilings.value).flatMap(([p, t]) => dividers(t, a).map((d) => dividerEntry(p, d)).filter((e): e is string => e != null));
}

function dividerEntry(p: string, d: Divider): string | null {
  const el = document.querySelector<HTMLElement>(`.ww-divider[data-div="${p}:${d.axis}"]`);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const vertical = d.axis === "x";
  // The element's offset from where the model put it: the page's slide.
  const shift = (vertical ? r.left : r.top) + TILE_GAP / 2 - d.pos;
  const from = vertical ? r.top : r.left;
  const ids = (l: number[]) => (l.length ? l.join(",") : "-");
  return `${p}:${d.axis} ${d.axis} ${px(d.pos + shift)} ${px(from)} ${px(d.len)} ${px(d.lo + shift)} ${px(d.hi + shift)} ${ids(d.before)} ${ids(d.after)}`;
}

function geometry(): string {
  const parts = webWins.value.map(entry).filter((e): e is string => e != null);
  const divs = dividerEntries();
  return [devicePixelRatio, parts.length, ...parts, divs.length, ...divs].join(" ");
}

/** "r g b a" of a CSS colour, as the page resolves it. */
function resolved(css: string): string {
  const probe = document.createElement("i");
  probe.style.color = css;
  document.body.append(probe);
  const c = getComputedStyle(probe).color;
  probe.remove();
  const n = c.match(/[\d.]+/g)?.map(Number) ?? [0, 0, 0];
  return `${n[0]} ${n[1]} ${n[2]} ${n[3] ?? 1}`;
}

/** The host's bar in the page's colours ("w.theme <bg r g b a> <fg r g b a>"): checked at most once a second. */
function theme() {
  if (performance.now() - themeAt < 1000) return;
  themeAt = performance.now();
  const t = `${resolved("var(--color-surface)")} ${resolved("var(--color-foreground)")}`;
  if (t !== lastTheme) send(`w.theme ${(lastTheme = t)}`);
}

/** Each frame while there are windows: the work area, then their geometry tagged with this page frame, when changed. */
function tick() {
  raf = 0;
  if (!native.value) return;
  theme();
  const a = workArea();
  const ta = tileArea();
  // Then the tiles' area: the host's edge snapping makes the same tiles as tileRects.
  const area = `${devicePixelRatio} ${px(a.left)} ${px(a.top)} ${px(a.right)} ${px(a.bottom)} ${px(ta.left)} ${px(ta.top)} ${px(ta.right)} ${px(ta.bottom)}`;
  if (area !== lastArea) {
    send(`w.area ${(lastArea = area)}`);
    // The screen turned or the dock moved: tiles follow the work area.
    for (const p of Object.keys(tilings.value)) relayout(Number(p));
  }
  const g = geometry();
  if (g !== lastGeometry) {
    lastGeometry = g;
    const id = nextFrameId();
    console.timeStamp(`ww f${id}`);
    send(`w.f ${id} ${g}`);
  }
  if (webWins.value.length) raf = requestAnimationFrame(tick);
}

function kick() {
  if (!raf) raf = requestAnimationFrame(tick);
}
webWins.subscribe(kick);
tilings.subscribe(kick);
// A new port (the page reloaded or the host came back): its layers know nothing yet.
native.subscribe(() => {
  lastGeometry = lastArea = lastTheme = "";
  themeAt = 0;
  kick();
});

/**
 * Its title bar's place: invisible, the host draws the bar and takes its touches (moves, buttons). With no host (the
 * browser gate, a page without the native port) it moves the model itself.
 */
function TitleBar({ win }: { win: WebWin }) {
  const drag = useRef<{ px: number; py: number; x: number; y: number } | null>(null);
  const up = (e: PointerEvent) => {
    e.stopPropagation();
    drag.current = null;
  };
  return (
    <div
      class="webwindow-title"
      style={{ height: `${TITLE}px`, flex: `0 0 ${TITLE}px`, touchAction: "none" }}
      onPointerDown={(e) => {
        e.stopPropagation();
        raise(win.id);
        if (native.value) return;
        capture(e);
        drag.current = { px: e.clientX, py: e.clientY, x: win.x, y: win.y };
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        e.stopPropagation();
        update(win.id, { x: d.x + e.clientX - d.px, y: Math.max(0, d.y + e.clientY - d.py), restore: undefined });
      }}
      onPointerUp={up}
      onPointerCancel={up}
    />
  );
}

/** The app's place: its touches go to the app (mapped through the window's zoom). */
function Body({ win, body }: { win: WebWin; body: { current: HTMLDivElement | null } }) {
  const pressed = useRef(false);
  const send = (e: PointerEvent, action: "down" | "move" | "up" | "cancel") => {
    e.stopPropagation();
    const r = body.current?.getBoundingClientRect();
    const s = win.scale ?? 1;
    if (r) void powos.webwindows?.input(win.id, action, (e.clientX - r.left) / s, (e.clientY - r.top) / s);
  };
  const end = (e: PointerEvent, action: "up" | "cancel") => {
    pressed.current = false;
    send(e, action);
  };
  return (
    <div
      class="webwindow-body"
      ref={body}
      style={{ flex: 1, touchAction: "none" }}
      onPointerDown={(e) => {
        raise(win.id);
        capture(e);
        pressed.current = true;
        send(e, "down");
      }}
      onPointerMove={(e) => pressed.current && send(e, "move")}
      onPointerUp={(e) => end(e, "up")}
      onPointerCancel={(e) => end(e, "cancel")}
    />
  );
}

/** Invisible: the host draws the window above home; this keeps its place in the page (swipes, exclusions, touches). */
function WebWindowEl({ win, z }: { win: WebWin; z: number }) {
  const body = useRef<HTMLDivElement>(null);
  const s = win.scale ?? 1;
  const frame = {
    position: "absolute",
    left: `${win.x}px`,
    top: `${win.y}px`,
    width: `${win.w}px`,
    height: `${win.h}px`,
    transform: s === 1 ? undefined : `scale(${s})`,
    transformOrigin: "0 0",
    zIndex: 20 + z,
    display: "flex",
    flexDirection: "column",
  } as const;
  return (
    <div class="webwindow" data-wwid={win.id} style={frame}>
      <TitleBar win={win} />
      <Body win={win} body={body} />
    </div>
  );
}
