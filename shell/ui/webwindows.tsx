// Web windows: an app's window as an ELEMENT of home's page (unfolded; off unless Settings.Global powos_web_windows =
// 1). docs/WEB_WINDOWS.md "Element model". The user, 2026-10-30: "the whole way we integrate windows is still hacky, it
// needs to be handled properly fully inside the powos web ui", "The apps were supposed to be working directly in the
// webview". This file is the window: its model (page, position, size, scale, z-order = list order = DOM order,
// minimised/maximised, tiles) AND its element - the title bar, buttons, edges, tile menu and dividers are DOM, plain
// web input. Only the app's pixels are native: the host (WebWindows.kt) puts the app's own buffers in a layer UNDER
// home's surface, exactly where this file measures the body every frame (position, clip, visibility, z), on the same
// draw. Over the body the page is transparent; anything above it in the DOM paints over the app and takes its taps.
import { effect, signal } from "@preact/signals";
import { useRef, useState } from "preact/hooks";
import { geometryChannel, native, nextFrameId, sendGeometry } from "../apps/port.ts";
import { powos } from "../bridge.ts";
import { wideHome } from "../hosts/wide.ts";
import type { WebWindowRect } from "../types.ts";
import { Mark } from "./chrome.tsx";
import { memo } from "./memo.ts";
import { confirm as hapticConfirm, tick as hapticTick } from "./haptics.ts";
import { dropAt, dropInto, insertAt, leaves, splitBox, tabAt, treeRects, zoneKey as dropKey, type Bar, type Tree, type Zone } from "./tiledrop.ts";

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
  /** Its app's content shows ("webwindows.live"): the body paints nothing; until then, the placeholder. */
  live?: boolean;
  /**
   * LW3: a Linux launch's window before KWin offers its toplevel - the placeholder at once, at its place (id < 0: the
   * host knows nothing of it, no geometry goes out). The first offer with its key takes it ([takePlaceholder]).
   */
  pending?: boolean;
  /** Its element's key: a placeholder's id, kept when KWin's window takes it (the same element: no jump). */
  el?: number;
  /** Not live in [LINUX_START] (or its app gone): "couldn't start", with the reason - its body shows it and a close. */
  failed?: string;
  /**
   * Its app draws its own complete frame (a Linux window with client-side decorations: Brave, Chrome, Steam, a GTK
   * header bar; kwin 0046 "decor ... own"): no PowOS bar over it (one bar, never two) - its own drag moves this frame
   * ("webwindows.moveresize"), a hold on that drag opens the tile menu.
   */
  ownFrame?: boolean;
}

/** An app's icon URL by its key (state.ts sets it: this file can't import that one), or undefined. */
let iconOf: (key: string) => string | undefined = () => undefined;
export function setIconOf(f: (key: string) => string | undefined) {
  iconOf = f;
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
  if (key.startsWith("l:")) return (await linuxWindow(key, label, page)) != null;
  return (await openWindow(key, label, page)) != null;
}

/** [openWebWindow], with the window's id (null: not a window). A page tiling with an empty tile puts it there. */
/**
 * A Linux app ("l:"): its windows come from KWin ("webwindows.adopt" with a KWin id). One that has a web window already
 * comes to [page], on top, as an Android app's does; else (or that window couldn't start) the tap launches it with a
 * placeholder window on [page] at once (LW3: the user, 2026-10-30, "they shoulf have a splash screen"), which its first
 * toplevel takes. null: not one (the caller launches it as before).
 */
async function linuxWindow(key: string, label: string, page: number): Promise<number | null> {
  if (!wideHome.value || !(await enabled())) return null;
  const open = webWins.value.find((w) => w.key === key && !w.full && !w.failed);
  if (open) {
    update(open.id, { page, minimised: false });
    raise(open.id);
    return open.id;
  }
  // One that couldn't start goes: a tap is a new try (a stuck one never blocks the app: Dolphin, 2026-10-30 21:01).
  for (const w of webWins.value.filter((v) => v.key === key && v.failed)) close(w.id);
  return linuxPlaceholder(key, label, page);
}

/** How long a Linux launch's window may take to show (LW3): then "couldn't start". The gate shortens it. */
export const LINUX_START = { ms: 20_000 };
let placeholders = 0;

/** A Linux launch's placeholder window (LW3) on [page], on top, and the launch itself (the host: powos-run). */
function linuxPlaceholder(key: string, label: string, page: number): number {
  const id = --placeholders;
  webWins.value = [...webWins.value, { id, el: id, key, label, page, ...cascade(), pending: true }];
  fillEmptyTile(page, id);
  watchStart(id);
  void powos.apps.launch(key).catch(() => update(id, { failed: "The launch failed." }));
  return id;
}

// The host: a Linux launch of [key] couldn't start (its command ended with no window, or never ran; Runtime.openRooted):
// its waiting window says so with the reason at once, not "loading" until [LINUX_START] (Dolphin, 2026-10-30 21:00).
powos.on("apps.launchfailed", ({ key, reason }: { key: string; reason?: string }) => {
  for (const w of webWins.value.filter((v) => v.key === key && !v.live && !v.failed)) update(w.id, { failed: `${(reason || "The launch failed").replace(/\.$/, "")}.` });
});

/** Window [id] not live in [LINUX_START] (no toplevel, or one that never drew): "couldn't start" - never forever. */
function watchStart(id: number) {
  setTimeout(() => {
    const w = webWins.value.find((v) => v.id === id);
    if (w && !w.live && !w.failed) update(id, { failed: w.pending ? "It opened no window." : "Its window never drew." });
  }, LINUX_START.ms);
}

/** A new window's default frame (page px): half the screen wide, cascaded by the windows there are. */
function cascade(): { x: number; y: number; w: number; h: number } {
  const n = webWins.value.length;
  return { x: 48 + 32 * (n % 6), y: 72 + 32 * (n % 6), w: Math.round(innerWidth * 0.5), h: Math.round(innerHeight * 0.6) };
}

/**
 * KWin's toplevel [kwin] for placeholder [ph] (LW3): the host's window at the placeholder's body, then the same model
 * entry and element under the host's id (its frame, page, tile and z kept). Closed meanwhile: the window goes too.
 */
async function takePlaceholder(ph: WebWin, kwin: number, ownFrame?: boolean): Promise<boolean> {
  const b = document.querySelector(`.webwindow[data-wwid="${ph.id}"] .webwindow-body`)?.getBoundingClientRect();
  const o = pageOrigin();
  const rect = b?.width ? { left: b.left, top: b.top, width: b.width, height: b.height } : { left: ph.x + o.x, top: ph.y + o.y + TITLE, width: ph.w, height: ph.h - TITLE };
  const id = await powos.webwindows!.open(ph.key, rect, undefined, kwin).catch(() => -1);
  if (id < 0) return false;
  if (!webWins.value.some((w) => w.id === ph.id)) {
    void powos.webwindows!.close(id);
    return true;
  }
  hostGave(id);
  webWins.value = webWins.value.map((w) => (w.id === ph.id ? { ...w, id, el: w.el ?? ph.id, pending: undefined, failed: undefined, ownFrame: ownFrame || undefined } : w));
  const t = tiledOn(ph.id);
  if (t != null) setTiling(t, { ...tilings.value[t], ids: tilings.value[t].ids.map((v) => (v === ph.id ? id : v)) });
  if (tileMenu.value === ph.id) tileMenu.value = id;
  watchStart(id);
  return true;
}

/** App [key]'s window already (its id, brought to [page] - or to the front as its full-screen app), or null: none. */
function existingWindow(key: string, page: number): number | null {
  // Already a window: it comes to this page, on top - never a second display for the same app (its task would move).
  const open = webWins.value.find((w) => w.key === key);
  if (!open) return null;
  // A full-screen app now: it comes to the front as one (never a second window).
  if (open.full && powos.webwindows?.fullScreen) {
    void powos.webwindows.fullScreen(open.id);
    return open.id;
  }
  return cameHere(open.id, page);
}

/** Window [id] to [page], not minimised, on top: its id. */
function cameHere(id: number, page: number): number {
  showTab(id);
  update(id, { page, minimised: false });
  raise(id);
  return id;
}

export async function openWindow(key: string, label: string, page: number): Promise<number | null> {
  if (!wideHome.value || !key.startsWith("a:") || !(await enabled())) return null;
  const had = existingWindow(key, page);
  if (had != null) return had;
  const { x, y, w, h } = cascade();
  // Its first rect is a guess; the element reports its real one on its first frame.
  const id = await powos.webwindows!.open(key, { left: x, top: y + TITLE, width: w, height: h - TITLE }).catch(() => -1);
  if (id < 0) return null;
  // The host's window for this app already (a second tap while the first open was in flight, a model the host knows
  // better): that one comes here, never a second entry or display.
  if (webWins.value.some((v) => v.id === id)) return cameHere(id, page);
  hostGave(id);
  webWins.value = [...webWins.value, { id, key, label, page, x, y, w, h }];
  fillEmptyTile(page, id);
  return id;
}

/** Where an adopted window goes: its [body] (viewport CSS px) plus its [bar], else a default size centred in the work
 * area; clamped into the work area (viewport px). */
function adoptPlace(body: WebWindowRect | undefined, bar: number): { vx: number; vy: number; w: number; h: number } {
  const a = workArea();
  const aw = a.right - a.left;
  const ah = a.bottom - a.top;
  const w = Math.max(Math.min(aw, Math.round(body ? body.width : innerWidth * 0.5)), 200);
  const h = Math.max(Math.min(ah, Math.round(body ? body.height + bar : innerHeight * 0.6)), 160);
  const sx = body ? body.left : a.left + (aw - w) / 2;
  const sy = body ? body.top - bar : a.top + (ah - h) / 2;
  const vx = Math.round(Math.min(Math.max(sx, a.left), a.right - w));
  const vy = Math.round(Math.min(Math.max(sy, a.top), a.bottom - h));
  return { vx, vy, w, h };
}

/**
 * An app's running task made a window here (the host's "webwindows.adopt": the switcher's "PowOS desktop window", the
 * system window menu's "Desktop window" - ShellBridge.toWebWindow is the one path): a new window on [page] holding THAT
 * task (moved onto the window's display, not launched again), at [body] (viewport CSS px: where the app floated, or its
 * last place by hand) inside the work area, else a default size centred in it. Home goes to [page], the window on top.
 * A tiling on [page] with an empty tile puts it there (fillEmptyTile), as [openWindow] does.
 */
export async function adoptWebWindow(
  m: { task?: number; kwin?: number; key: string; label: string; body?: WebWindowRect; ownFrame?: boolean },
  page: number,
): Promise<boolean> {
  // A window that draws its own frame has no PowOS bar: its body is the whole frame.
  const bar = m.ownFrame ? 0 : TITLE;
  const ww = powos.webwindows;
  if (!ww) return false;
  // A Linux launch's placeholder waiting for this app (LW3; by its key - the host matched app_id to the .desktop): taken.
  const ph = m.kwin != null ? webWins.value.find((w) => w.pending && w.key === m.key) : undefined;
  if (ph) return takePlaceholder(ph, m.kwin!, m.ownFrame);
  const o = pageOrigin();
  const { vx, vy, w, h } = adoptPlace(m.body, bar);
  const id = await ww.open(m.key, { left: vx, top: vy + bar, width: w, height: h - bar }, m.task, m.kwin).catch(() => -1);
  if (id < 0) return false;
  // The host gave the app's existing window (one display per app task): it comes to [page], no second entry.
  if (webWins.value.some((v) => v.id === id)) {
    cameHere(id, page);
    toPage(page);
    return true;
  }
  hostGave(id);
  webWins.value = [...webWins.value, { id, key: m.key, label: m.label, page, x: vx - o.x, y: vy - o.y, w, h, task: m.task, ownFrame: m.ownFrame || undefined }];
  if (m.kwin != null) watchStart(id);
  // As any window opened on the page: a tiling there with an empty tile takes it (its floating frame kept for a float
  // out); otherwise it floats at that frame on top.
  fillEmptyTile(page, id);
  toPage(page);
  return true;
}

/** The pointer kept by its element (a synthetic or already-ended pointer can't be: the drag still works). */
function capture(e: PointerEvent) {
  try {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  } catch {}
}

export function update(id: number, change: Partial<WebWin>) {
  const was = change.minimised === undefined ? undefined : !!webWins.value.find((w) => w.id === id)?.minimised;
  webWins.value = webWins.value.map((w) => (w.id === id ? { ...w, ...change } : w));
  if (was !== undefined && was !== !!change.minimised) minimisedChanged(id, !was);
}

/**
 * MN1/MN2 (the user, 2026-10-30 22:52: "Click the minimize button on for example YouTube. It should act as if I swiped
 * home on it"): every minimise (bar button, dock toggle, a tile's drop) and every way back reaches the host, which gives
 * the app a home gesture's lifecycle (it may go picture-in-picture) and brings it back into its window.
 */
function minimisedChanged(id: number, on: boolean) {
  if (!native.value || id < 0) return;
  if (on) void powos.webwindows?.minimise?.(id);
  else void powos.webwindows?.restore?.(id);
}

export function raise(id: number) {
  const list = webWins.value;
  if (list[list.length - 1]?.id === id) return;
  const win = list.find((w) => w.id === id);
  if (!win) return;
  webWins.value = [...list.filter((w) => w.id !== id), win];
}

/**
 * The host's window ids as its last "webwindows.alive" listed them, plus each one it gave the page since (an open, an
 * adoption); null: no list yet (the mock, a host before it). A window not in it has no host window: [WebWindowEl] gives
 * it its PowOS bar with a close button whatever its state (own frame, tiled), never a bare picture (10-31 03:05, "Clear
 * all": "like it's missing the title bar but it's not done properly").
 */
export const hostIds = signal<Set<number> | null>(null);
function hostGave(id: number) {
  const ids = hostIds.value;
  if (ids && !ids.has(id)) hostIds.value = new Set([...ids, id]);
}
/** Window [id] has no host window (the host's list doesn't name it): its bar shows, with a close button. */
export function orphaned(id: number): boolean {
  const ids = hostIds.value;
  return id >= 0 && ids != null && !ids.has(id);
}
function forget(id: number) {
  leaveStack(id);
  untile(id, "gone");
  webWins.value = webWins.value.filter((w) => w.id !== id);
}
powos.on("webwindows.closed", (id: number) => {
  const ids = hostIds.value;
  if (ids?.has(id)) hostIds.value = new Set([...ids].filter((v) => v !== id));
  forget(id);
});
/**
 * The host's windows, by id (each reconcile, at least every 2 s): an entry it has no window for is a ghost - it goes,
 * as on "webwindows.closed". Placeholders (negative ids, a Linux launch's) are the page's own.
 */
powos.on("webwindows.alive", (ids: number[]) => {
  const alive = new Set(ids);
  hostIds.value = alive;
  for (const w of webWins.value) if (!(w.id < 0 || w.pending || alive.has(w.id))) forget(w.id);
});
/** Home to a page (by its number, as pages lists them): state.ts sets it (it imports this file, not the reverse). */
let toPage: (page: number) => void = () => {};
export function onWebWindowPage(f: (page: number) => void) {
  toPage = f;
}

/** Window [id] shown where it was: not minimised, on top, home on its page. */
function bringBack(id: number) {
  showTab(id);
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  update(id, { minimised: false });
  raise(id);
  toPage(w.page);
}

/**
 * TB4 (the user, 2026-10-30: "If I click on the icon of an open window I should be able to minimize it that way"): a
 * dock tap on app [key] with web windows, taskbar style - one code path for Android and Linux windows. Its window in
 * front (the top-most one showing on the page on screen) minimises; with several windows of the app the tap cycles
 * instead (its bottom-most one comes to the front, so each gets its turn). Not in front - minimised, under another
 * window or on another page - its top-most window comes back in front on ITS page (home goes there). false: no window
 * here (folded, none, or only a full-screen one): the caller goes on as before (launch -> openWebWindow).
 */
export function dockToggle(key: string): boolean {
  if (!wideHome.value) return false;
  const mine = webWins.value.filter((w) => w.key === key && !w.full);
  if (!mine.length) return false;
  const here = shownPage();
  const front = webWins.value.filter((w) => w.page === here && !w.minimised && !w.full && !hiddenTab(w.id)).at(-1);
  if (front?.key === key) {
    if (mine.length === 1) minimise(front.id);
    else bringBack(mine[0].id);
    return true;
  }
  bringBack(mine[mine.length - 1].id);
  return true;
}

/** Its app became a full-screen app (the window hides, its place kept) or is back in the window (shown on its page). */
powos.on("webwindows.full", (m: { id: number; on: boolean; task?: number }) => {
  // A tile going full screen leaves its tile (the others close up); back in a window, it floats at its old frame.
  if (m.on) untile(m.id, "float");
  update(m.id, { full: m.on, task: m.task ?? webWins.value.find((w) => w.id === m.id)?.task, minimised: false });
  if (!m.on) bringBack(m.id);
  resendGeometry();
});
/** The host lost or re-made layer state (a mirror made again, home's surface re-attached): every window's state again. */
powos.on("webwindows.resend", () => resendGeometry());
/** Its app's first frame shows (WebWindows.liveWhenDrawn): the placeholder goes, the body is the app's. */
powos.on("webwindows.live", (id: number) => update(id, { live: true }));
/** Its app draws its own frame now, or no longer (WebWindows.linuxOwnFrame): its PowOS bar goes or comes. */
powos.on("webwindows.frame", (m: { id: number; own: boolean }) => update(m.id, { ownFrame: m.own || undefined }));
/**
 * Its app's own frame dragged (WebWindows.linuxMoveResize: its tab strip's drag, an edge of its own): the press on its
 * body that did it now moves ("move") or resizes (the edges) this frame, from the next pointer move on (Body).
 */
powos.on("webwindows.moveresize", (m: { id: number; edges: string }) => {
  appDrags.set(m.id, { edges: m.edges, start: null, moved: false, hold: 0 });
});
/** Its switcher card tapped (ShellBridge.openTask): back where it was, floating, on its page. */
powos.on("webwindows.show", (id: number) => bringBack(id));

// ---- the work area, and the host's events ----------------------------------------------------------------------------

/**
 * Where windows may be, viewport CSS px: the screen above home's foot (the dock and the bar - maximise and tiles stop
 * there, a desktop's reserved dock strip).
 */
export function workArea(): { left: number; top: number; right: number; bottom: number } {
  // The pages' own box (a side dock's column is not theirs: PS1, a maximised window never reaches the next page). The
  // box, not the page on screen: mid-swipe the area stays where the page rests.
  const pages = document.querySelector(".pages")?.getBoundingClientRect();
  const left = pages && pages.width > 0 ? Math.max(0, pages.left) : 0;
  const right = pages && pages.width > 0 ? Math.min(innerWidth, pages.right) : innerWidth;
  let bottom = innerHeight;
  for (const el of document.querySelectorAll<HTMLElement>(".home > .dock, .home > .bar")) {
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.top > innerHeight / 2) bottom = Math.min(bottom, r.top);
  }
  return { left, top: 0, right, bottom };
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

/**
 * DB1 (the user, 2026-10-30: "We need to prevent windows from going up past the status bar"): a floating window's
 * place (page px) clamped so its bar never goes above the status bar's bottom and at least a third of the bar stays
 * on screen sideways and above the work area's bottom.
 */
export function clampPlace(x: number, y: number, w: number): { x: number; y: number } {
  const o = pageOrigin();
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 0;
  const a = workArea();
  const keep = w / 3;
  const vx = Math.min(Math.max(x + o.x, keep - w), innerWidth - keep);
  const vy = Math.min(Math.max(y + o.y, inset), Math.max(inset, a.bottom - TITLE));
  return { x: vx - o.x, y: vy - o.y };
}

/** Fills the work area, or goes back to where it was. */
export function toggleMaximise(id: number) {
  // A tile goes full screen as a free window (its tile closes up); restore brings back its floating frame.
  if (tiledOn(id) != null) untile(id, "float");
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  if (w.restore) return update(id, { ...w.restore, ...clampPlace(w.restore.x, w.restore.y, w.restore.w), restore: undefined });
  const a = workArea();
  const o = pageOrigin();
  update(id, { x: a.left - o.x, y: a.top - o.y, w: a.right - a.left, h: a.bottom - a.top, scale: 1, restore: { x: w.x, y: w.y, w: w.w, h: w.h } });
  raise(id);
}

export function minimise(id: number) {
  if (tiledOn(id) != null) return untile(id, "minimise");
  update(id, { minimised: true });
}

/** The host's maximise (a Linux window's full screen button, for now: WebWindows.fullScreen). */
powos.on("webwindows.control", (m: { id: number; action: string }) => {
  if (m.action === "minimise") minimise(m.id);
  else if (m.action === "maximise") toggleMaximise(m.id);
});

/** The windows pinned to home page [page] (not minimised), and its tiles' dividers: elements of that page, in z order. */
/**
 * The windows above [id], the same array while they are the same windows: a fresh slice each render re-rendered every
 * window (its bar, body, 8 edges) on each frame of another one's move or resize (render scan 10-30: half of
 * WebWindowEl's renders in a drag needless, with all of their Edges and Marks).
 */
const aboveOf = new Map<number, WebWin[]>();
function sameAbove(id: number, list: WebWin[]): WebWin[] {
  const was = aboveOf.get(id);
  if (was && was.length === list.length && was.every((w, i) => w === list[i])) return was;
  aboveOf.set(id, list);
  if (aboveOf.size > 64) aboveOf.delete(aboveOf.keys().next().value!);
  return list;
}

export function WebWindowsOn({ page }: { page: number }) {
  const here = webWins.value.filter((w) => w.page === page && !w.minimised && !w.full && !hiddenTab(w.id));
  if (!here.length) return null;
  const t = tilings.value[page];
  const o = pageOrigin();
  return (
    // Clipped to its page (PS2): a window bigger than its page never shows on the next one.
    <div class="page-windows">
      {here.map((w, i) => (
        <WebWindowEl key={w.el ?? w.id} win={w} z={webWins.value.indexOf(w)} above={sameAbove(w.id, here.slice(i + 1))} />
      ))}
      {t && dividers(t, tileArea()).map((d) => <DividerEl key={d.ratio} page={page} d={d} o={o} />)}
      {dropView.value?.page === page && <DropPreview d={dropView.value} o={o} />}
    </div>
  );
}

// ---- tiles -------------------------------------------------------------------------------------------------------------
//
// PowOS's own split screen (the user, 2026-10-30: "lets take full control and replace that too so we can unlock our
// own splitscreen capabilities maybe with like 3 of 4 apps at once"). A tiling is a state of one page's windows: a
// layout and which window is in which tile (a window in one is "tiled", the rest float above or below as usual). The
// windows' frames are the tiles' rects (the model stays x/y/w/h, so the host needs nothing new to place them); the
// dividers between tiles are DOM handles here ([DividerEl]). docs/WEB_WINDOWS.md "Tiles".

/**
 * "2h" left | right, "2v" top / bottom, "3" one big left + two stacked right, "4" a 2x2 grid. GL1 (a window docked
 * beside a tile, [dock]): "3r" two stacked left + one big right, "3t" one wide top + two below, "3b" two above + one
 * wide bottom, "3c" three columns, "3s" three rows.
 */
export type Layout = "2h" | "2v" | "3" | "3r" | "3t" | "3b" | "3c" | "3s" | "4";
export interface Tiling {
  layout: Layout;
  /** Window per tile, in [SLOTS] order; null: an empty tile (the next window opened on the page goes there). */
  ids: (number | null)[];
  /** The vertical divider's place (share of the work area's width) and the horizontal one's (of its height). */
  rx: number;
  ry: number;
}
export type Slot = "left" | "right" | "top" | "bottom" | "tl" | "tr" | "bl" | "br" | "grid" | "float";
const SLOTS: Record<Layout, string[]> = {
  "2h": ["left", "right"],
  "2v": ["top", "bottom"],
  "3": ["left", "rtop", "rbottom"],
  "3r": ["ltop", "lbottom", "right"],
  "3t": ["top", "bleft", "bright"],
  "3b": ["tleft", "tright", "bottom"],
  "3c": ["c1", "c2", "c3"],
  "3s": ["r1", "r2", "r3"],
  "4": ["tl", "tr", "bl", "br"],
};
/** Every layout but "4" as nested splits (leaves: slot indices, in slot order; the ratio each split takes). */
type Spec = number | ["x" | "y", "rx" | "ry", Spec, Spec];
const SPECS: Record<Exclude<Layout, "4">, Spec> = {
  "2h": ["x", "rx", 0, 1],
  "2v": ["y", "ry", 0, 1],
  "3": ["x", "rx", 0, ["y", "ry", 1, 2]],
  "3r": ["x", "rx", ["y", "ry", 0, 1], 2],
  "3t": ["y", "ry", 0, ["x", "rx", 1, 2]],
  "3b": ["y", "ry", ["x", "rx", 0, 1], 2],
  "3c": ["x", "rx", 0, ["x", "ry", 1, 2]],
  "3s": ["y", "ry", 0, ["y", "rx", 1, 2]],
};
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
  if (t.layout !== "4") {
    const rs = treeRects(treeOf(SPECS[t.layout], t, (i) => i), boxOf(a), TILE_GAP);
    return SLOTS[t.layout].map((_, i) => rs.get(i)!);
  }
  const g = TILE_GAP / 2;
  const xs = a.left + (a.right - a.left) * t.rx;
  const ys = a.top + (a.bottom - a.top) * t.ry;
  const r = (l: number, top: number, right: number, b: number): Box => ({ x: l, y: top, w: right - l, h: b - top });
  return [r(a.left, a.top, xs - g, ys - g), r(xs + g, a.top, a.right, ys - g), r(a.left, ys + g, xs - g, a.bottom), r(xs + g, ys + g, a.right, a.bottom)];
}

/**
 * A divider (viewport CSS px): a vertical one ("x") is the line at [pos] from [from] for [len]; [lo]..[hi] is the span
 * its ratio is of. [before]/[after]: the windows whose right (bottom) and left (top) edges follow it.
 */
export interface Divider {
  axis: "x" | "y";
  /** The tiling's ratio it sets. */
  ratio: "rx" | "ry";
  pos: number;
  from: number;
  len: number;
  lo: number;
  hi: number;
  before: number[];
  after: number[];
}

export function dividers(t: Tiling, a: Area): Divider[] {
  if (t.layout !== "4") return specDividers(SPECS[t.layout], t, boxOf(a));
  const at = (slots: number[]) => slots.map((i) => t.ids[i]).filter((v): v is number => v != null);
  const W = a.right - a.left;
  const H = a.bottom - a.top;
  const xs = a.left + W * t.rx;
  const ys = a.top + H * t.ry;
  const v = (before: number[], after: number[]): Divider => ({ axis: "x", ratio: "rx", pos: xs, from: a.top, len: H, lo: a.left, hi: a.right, before: at(before), after: at(after) });
  const h = (from: number, len: number, before: number[], after: number[]): Divider => ({ axis: "y", ratio: "ry", pos: ys, from, len, lo: a.top, hi: a.bottom, before: at(before), after: at(after) });
  return [v([0, 2], [1, 3]), h(a.left, W, [0, 1], [2, 3])];
}

const boxOf = (a: Area): Box => ({ x: a.left, y: a.top, w: a.right - a.left, h: a.bottom - a.top });

/** [spec] as a split tree of [t]'s ratios, its leaves [leaf](slot). */
function treeOf(spec: Spec, t: Tiling, leaf: (i: number) => number): Tree {
  if (typeof spec === "number") return leaf(spec);
  const [axis, r, a, b] = spec;
  return { axis, at: t[r], a: treeOf(a, t, leaf), b: treeOf(b, t, leaf) };
}

/** A spec'd layout's dividers: one per split, across its own box (the windows of each side before / after it). */
function specDividers(spec: Spec, t: Tiling, area: Box): Divider[] {
  const out: Divider[] = [];
  const ids = (s: Spec) => leaves(treeOf(s, t, (i) => i)).map((i) => t.ids[i]).filter((v): v is number => v != null);
  const walk = (s: Spec, b: Box) => {
    if (typeof s === "number") return;
    const [axis, ratio, a, c] = s;
    const x = axis === "x";
    const [lo, span] = x ? [b.x, b.w] : [b.y, b.h];
    const pos = lo + span * t[ratio];
    out.push({ axis, ratio, pos, from: x ? b.y : b.x, len: x ? b.h : b.w, lo, hi: lo + span, before: ids(a), after: ids(c) });
    const [ba, bc] = splitBox(b, axis, t[ratio], TILE_GAP);
    walk(a, ba);
    walk(c, bc);
  };
  walk(spec, area);
  return out;
}

/** The page whose tiling holds window [id], or null (it floats). */
export function tiledOn(id: number): number | null {
  for (const [p, t] of Object.entries(tilings.value)) if (t.ids.includes(id)) return Number(p);
  return null;
}

function setTiling(page: number, t: Tiling | null) {
  const next = { ...tilings.value };
  if (t) t = compact(t);
  if (t && t.ids.filter((v) => v != null).length >= 2) next[page] = t;
  else delete next[page];
  tilings.value = next;
  if (t) relayout(page);
}

/**
 * TG1 (the user, 10-31 00:17: "Why can't I expand grid further than a certain point? I mean, I guess it's expecting me
 * to have four apps"): never an empty tile. The grid follows the count - 2 apps fill the whole area (side by side, or
 * stacked when it is clearly portrait), 3 = one big + two, 4 = 2x2 - so a tiling with an empty slot (a corner snap, a
 * grid of fewer than four) is closed up to its windows, in slot order. Two left of a 2x2 grid in one column stack.
 */
function compact(t: Tiling): Tiling {
  if (!t.ids.includes(null)) return t;
  const at = t.ids.flatMap((v, i) => (v == null ? [] : [i]));
  const list = at.map((i) => t.ids[i] as number);
  if (list.length < 2) return { ...t, ids: list };
  const layout = compactLayout(t.layout, at);
  return { layout, ids: list, rx: layout === t.layout ? t.rx : 0.5, ry: layout === t.layout ? t.ry : 0.5 };
}

/** The layout for the windows left at slots [at] (2-4) of [was]: a 2-split keeps its direction, one column stacks. */
function compactLayout(was: Layout, at: number[]): Layout {
  if (at.length !== 2) return layoutFor(at.length, tileArea());
  if (was === "2h" || was === "2v") return was;
  return was === "4" && at[1] - at[0] === 2 ? "2v" : layoutFor(2, tileArea());
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
  webWins.value.filter((w) => w.page === page && !w.minimised && !w.full && !hiddenTab(w.id) && !skip.includes(w.id)).map((w) => w.id).reverse();

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
  // Alone: no tiling of one (SC1) - a half or a corner is just where it goes, a floating window at that tile's rect.
  if (ids.filter((v) => v != null).length < 2) return snapAlone(id, layout, ids.indexOf(id));
  // Tiled windows that found no tile float again.
  const left = others.filter((o) => !ids.includes(o));
  setTiling(page, { layout, ids, rx: 0.5, ry: 0.5 });
  for (const o of left) refloat(o);
  console.info(`[tiles] page ${page}: ${layout} [${ids.join(",")}] (${slot} for window ${id})`);
}

/** Window [id], the page's only one to tile, at tile [i] of [layout]'s rect (restore: its frame before). */
function snapAlone(id: number, layout: Layout, i: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w || i < 0) return;
  const r = tileRects({ layout, ids: [], rx: 0.5, ry: 0.5 }, tileArea())[i];
  const o = pageOrigin();
  // Not "maximised" (no restore): a maximised window's bar merges into the status bar and squeezes it (TB1).
  update(id, { x: Math.round(r.x - o.x), y: Math.round(r.y - o.y), w: Math.round(r.w), h: Math.round(r.h), scale: 1, restore: undefined });
  raise(id);
  console.info(`[tiles] window ${id} alone: snapped to ${layout} tile ${i}, no tiling`);
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

/** A half or a corner: [id] there, the other tiled windows in the rest (a half: then the topmost floating one). The
 * empty corners close up ([compact]). */
function slotOf(page: number, id: number, slot: Slot, others: number[]): { layout: Layout; ids: (number | null)[] } {
  const layout = HALVES[slot] ?? "4";
  const ids: (number | null)[] = SLOTS[layout].map((s) => (s === slot ? id : null));
  // A corner takes the other tiled windows; with none, the topmost floating one (two corner snaps: a 2-split, TG1).
  const floating = floatingOn(page, [id, ...others]);
  const fill = layout !== "4" ? [...others, ...floating] : others.length ? others : floating.slice(0, 1);
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
    // SC1 (the user, 10-31 00:06: "When there's only like one split-screen application left, it should return to like
    // a normal full-screen application"): no tiling of one - the last window goes full screen at once, the bar's way.
    if (rest.length) lastOfSplit(rest[0]);
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

/** A 2-split's direction kept as one of its tiles goes: rows stay rows, columns columns. */
const TWO_OF: Partial<Record<Layout, Layout>> = { "2h": "2h", "2v": "2v", "3c": "2h", "3s": "2v" };

/** The [rest] (2-3) of [t] closed up: a 2-split keeps its direction, the split stays where it was if nothing moved. */
function closeUp(page: number, t: Tiling, rest: number[]) {
  const two = rest.length === 2 ? TWO_OF[t.layout] : undefined;
  const layout = two ?? layoutFor(rest.length, tileArea());
  const keep = layout === t.layout && !t.ids.includes(null);
  setTiling(page, { layout, ids: SLOTS[layout].map((_, i) => rest[i] ?? null), rx: keep ? t.rx : 0.5, ry: keep ? t.ry : 0.5 });
}

/**
 * The last window of a split: back at its floating frame (what "restore" gives back), then full screen as the bar's
 * button does it (F1: a real full-screen app on the host; with none, the work area).
 */
function lastOfSplit(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  update(id, { ...(w.untiled ?? {}), untiled: undefined, restore: undefined });
  fullScreen(id);
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

// ---- GL1: a dragged window docked into the tiles (Golden Layout's model; the zones: ui/tiledrop.ts) -------------------

/** What a drop makes: the page's new tiling, the tiled windows it puts out (a swap), the dropped window's tile rect. */
interface Landing {
  page: number;
  id: number;
  rect: Box;
  tiling: Tiling;
  out: number[];
}

/** The drop in progress (a floating window's bar dragged over its page's tiles): its zone and landing ([DropPreview]). */
export const dropView = signal<(Landing & { zone: Zone }) | null>(null);

/** [t] as a split tree of its windows ("4": two columns of two). */
function treeOfTiling(t: Tiling): Tree {
  const id = (i: number) => t.ids[i] as number;
  if (t.layout !== "4") return treeOf(SPECS[t.layout], t, id);
  const col = (a: number, b: number): Tree => ({ axis: "y", at: t.ry, a: id(a), b: id(b) });
  return { axis: "x", at: t.rx, a: col(0, 2), b: col(1, 3) };
}

/** Window [id] dropped at [zone] of page [page]'s tiling: what it makes, or null (a fifth tile, an empty tile...). */
function landing(page: number, id: number, zone: Zone): Landing | null {
  const t = tilings.value[page];
  if (!t || t.ids.includes(null) || t.ids.includes(id)) return null;
  if (zone.kind !== "swap" && t.ids.length >= 4) return null;
  const target = zone.tile < 0 ? -1 : (t.ids[zone.tile] as number);
  const tiling = tilingOf(dropInto(treeOfTiling(t), zone, target, id));
  const rects = tileRects(tiling, tileArea());
  // As the dividers (TG2, the native split's minimum): a drop that would make a tile smaller than [MIN_TILE] is no zone.
  if (rects.some((r) => r.w < MIN_TILE.x || r.h < MIN_TILE.y)) return null;
  const rect = rects[tiling.ids.indexOf(id)];
  return rect ? { page, id, rect, tiling, out: zone.kind === "swap" ? [target] : [] } : null;
}

/** A split tree of 2-4 windows as a tiling (TG1: the layout follows the count; 4 is always the 2x2 grid). */
function tilingOf(tree: Tree): Tiling {
  const ids = leaves(tree);
  if (typeof tree === "number" || ids.length >= 4) return fourOf(tree);
  if (ids.length === 2) return tree.axis === "x" ? { layout: "2h", ids, rx: tree.at, ry: 0.5 } : { layout: "2v", ids, rx: 0.5, ry: tree.at };
  return threeOf(tree, ids);
}

/** Three windows: one beside a split of two ("3", "3r", "3t", "3b") or three in a row ("3c", "3s"). */
function threeOf(tree: Exclude<Tree, number>, ids: number[]): Tiling {
  const leafFirst = typeof tree.a === "number";
  const inner = (leafFirst ? tree.b : tree.a) as Exclude<Tree, number>;
  const row = inner.axis === tree.axis;
  const layout = THREES[`${tree.axis}${row ? "=" : leafFirst ? "<" : ">"}`];
  // Three in a row: as spec'd (the leaf first) its ratios; else the same lines as shares of the whole - the tiles not
  // split keep their size (the native split's way: a neighbour added never resizes the others).
  const first = tree.at * inner.at;
  const [r1, r2] = !row || leafFirst ? [tree.at, inner.at] : [first, (tree.at - first) / (1 - first)];
  return tree.axis === "x" ? { layout, ids, rx: r1, ry: r2 } : { layout, ids, ry: r1, rx: r2 };
}
/** A 3-tree's layout by its root's axis and its leaf's side ("<" first, ">" second, "=" the other two split the same way). */
const THREES: Record<string, Layout> = { "x<": "3", "x>": "3r", "y<": "3t", "y>": "3b", "x=": "3c", "y=": "3s" };

/** Four windows in the 2x2 grid, each in the quarter nearest where [tree] would put it (the dropped one where previewed). */
function fourOf(tree: Tree): Tiling {
  const want = treeRects(tree, boxOf(tileArea()), TILE_GAP);
  const grid = tileRects({ layout: "4", ids: [], rx: 0.5, ry: 0.5 }, tileArea());
  const far = (a: Box, b: Box) => Math.hypot(a.x + a.w / 2 - b.x - b.w / 2, a.y + a.h / 2 - b.y - b.h / 2);
  const cost = (p: number[]) => p.reduce((s, id, i) => s + far(want.get(id)!, grid[i]), 0);
  const best = perms(leaves(tree).slice(0, 4)).reduce((m, p) => (cost(p) < cost(m) ? p : m));
  return { layout: "4", ids: best, rx: 0.5, ry: 0.5 };
}

const perms = (a: number[]): number[][] => (a.length <= 1 ? [a] : a.flatMap((v, i) => perms([...a.slice(0, i), ...a.slice(i + 1)]).map((p) => [v, ...p])));

/**
 * Window [id]'s bar dragged to (x, y): the drop it would make there, previewed; a haptic tick as the target changes.
 * Another window's bar (floating or tiled: WT1) takes it as a tab; else, [docks] (a floating window's drag), the tiles'
 * zones (GL1).
 */
function aim(id: number, x: number, y: number, docks = true) {
  const tab = tabTarget(id, x, y);
  const next = tab || !docks ? null : tileDrop(id, x, y);
  if (dropKey(next?.zone) + tabKey(tab) === dropKey(dropView.value?.zone) + tabKey(tabView.value)) return;
  if (next || tab) hapticTick();
  dropView.value = next;
  tabView.value = tab;
}

/** WT1: the tab drop window [id]'s bar makes at (x, y) - another window's bar there - or null. */
function tabTarget(id: number, x: number, y: number) {
  const z = tabAt(x, y, barsUnder(id));
  return z?.kind === "tab" ? { id, target: z.tile, at: z.at } : null;
}

/** GL1: the tile drop window [id] makes at (x, y) over its page's tiles (a tile's bar is the tab drop's), or null. */
function tileDrop(id: number, x: number, y: number) {
  const w = webWins.value.find((v) => v.id === id);
  const t = w && tilings.value[w.page];
  if (!w || !t) return null;
  const grid = { tiles: tileRects(t, tileArea()), area: boxOf(tileArea()), bar: TITLE };
  return dropAt(x, y, grid, (z) => (z.kind === "tab" ? null : landing(w.page, id, z)));
}

/** Let go of window [id]'s bar drag at (x, y): the previewed tab drop or tile drop, else an edge snap. */
function release(id: number, x: number, y: number) {
  const drop = dropView.value;
  const tab = tabView.value;
  dropView.value = tabView.value = null;
  if (tab?.id === id) return joinStack(tab);
  // GL1: over the tiles, the previewed drop; with none (no tiles yet, a full grid), an edge snap as before.
  if (drop?.id === id) return dock(drop);
  const slot = snapSlot(x, y);
  if (slot) tile(id, slot);
}

/** The previewed drop made: the new tiling, a swapped-out window floating again, the tiles re-flowing ([reflow]). */
function dock(l: Landing) {
  reflow(l.page);
  setTiling(l.page, l.tiling);
  for (const o of l.out) refloat(o);
  holdAppSizes(l.tiling.ids);
  console.info(`[tiles] window ${l.id} docked: page ${l.page} ${l.tiling.layout} [${l.tiling.ids.join(",")}]`);
}

// ---- tabs: windows stacked under one bar (WT1-WT3) -------------------------------------------------------------------
//
// The user, 10-31 01:30/01:31: "we should be able to like add tabs. So that I can like, group Dolphin and Chrome
// together." / "grab the title bar of Dolphin and drag it into the title bar of Chrome, and then they can share a title
// bar and they can tap between them." A stack is windows (Android or Linux alike) sharing one frame: its shown tab is a
// window like any other (moved, resized, tiled, paged, minimised as one), the others are hidden - not rendered, sent to
// the host as hidden entries of the same size ([hiddenEntry]) - and keep running. A switch hands the shown tab's frame,
// tile and z place to the new one ([showTab]). Held in a signal beside [tilings], with the same lifetime.

export interface Stack {
  /** Its windows, in tab order (2 or more: a stack of one is no stack). */
  ids: number[];
  /** The shown tab. */
  active: number;
}
export const stacks = signal<Stack[]>([]);
/** A drag's tab drop in progress: window [id] (with its stack) onto [target]'s bar, at tab index [at] (-1: the end). */
export const tabView = signal<{ id: number; target: number; at: number } | null>(null);
const tabKey = (v: { target: number; at: number } | null | undefined) => (v ? `tab:${v.target}:${v.at}` : "");

export const stackOf = (id: number) => stacks.value.find((s) => s.ids.includes(id));
/** Window [id] is a stack's hidden tab (not shown, running). */
export const hiddenTab = (id: number) => {
  const s = stackOf(id);
  return !!s && s.active !== id;
};
const setStacks = (next: Stack[]) => (stacks.value = next.filter((s) => s.ids.length >= 2));

/** Tab [id] shown: it takes the shown tab's frame, tile and place in the z order; that one is hidden (running). */
export function showTab(id: number) {
  const s = stackOf(id);
  if (!s || s.active === id) return;
  const from = webWins.value.find((w) => w.id === s.active);
  const me = webWins.value.find((w) => w.id === id);
  stacks.value = stacks.value.map((v) => (v === s ? { ...v, active: id } : v));
  if (!from || !me) return;
  const rest = webWins.value.filter((w) => w.id !== id);
  rest.splice(rest.indexOf(from) + 1, 0, me);
  webWins.value = rest;
  const p = tiledOn(from.id);
  if (p != null) tilings.value = { ...tilings.value, [p]: { ...tilings.value[p], ids: tilings.value[p].ids.map((v) => (v === from.id ? id : v)) } };
  if (tileMenu.value === from.id) tileMenu.value = null;
  const { page, x, y, w, h, scale, restore, untiled, minimised } = from;
  update(id, { page, x, y, w, h, scale, restore, untiled, minimised });
}

/** Window [id] out of its stack (closed, undocked): shown, its neighbour takes its place first. */
function leaveStack(id: number) {
  const s = stackOf(id);
  if (!s) return;
  const i = s.ids.indexOf(id);
  if (s.active === id) showTab(s.ids[i + 1] ?? s.ids[i - 1]);
  setStacks(stacks.value.map((v) => (v.ids.includes(id) ? { ...v, ids: v.ids.filter((t) => t !== id) } : v)));
}

/** The previewed tab drop made: window [id] (its whole stack, if it has one) into [target]'s tabs at [at], shown. */
function joinStack(t: { id: number; target: number; at: number }) {
  const moving = stackOf(t.id)?.ids ?? [t.id];
  const into = stackOf(t.target);
  const base = (into?.ids ?? [t.target]).filter((v) => !moving.includes(v));
  const at = t.at < 0 ? base.length : Math.min(t.at, base.length);
  const ids = [...base.slice(0, at), ...moving, ...base.slice(at)];
  setStacks([...stacks.value.filter((v) => v !== into && !v.ids.includes(t.id)), { ids, active: into?.active ?? t.target }]);
  showTab(t.id);
  hapticConfirm();
  console.info(`[tabs] window ${t.id} joined ${t.target}: [${ids.join(",")}]`);
}

/** Tab [id] dragged out of its stack's bar: a floating window of the stack's size, shown, on top (the drag goes on). */
function undock(id: number) {
  const s = stackOf(id);
  const from = s && webWins.value.find((w) => w.id === s.active);
  if (!from) return;
  const size = from.restore ?? from;
  leaveStack(id);
  update(id, { page: from.page, w: size.w, h: size.h, scale: from.scale, restore: undefined, untiled: undefined, minimised: false });
  raise(id);
  hapticTick();
}

/** Tab [id] dragged along its bar to [x]: its place among the others' tabs (a tick as it changes). */
function reorder(id: number, shown: number, x: number) {
  const s = stackOf(id);
  if (!s) return;
  const els = [...document.querySelectorAll<HTMLElement>(`.webwindow[data-wwid="${shown}"] .ww-tab[data-tab]`)].filter((e) => Number(e.dataset.tab) !== id);
  const others = els.map((e) => Number(e.dataset.tab));
  const at = insertAt(els.map((e) => boxOfRect(e.getBoundingClientRect())), x);
  const ids = [...others.slice(0, at), id, ...others.slice(at)];
  if (ids.join() === s.ids.join()) return;
  stacks.value = stacks.value.map((v) => (v === s ? { ...v, ids } : v));
  hapticTick();
}

const boxOfRect = (r: DOMRect): Box => ({ x: r.left, y: r.top, w: r.width, h: r.height });

/** The other windows on [id]'s page (bottom first): their frames, bars and tabs, viewport px ([tabAt]). */
function barsUnder(id: number): Bar[] {
  const own = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${id}"]`);
  const out: Bar[] = [];
  for (const el of own?.parentElement?.querySelectorAll<HTMLElement>(":scope > .webwindow[data-wwid]") ?? []) {
    const wid = Number(el.dataset.wwid);
    if (wid === id) continue;
    const bar = el.querySelector(".webwindow-title");
    const tabs = [...el.querySelectorAll(".ww-tab[data-tab]")];
    const list = tabs.length ? tabs : [...el.querySelectorAll(".ww-title-label")];
    out.push({ id: wid, frame: boxOfRect(el.getBoundingClientRect()), bar: bar ? boxOfRect(bar.getBoundingClientRect()) : undefined, tabs: list.map((t) => boxOfRect(t.getBoundingClientRect())) });
  }
  return out;
}

/** How long the windows glide to their new tiles after a drop ("ww-reflow" in shell.css: the same time). */
const REFLOW_MS = 220;
/** The page whose windows are re-flowing (their frames transition), or null. */
const reflowing = signal<number | null>(null);
let reflowTimer = 0;
function reflow(page: number) {
  reflowing.value = page;
  clearTimeout(reflowTimer);
  reflowTimer = window.setTimeout(() => {
    reflowing.value = null;
    for (const id of held.splice(0)) resizing.delete(id);
    resendGeometry();
  }, REFLOW_MS);
}

/**
 * RS1 for the glide: each app relayouts ONCE, to its final tile (paced as a resize drag, never re-paced while the frame
 * moves), not on every frame of the transition; the end sends the bodies' own sizes.
 */
const held: number[] = [];
function holdAppSizes(ids: (number | null)[]) {
  for (const w of webWins.value) {
    if (!ids.includes(w.id) || resizing.has(w.id)) continue;
    resizing.set(w.id, { cw: w.w, ch: w.h - (w.ownFrame ? 0 : TITLE), frame: 0, last: Infinity, lastAt: Infinity, steps: 0, reqs: 0 });
    held.push(w.id);
  }
}

/** The drop's preview: the tile the window would take, translucent; it glides between zones. */
function DropPreview({ d, o }: { d: Landing & { zone: Zone }; o: { x: number; y: number } }) {
  const r = d.rect;
  const style = { left: `${r.x - o.x}px`, top: `${r.y - o.y}px`, width: `${r.w}px`, height: `${r.h}px`, zIndex: 999 };
  return (
    <div class={`ww-drop ${d.zone.kind}`} data-zone={dropKey(d.zone)} style={style}>
      {d.zone.kind === "swap" && <span class="ww-drop-label tile">Swap</span>}
    </div>
  );
}

/**
 * TG2: a divider goes anywhere across the area - only a tile's minimum size ([MIN_TILE], CSS px along the divider's
 * axis) limits it, with a light pull to the half (within [HALF_PULL] px). Pushed past that minimum to within
 * [DROP_PX] of the edge, the squeezed side goes to the dock.
 */
export const MIN_TILE = { x: 160, y: 96 };
const HALF_PULL = 12;
export const DROP_PX = 32;
/** The divider's ratio of [span] px let go at [r]: a tile at least [MIN_TILE] each side, pulled to the half. */
export function dividerRatio(r: number, span: number, axis: "x" | "y"): number {
  const min = Math.min(0.5, MIN_TILE[axis] / span);
  const near = Math.abs(r - 0.5) * span < HALF_PULL ? 0.5 : r;
  return Math.min(1 - min, Math.max(min, near));
}

/**
 * A divider drag ended ([DividerEl]): "<page>:<axis>" at [ratio] (already snapped), or [drop]: the windows squeezed to an
 * edge. Those go to the dock (minimised, alive: a tap on their dock icon brings them back floating), the rest close
 * up. Not closed (the app's state would go) and not floated on top (it would cover the tile the user just widened);
 * the user asked the same of Android's split, 2026-10-29: dragging it to the edge should tuck it away, not close it.
 */
function divided(m: { key: string; ratio: number; drop?: number[] }) {
  const [p, which] = m.key.split(":");
  const page = Number(p);
  const t = tilings.value[page];
  if (!t) return;
  if (m.drop?.length) {
    for (const id of m.drop) untile(id, "minimise");
    return;
  }
  setTiling(page, which === "x" || which === "rx" ? { ...t, rx: m.ratio } : { ...t, ry: m.ratio });
}

/**
 * A divider between tiles: a DOM handle in its page (it moves with a page swipe, home's swipes leave it alone). Its drag
 * follows the finger; let go, the split snaps to a third, a half or two thirds - or, within [DROP_SHARE] of an edge,
 * the squeezed side's windows go to the dock (see "webwindows.divider" above, the same rules).
 */
function DividerEl({ page, d, o }: { page: number; d: Divider; o: { x: number; y: number } }) {
  const [shift, setShift] = useState(0);
  const start = useRef<number | null>(null);
  const vertical = d.axis === "x";
  const style = {
    position: "absolute",
    left: `${(vertical ? d.pos - TILE_GAP / 2 + shift : d.from) - o.x}px`,
    top: `${(vertical ? d.from : d.pos - TILE_GAP / 2 + shift) - o.y}px`,
    width: `${vertical ? TILE_GAP : d.len}px`,
    height: `${vertical ? d.len : TILE_GAP}px`,
    zIndex: 1000,
    touchAction: "none",
  } as const;
  const at = (e: PointerEvent) => (vertical ? e.clientX : e.clientY);
  const end = (e: PointerEvent, cancelled: boolean) => {
    if (start.current == null) return;
    e.stopPropagation();
    const span = d.hi - d.lo;
    const p = d.pos + at(e) - start.current - d.lo;
    const r = p / span;
    start.current = null;
    setShift(0);
    if (cancelled) return;
    const drop = p < DROP_PX ? d.before : p > span - DROP_PX ? d.after : [];
    const ratio = dividerRatio(r, span, d.axis);
    divided({ key: `${page}:${d.ratio}`, ratio, drop });
    console.info(`[tiles] divider ${page}:${d.axis} let go at ${r.toFixed(2)} -> ${drop.length ? `windows ${drop} to the dock` : `at ${ratio.toFixed(2)}`}`);
  };
  return (
    <div
      class="webwindow ww-divider"
      data-div={`${page}:${d.ratio}`}
      style={style}
      onPointerDown={(e) => {
        e.stopPropagation();
        capture(e);
        start.current = at(e);
      }}
      onPointerMove={(e) => {
        if (start.current == null) return;
        e.stopPropagation();
        // To the very edge (TG2): past the minimum tile it shows the drop to the dock.
        const lo = d.lo + TILE_GAP - d.pos;
        const hi = d.hi - TILE_GAP - d.pos;
        setShift(Math.min(hi, Math.max(lo, at(e) - start.current)));
      }}
      onPointerUp={(e) => end(e, false)}
      onPointerCancel={(e) => end(e, true)}
    />
  );
}

// ---- geometry to the host (docs/WEB_WINDOWS.md "Element model") ----------------------------------------------------------
//
// Each frame while there are windows, every window's BODY element is measured as it shows: its rect after every
// transform (a page swipe, the screens' slide to PowOS AI, the drawer's zoom, the window's own scale), the part its
// ancestors' clips and the screen let show, its visibility (off page, under a full-screen overlay, faded out) and its
// DOM order. The host puts the app's layer exactly there, on the draw that shows this frame (FrameSync), so the layer
// and the page's pixels can't be a frame apart - mid-swipe too.

const px = (v: number) => (Math.round(v * 100) / 100).toString();
let lastGeometry = "";
let raf = 0;

/** Overlays that cover all of home: a window under one is hidden (its layer, not only its pixels). */
const OVERLAYS = ".folder-view.open";

type Clip = [number, number, number, number];

/** [clip] narrowed to [q] along x and/or y. */
function narrow(clip: Clip, q: DOMRect, x: boolean, y: boolean) {
  if (x) (clip[0] = Math.max(clip[0], q.left), (clip[2] = Math.min(clip[2], q.right)));
  if (y) (clip[1] = Math.max(clip[1], q.top), (clip[3] = Math.min(clip[3], q.bottom)));
}

/** One ancestor's share of [shown]: its opacity (0: hidden), and its clip into [clip]. */
function ancestor(a: HTMLElement, clip: Clip): number {
  const cs = getComputedStyle(a);
  // Its own page's area always clips it (PS2), whatever the page's overflow.
  const page = a.classList.contains("page");
  const x = page || cs.overflowX !== "visible";
  const y = page || cs.overflowY !== "visible";
  if (x || y) narrow(clip, a.getBoundingClientRect(), x, y);
  return cs.visibility === "hidden" || cs.display === "none" ? 0 : parseFloat(cs.opacity) || 0;
}

/** What of [el] its clipping ancestors and the screen let show (viewport CSS px, l t r b), and its ancestors' opacity. */
function shown(el: HTMLElement): { clip: Clip; alpha: number } {
  const r = el.getBoundingClientRect();
  const clip: Clip = [Math.max(0, r.left), Math.max(0, r.top), Math.min(innerWidth, r.right), Math.min(innerHeight, r.bottom)];
  let alpha = 1;
  for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) alpha *= ancestor(a, clip);
  return { clip, alpha };
}

/**
 * Maximised, the bar merges with the status bar: "<title's end> <controls' start>" (the status bar's between), else "-1 -1".
 * Never a tiled window's (the status bar spans the full screen while tiled - 10-31: its clock sat at x 234, laid out
 * to a lone tile's bar, when the last tile was made a maximised window), and only while that bar is on the strip.
 */
function mergeOf(w: WebWin, el: HTMLElement): string {
  if (!w.restore || tiledOn(w.id) != null) return "-1 -1";
  const title = el.querySelector(".ww-title-label")?.getBoundingClientRect();
  const controls = el.querySelector(".ww-controls")?.getBoundingClientRect();
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || TITLE;
  return title && controls && title.top < inset ? `${px(title.right)} ${px(controls.left)}` : "-1 -1";
}

/**
 * One window's entry, or null (its page isn't in the DOM): "<id> <frame x y w h> <body x y w h> <clip l t r b>
 * <radius> <visible> <alpha> <scale> <maximised> <titleEnd> <controls> <resizing> <app w> <app h> <fill>", viewport
 * CSS px after transforms ([sizeOf]: the app's paced size during a resize drag, unscaled; [fillOf]: the theme surface).
 */
export function entry(w: WebWin): string | null {
  const el = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${w.id}"]`);
  const body = el?.querySelector<HTMLElement>(".webwindow-body");
  if (!el || !body) return null;
  const f = el.getBoundingClientRect();
  const b = body.getBoundingClientRect();
  const scale = body.offsetWidth ? b.width / body.offsetWidth : 1;
  const { clip, alpha } = shown(body);
  const visible = !document.querySelector(OVERLAYS) && alpha > 0.01 && clip[2] > clip[0] && clip[3] > clip[1];
  const rects = [f.left, f.top, f.width, f.height, b.left, b.top, b.width, b.height, ...clip].map(px);
  return [w.id, ...rects, RADIUS * scale, visible ? 1 : 0, px(alpha), px(scale), w.restore ? 1 : 0, mergeOf(w, el), sizeOf(w, body), fillOf()].join(" ");
}

// ---- RS1/RS2: a resize drag paces the app's relayouts --------------------------------------------------------------
// The frame (and the layer's crop) follows the finger every frame; the app's own size - what the host resizes its
// display / KWin window to, each one a relayout and a new buffer - only every [RELAYOUT_FRAMES] frames and at least
// [RELAYOUT_MS] apart, newest size wins. Until it draws at it, the host shows the app's last buffer anchored top left,
// clipped to the body, over the theme's surface (never stretched). The press ends: the body's size, once (the final).
// Before (10-30, the user: "it's just lagging after, eventually it's catching up"): one VD resize per step, queued.

/** RS1: at least this many page frames, and ms, between two of the app's relayouts while an edge is dragged. */
const RELAYOUT_FRAMES = 3;
const RELAYOUT_MS = 40;

/** A resize drag in progress, by window id: the app's paced size (body CSS px, unscaled), its counts for the log. */
interface Resizing {
  cw: number;
  ch: number;
  frame: number;
  last: number;
  lastAt: number;
  steps: number;
  reqs: number;
}
const resizing = new Map<number, Resizing>();

/** A resize grab on window [id] began: its app's size paced from now ([pace]) until [resizeEnd]. */
function resizeStart(id: number) {
  resizing.set(id, { cw: -1, ch: -1, frame: 0, last: -Infinity, lastAt: -Infinity, steps: 0, reqs: 0 });
}

/** The grab ended: the next "w.f" has the body's size as the app's (the final relayout); the counts kept for the gate. */
function resizeEnd(id: number) {
  const r = resizing.get(id);
  if (!r) return;
  resizing.delete(id);
  lastResize = { id, steps: r.steps, reqs: r.reqs };
  resendGeometry();
}
let lastResize: { id: number; steps: number; reqs: number } | null = null;

/** Once per page frame, before measuring: window [id]'s app size moves to its body's when its pace allows. */
function pace(id: number, r: Resizing, now: number) {
  r.frame++;
  const body = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${id}"] .webwindow-body`);
  if (!body) return;
  const [w, h] = [body.offsetWidth, body.offsetHeight];
  if (w === r.cw && h === r.ch) return;
  if (r.frame - r.last < RELAYOUT_FRAMES || now - r.lastAt < RELAYOUT_MS) return;
  (r.cw = w), (r.ch = h), (r.last = r.frame), (r.lastAt = now), r.reqs++;
}

/**
 * "<resizing> <app w> <app h>": the app's size in CSS px - a paced drag's, else the body's layout size. Always the
 * layout size, never one measured after transforms: the host rounds it to device px ONCE (x dpr), so a page zoom, a
 * swipe or a rounded scale can't move the app's display by a pixel each frame (10-30: "After I rescaled YouTube it's
 * like flickering" - the size came from the transformed rect / a 2-decimal scale, a resize per frame).
 */
function sizeOf(w: WebWin, body: HTMLElement): string {
  const r = resizing.get(w.id);
  return r && r.cw > 0 ? `1 ${r.cw} ${r.ch}` : `0 ${body.offsetWidth} ${body.offsetHeight}`;
}

/** The theme's surface as "rrggbb" (the host's fill under a resized app's last buffer), cached by its token's value. */
let fillKey = "";
let fillHex = "000000";
function fillOf(): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue("--color-surface").trim();
  if (v === fillKey) return fillHex;
  fillKey = v;
  const ctx = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  if (!ctx || !v) return fillHex;
  ctx.fillStyle = v;
  ctx.fillRect(0, 0, 1, 1);
  const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data;
  fillHex = [r, g, b].map((c) => c.toString(16).padStart(2, "0")).join("");
  return fillHex;
}

/**
 * W-IN1: bumped in the frame any window's geometry changes - a move, a resize, a snap or its transition, open, close,
 * raise, full screen, a page swipe carrying it, a fold. Home re-reports the pull-exclusion regions from it (home.tsx),
 * so they follow the same per-frame geometry as the layer (03:15: "the window resized, but ... the touch handlers
 * didn't realize": they were refreshed only on webWins changes, then read mid-transition).
 */
export const windowFrame = signal(0);

/** "<dpr> <n> <entries...>": every window the page shows, bottom first (DOM order = z-order). */
export function geometry(): string {
  const parts: string[] = [];
  for (const w of webWins.value) {
    const e = w.pending || hiddenTab(w.id) ? null : entry(w);
    if (!e) continue;
    for (const t of stackOf(w.id)?.ids ?? []) if (t !== w.id) parts.push(hiddenEntry(e, t));
    parts.push(e);
  }
  return [devicePixelRatio, parts.length, ...parts].join(" ");
}

/**
 * WT3: a stack's hidden tab [id] as its shown tab's [entry] - the same frame, body and app size (so its display keeps
 * the stack's size and a switch is instant, no relayout) - but not visible: the host hides its layer (WebWindows.place:
 * "hidden is the layer, never the display's surface"), as for any window off screen, and it composites nothing. Its app
 * keeps running on its display; never minimised (that is a home gesture: PiP, its task to display 0).
 */
function hiddenEntry(entry: string, id: number): string {
  const f = entry.split(" ");
  // 0 id, 1-12 frame/body/clip, 13 radius, 14 visible, 15 alpha, 16 scale, 17 maximised, 18-19 merge.
  f[0] = String(id);
  f[14] = "0";
  f[17] = "0";
  f[18] = f[19] = "-1";
  return f.join(" ");
}

/** For the gate and CDP (`__ww.sent`): the last "w.f" lines (sent, or measured with no host), newest last. */
const sent: string[] = [];
(globalThis as { __ww?: unknown }).__ww = {
  sent,
  geometry,
  get lastResize() {
    return lastResize;
  },
  get direct() {
    return geometryChannel.direct;
  },
  set direct(on: boolean) {
    geometryChannel.direct = on;
  },
};

/**
 * Each frame while there are windows: their geometry tagged with this page frame, when it changed. The line ends with
 * the frame's rAF time as wall-clock ms (Date.now() less the time since the rAF timestamp; WebView's timeOrigin read
 * ~593 s off the host's clock on the phone, 10-30): the host counts the window draws
 * between it and the apply (FrameSync.pageLag, "pf=" in the host's "w.f" log).
 */
function tick(ts: number) {
  raf = 0;
  for (const [id, r] of resizing) pace(id, r, ts);
  const g = geometry();
  if (g !== lastGeometry) {
    lastGeometry = g;
    windowFrame.value++;
    const id = nextFrameId();
    const now = Date.now();
    // Two stamps (wall-clock ms): the rAF's frame time, and now - the send - so the host splits its "rx=" into the page's
    // own share (vsync to this send: rAF scheduling and measuring) and the hop to the host.
    const line = `w.f ${id} ${g} ${(now - (performance.now() - ts)).toFixed(2)} ${now}`;
    sent.push(line);
    if (sent.length > 120) sent.shift();
    if (native.value) {
      console.timeStamp(`ww f${id}`);
      sendGeometry(line);
    }
  }
  if (webWins.value.length) raf = requestAnimationFrame(tick);
}

function kick() {
  if (!raf) raf = requestAnimationFrame(tick);
}

/**
 * The next frame sends every window's geometry even if unchanged: a transition (full screen and back, a resize's end,
 * a layer the host re-made) commits the whole layer state - parent, z, crop, position, visibility - at once, never
 * only on the next move (10-30 22:59: a window back from full screen showed a bare hole until it was dragged).
 */
function resendGeometry() {
  lastGeometry = "";
  kick();
}
webWins.subscribe(kick);
tilings.subscribe(kick);
// A new port (the page reloaded or the host came back): its layers know nothing yet.
native.subscribe(() => {
  lastGeometry = "";
  kick();
});

// ---- the window element: DOM title bar, buttons, edges, tile menu, the body ------------------------------------------

/** The window whose tile menu is open, or null. */
export const tileMenu = signal<number | null>(null);

/** A double tap on the bar within this (ms): full screen, as its bar's full screen button (the user, 10-30). */
const DOUBLE_TAP_MS = 350;
/** A bar drag let go this near the work area's left/right edge snaps to that half; near a corner, its quarter. */
const SNAP_EDGE = 24;
const SNAP_CORNER = 120;
const SLOP = 6;

/** The corner or half each side snaps to: top, middle, bottom of the work area. */
const SNAPS_AT: Record<"l" | "r", [Slot, Slot, Slot]> = { l: ["tl", "left", "bl"], r: ["tr", "right", "br"] };

/** Where a bar drag let go at ([x], [y]) snaps (docs "Tiles": drag to an edge), or null. */
function snapSlot(x: number, y: number): Slot | null {
  const a = tileArea();
  const side = x <= a.left + SNAP_EDGE ? "l" : x >= a.right - SNAP_EDGE ? "r" : null;
  if (!side) return null;
  const row = y <= a.top + SNAP_CORNER ? 0 : y >= a.bottom - SNAP_CORNER ? 2 : 1;
  return SNAPS_AT[side][row];
}

/**
 * Its bar's buttons, right to left: close, full screen, minimise, tile (the old native bar's order). Only the id and
 * whether it is maximised: the whole window re-rendered them (4 Marks) on every frame of its drag (render scan 10-31).
 */
const Controls = memo(function Controls({ id, restore }: { id: number; restore: boolean }) {
  const press = (f: () => void) => ({
    onPointerDown: (e: PointerEvent) => e.stopPropagation(),
    onClick: (e: MouseEvent) => (e.stopPropagation(), f()),
  });
  return (
    <div class="ww-controls">
      <button class="ww-button" aria-label="Tile" {...press(() => (tileMenu.value = tileMenu.value === id ? null : id))}>
        <Mark kind="tile" />
      </button>
      <button class="ww-button" aria-label="Minimise" {...press(() => minimise(id))}>
        <Mark kind="minimise" />
      </button>
      <button class="ww-button" aria-label="Full screen" {...press(() => fullScreen(id))}>
        <Mark kind={restore ? "restore" : "maximise"} />
      </button>
      <button class="ww-button ww-close" aria-label="Close" {...press(() => close(id))}>
        <Mark kind="close" />
      </button>
    </div>
  );
});

/** Full screen = a real full-screen app on the main display (WebWindows.fullScreen); with no host, the work area. */
function fullScreen(id: number) {
  tileMenu.value = null;
  if (native.value && powos.webwindows?.fullScreen && id >= 0) void powos.webwindows.fullScreen(id);
  else toggleMaximise(id);
}

function close(id: number) {
  tileMenu.value = null;
  // A placeholder (id < 0, LW3) is the page's alone.
  if (native.value && powos.webwindows?.close && id >= 0) void powos.webwindows.close(id);
  else {
    leaveStack(id);
    untile(id, "gone");
    webWins.value = webWins.value.filter((w) => w.id !== id);
  }
}

/** The tile menu, under the tile button: DOM over the window's body (it takes its taps by DOM order). */
function TileMenu({ win }: { win: WebWin }) {
  const tiled = tiledOn(win.id) != null;
  const items: [Slot, string][] = [["left", "Left half"], ["right", "Right half"], ["top", "Top half"], ["bottom", "Bottom half"], ["grid", "Grid"]];
  if (tiled) items.push(["float", "Float"]);
  return (
    <div class="ww-tile-menu tile sheet pop" onPointerDown={(e) => e.stopPropagation()}>
      {items.map(([slot, label]) => (
        <button
          key={slot}
          class="ww-tile-item"
          data-slot={slot}
          onClick={(e) => {
            e.stopPropagation();
            tileMenu.value = null;
            tile(win.id, slot);
          }}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
// A press anywhere else closes the tile menu.
addEventListener("pointerdown", (e) => {
  if (tileMenu.value != null && !(e.target as Element | null)?.closest?.(".ww-tile-menu, .ww-button")) tileMenu.value = null;
}, true);

/**
 * A window's one-finger gesture in progress (its bar's move, an edge's resize, its body's press to the app): how to end
 * it unfinished when a second finger makes the gesture a pinch ([usePinch]). The body's sends the app a cancel.
 */
const oneFinger = new Map<number, () => void>();

/** PZ1: a window's body taking another finger of its gesture that landed off the body (the bar, a zone), by window id. */
const bodyFinger = new Map<number, (e: PointerEvent) => void>();

/** A pinch's floor (the old native frame's MIN_SCALE) and ceiling (never past the work area either: [usePinch]). */
export const MIN_SCALE = 0.4;
export const MAX_SCALE = 1.5;

/**
 * SC1 (the user, 10-31: "Doing the two finger scaling motion is no longer scaling it, it's resizing it"): two fingers
 * on a window (bar or body) SCALE it - the whole frame, bar and app, zoomed uniformly like a picture; the app keeps its
 * size (w, h: no relayout), its layer is drawn at the frame's measured scale (entry()). Scale = start x spread / start
 * spread, [MIN_SCALE]..[MAX_SCALE] and no bigger than the work area; the window point under the fingers' centroid stays
 * under it. The scale is saved with the window. An edge or a grip RESIZES (w, h; the bar stays [TITLE]: RB1). The
 * first finger's gesture ends unfinished ([oneFinger]). One finger never scales: a primary pointer down starts a new
 * touch.
 * PZ1 (the user, 10-31 01:40: "I shouldn't be able to rescale the window with two fingers unless I'm pressing the
 * corners/resizers. If I zoom normally IN the app, I'm now resizing the window"): only a gesture whose FIRST finger is on
 * the chrome (the bar, an edge zone or corner grip) scales; a second finger on the body then is still the pinch's. A
 * gesture that starts on the body is the app's, every finger ([Body]: one multi-touch gesture, a pinch zooms Chrome's
 * page), a later finger off the body included ([bodyFinger]).
 */
function usePinch(win: WebWin) {
  const fingers = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef<{ spread0: number; s0: number; px: number; py: number } | null>(null);
  const onBody = useRef(false);
  const live = useRef(win);
  live.current = win;
  const spread = () => {
    const [a, b] = [...fingers.current.values()];
    return { cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2, d: Math.hypot(a.x - b.x, a.y - b.y) };
  };
  // PZ1: finger [e] counted; true = the gesture is the body's (its first finger was there): never a pinch.
  const bodyGesture = (e: PointerEvent) => {
    const inBody = !!(e.target as Element | null)?.closest?.(".webwindow-body");
    if (!fingers.current.size) onBody.current = inBody;
    fingers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (onBody.current && !inBody) (e.stopPropagation(), bodyFinger.get(win.id)?.(e));
    return onBody.current;
  };
  const down = (e: PointerEvent) => {
    // The first finger of a new touch starts clean: an earlier finger's up that landed outside this frame was never
    // seen here, and a stale entry made the next one-finger drag a pinch (10-30: "dragging with one finger rescales").
    if (e.isPrimary) (fingers.current.clear(), (pinch.current = null));
    if (bodyGesture(e) || fingers.current.size !== 2 || pinch.current) return;
    e.stopPropagation();
    oneFinger.get(win.id)?.();
    oneFinger.delete(win.id);
    const w = live.current;
    if (tiledOn(w.id) != null) untile(w.id, "keep");
    const o = pageOrigin();
    const f = spread();
    const s0 = w.scale ?? 1;
    pinch.current = { spread0: f.d, s0, px: (f.cx - o.x - w.x) / s0, py: (f.cy - o.y - w.y) / s0 };
  };
  const move = (e: PointerEvent) => {
    if (!fingers.current.has(e.pointerId)) return;
    fingers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const p = pinch.current;
    if (!p) return;
    e.stopPropagation();
    if (fingers.current.size < 2) return;
    const f = spread();
    const w = live.current;
    const a = workArea();
    const top = Math.max(MIN_SCALE, Math.min(MAX_SCALE, (a.right - a.left) / w.w, (a.bottom - a.top) / w.h));
    const k = p.spread0 > 0 ? Math.min(top, Math.max(MIN_SCALE, (p.s0 * f.d) / p.spread0)) : p.s0;
    const o = pageOrigin();
    const at = clampPlace(f.cx - o.x - p.px * k, f.cy - o.y - p.py * k, w.w * k);
    update(w.id, { x: Math.round(at.x), y: Math.round(at.y), scale: Math.round(k * 1000) / 1000, restore: undefined });
  };
  const up = (e: PointerEvent) => {
    fingers.current.delete(e.pointerId);
    if (!pinch.current) return;
    e.stopPropagation();
    if (fingers.current.size === 0) pinch.current = null;
  };
  return { onPointerDownCapture: down, onPointerMoveCapture: move, onPointerUpCapture: up, onPointerCancelCapture: up };
}

/** Its title bar: moves it (a drag), full screen (a double tap), snaps it to a tile (let go at an edge). */
function TitleBar({ win }: { win: WebWin }) {
  const drag = useRef<{ px: number; py: number; x: number; y: number; moved: boolean; tiled: boolean } | null>(null);
  const lastTap = useRef(0);
  const merged = !!win.restore;
  const end = (e: PointerEvent, cancelled: boolean) => {
    const d = drag.current;
    if (!d) return;
    e.stopPropagation();
    drag.current = null;
    if (cancelled || !d.moved) dropView.value = tabView.value = null;
    if (cancelled) return;
    if (!d.moved) {
      const now = performance.now();
      if (now - lastTap.current < DOUBLE_TAP_MS) (fullScreen(win.id), (lastTap.current = 0));
      else lastTap.current = now;
      return;
    }
    release(win.id, e.clientX, e.clientY);
  };
  const aimed = tabView.value?.target === win.id ? tabView.value : null;
  return (
    <div
      class={`webwindow-title ${merged ? "merged" : "tile"}${aimed ? " ww-tab-target" : ""}`}
      style={{ height: `${TITLE}px`, flex: `0 0 ${TITLE}px`, touchAction: "none" }}
      onPointerDown={(e) => {
        e.stopPropagation();
        raise(win.id);
        capture(e);
        drag.current = { px: e.clientX, py: e.clientY, x: win.x, y: win.y, moved: false, tiled: tiledOn(win.id) != null };
        oneFinger.set(win.id, () => ((drag.current = null), (dropView.value = tabView.value = null)));
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        e.stopPropagation();
        const dx = e.clientX - d.px;
        const dy = e.clientY - d.py;
        if (!d.moved && Math.hypot(dx, dy) < SLOP) return;
        if (!d.moved && tiledOn(win.id) != null) untile(win.id, "keep");
        d.moved = true;
        update(win.id, { ...clampPlace(d.x + dx, d.y + dy, win.w), restore: undefined });
        // GL1: a floating window docks; one dragged out of the tiles floats (the tiles fill the area: it would re-dock).
        // WT1: either one joins another window's bar as a tab.
        aim(win.id, e.clientX, e.clientY, !d.tiled);
      }}
      onPointerUp={(e) => end(e, false)}
      onPointerCancel={(e) => end(e, true)}
    >
      <BarLabel win={win} aimed={aimed} merged={merged} />
      <div class="ww-spacer" />
      <div class={merged ? "tile ww-controls-glass" : "ww-controls-glass"}>
        <Controls id={win.id} restore={merged} />
      </div>
    </div>
  );
}

/**
 * WT2: a stack's bar is its tab strip - each tab its app's icon, name and a close; the shown one lit. A drop aimed at
 * this bar ([tabView]) lights the bar and shows a ghost tab where it would land, browser-style (also on a window of
 * one: what the stack would look like).
 */
/** The bar's title: its icon and name, or (a stack, or a tab drop aimed here) the tab strip. */
function BarLabel({ win, aimed, merged }: { win: WebWin; aimed: { id: number; at: number } | null; merged: boolean }) {
  const stack = stackOf(win.id);
  if (stack || aimed) return <Tabs win={win} ids={stack?.ids ?? [win.id]} aimed={aimed} merged={merged} />;
  return (
    <div class={`ww-title-label ${merged ? "tile" : ""}`}>
      {iconOf(win.key) && <img class="ww-icon" src={iconOf(win.key)!} alt="" draggable={false} />}
      <span>{win.label}</span>
    </div>
  );
}

function Tabs({ win, ids, aimed, merged }: { win: WebWin; ids: number[]; aimed: { id: number; at: number } | null; merged: boolean }) {
  const list = ids.map((id) => webWins.value.find((w) => w.id === id)).filter((w): w is WebWin => !!w);
  const items = list.map((w) => <Tab key={w.id} w={w} active={w.id === win.id} shown={win.id} />);
  const ghost = aimed && webWins.value.find((w) => w.id === aimed.id);
  if (ghost) {
    items.splice(aimed.at < 0 ? items.length : aimed.at, 0, (
      <div key="ghost" class="ww-tab ghost">
        {iconOf(ghost.key) && <img class="ww-icon" src={iconOf(ghost.key)!} alt="" draggable={false} />}
        <span>{ghost.label}</span>
      </div>
    ));
  }
  return <div class={`ww-title-label ww-tabs ${merged ? "tile" : ""}`}>{items}</div>;
}

function Tab({ w, active, shown }: { w: WebWin; active: boolean; shown: number }) {
  return (
    <div class={`ww-tab${active ? " active" : ""}`} data-tab={w.id} onPointerDown={(e) => tabPress(e, w.id, shown)}>
      {iconOf(w.key) && <img class="ww-icon" src={iconOf(w.key)!} alt="" draggable={false} />}
      <span>{w.label}</span>
      <button
        class="ww-tab-close"
        aria-label={`Close ${w.label}`}
        onPointerDown={(e) => e.stopPropagation()}
        onClick={(e) => (e.stopPropagation(), close(w.id))}
      >
        <Mark kind="close" />
      </button>
    </div>
  );
}

let lastTabTap = { id: 0, at: 0 };
/**
 * A press on tab [id] of the stack shown as [shown]: a tap shows it (a double tap: full screen, as the bar's), a drag
 * along the bar reorders it, out of the bar (a bar's height off it, or past its ends) undocks it - then it is a bar drag
 * (move, tile drop, edge snap, another bar's tabs). Window listeners: the tab's element goes when its stack does.
 */
function tabPress(e: PointerEvent, id: number, shown: number) {
  if (!e.isPrimary) return;
  e.stopPropagation();
  raise(shown);
  const pid = e.pointerId;
  const bar = (e.currentTarget as HTMLElement).closest(".webwindow-title")!.getBoundingClientRect();
  const grabX = Math.min(e.clientX - (e.currentTarget as HTMLElement).getBoundingClientRect().left, 120);
  const start = { x: e.clientX, y: e.clientY };
  let moved = false;
  let out = false;
  const stop = () => {
    removeEventListener("pointermove", move, true);
    removeEventListener("pointerup", up, true);
    removeEventListener("pointercancel", cancel, true);
    oneFinger.delete(shown);
  };
  const cancel = (ev: PointerEvent) => {
    if (ev.pointerId !== pid) return;
    stop();
    dropView.value = tabView.value = null;
  };
  const move = (ev: PointerEvent) => {
    if (ev.pointerId !== pid) return;
    ev.stopPropagation();
    if (!moved && Math.hypot(ev.clientX - start.x, ev.clientY - start.y) < SLOP) return;
    moved = true;
    const off = Math.abs(ev.clientY - (bar.top + bar.height / 2)) > bar.height || ev.clientX < bar.left - TITLE || ev.clientX > bar.right + TITLE;
    if (!out && off) (out = true), undock(id);
    if (!out) return reorder(id, shown, ev.clientX);
    const w = webWins.value.find((v) => v.id === id);
    if (!w) return;
    const o = pageOrigin();
    update(id, clampPlace(ev.clientX - o.x - grabX, ev.clientY - o.y - TITLE / 2, w.w));
    aim(id, ev.clientX, ev.clientY);
  };
  const up = (ev: PointerEvent) => {
    if (ev.pointerId !== pid) return;
    ev.stopPropagation();
    stop();
    if (out) return release(id, ev.clientX, ev.clientY);
    if (moved) return;
    const now = performance.now();
    if (lastTabTap.id === id && now - lastTabTap.at < DOUBLE_TAP_MS) return (fullScreen(id), (lastTabTap = { id: 0, at: 0 }));
    lastTabTap = { id, at: now };
    showTab(id);
  };
  addEventListener("pointermove", move, true);
  addEventListener("pointerup", up, true);
  addEventListener("pointercancel", cancel, true);
  oneFinger.set(shown, () => (stop(), (dropView.value = tabView.value = null)));
}

const MIN_W = 220;
const MIN_H = 160;
const EDGES = ["n", "s", "e", "w", "ne", "nw", "se", "sw"] as const;

type Grab = { px: number; py: number; x: number; y: number; w: number; h: number };

/** RZ4: a resized frame's side this near (screen px) a tile's (half, third, quarter of the work area, gaps out) snaps to it. */
const SNAP_SIZE = 16;
const SNAP_PARTS = [2, 3, 4];

/** Length [len] (frame px at scale [k]) snapped to a tile's along a work area [span] wide (screen px), or as it is. */
function snapLen(len: number, k: number, span: number): number {
  for (const n of SNAP_PARTS) {
    const t = (span - (n - 1) * TILE_GAP) / n / k;
    if (Math.abs(len - t) * k <= SNAP_SIZE) return t;
  }
  return len;
}

/** One axis of a resize: the frame's new length when its far side ([sign] 1) or near side (-1) follows [d] (0: neither). */
function resizeLen(len: number, d: number, sign: number, o: { min: number; k: number; span: number }): number {
  if (!sign) return len;
  return Math.max(o.min, snapLen(len + sign * d, o.k, o.span));
}
/** A side's sign along an axis: [far] in [side] 1, [near] -1, neither 0. */
const signOf = (side: string, far: string, near: string) => (side.includes(far) ? 1 : side.includes(near) ? -1 : 0);

/** RZ4: the resize in progress (its live size outline): the window, and its snapped sides ("w", "h", "wh" or ""). */
export const resizeView = signal<{ id: number; snapped: string } | null>(null);

/** Window [id]'s frame resized from [s] by pointer [e] on edges [side] (an Edge grab, or the app's own), scale [k]. */
function resizeBy(id: number, s: Grab & { side: string; k: number }, e: PointerEvent) {
  const { side, k } = s;
  const a = tileArea();
  const dx = (e.clientX - s.px) / k;
  const dy = (e.clientY - s.py) / k;
  const r = {
    x: s.x,
    y: s.y,
    w: resizeLen(s.w, dx, signOf(side, "e", "w"), { min: MIN_W, k, span: a.right - a.left }),
    h: resizeLen(s.h, dy, signOf(side, "s", "n"), { min: MIN_H, k, span: a.bottom - a.top }),
  };
  if (side.includes("w")) r.x = s.x + s.w - r.w;
  if (side.includes("n")) r.y = s.y + s.h - r.h;
  // DB1: the top edge stops at the status bar (the bar stays reachable).
  const top = clampPlace(r.x, r.y, r.w).y;
  if (r.y < top) (r.h -= top - r.y), (r.y = top);
  const pacing = resizing.get(id);
  if (pacing) pacing.steps++;
  showSnap(id, r, k, a);
  update(id, { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.w), h: Math.round(r.h), restore: undefined });
}

/** The outline's snapped sides for frame [r]; a haptic tick as a side snaps (RZ4). */
function showSnap(id: number, r: { w: number; h: number }, k: number, a: Area) {
  const on = (len: number, span: number) => SNAP_PARTS.some((n) => Math.abs(len - (span - (n - 1) * TILE_GAP) / n / k) < 0.5);
  const snapped = (on(r.w, a.right - a.left) ? "w" : "") + (on(r.h, a.bottom - a.top) ? "h" : "");
  const was = resizeView.value;
  if (was?.id === id && was.snapped === snapped) return;
  if (snapped && snapped !== was?.snapped) hapticTick();
  resizeView.value = { id, snapped };
}

/** A hold this long, still, on the app's own drag (its tab strip): the tile menu - PowOS's frame features for it. */
const HOLD_MS = 500;

/** An app's own frame drag in progress ("webwindows.moveresize"), by window id: the Body's pointer drives it. */
interface AppDrag {
  edges: string;
  start: Grab | null;
  moved: boolean;
  hold: number;
}
const appDrags = new Map<number, AppDrag>();

/** An edge zone's press this near (frame px) a corner resizes from that corner (RZ2: the strips' ends are the corner's). */
const CORNER_ALONG = 24;

/** The sides a press [e] on edge zone [side] resizes: a strip's end near a corner is that corner. */
function sideAt(side: string, e: PointerEvent): string {
  if (side.length === 2) return side;
  const f = (e.currentTarget as HTMLElement).parentElement!.getBoundingClientRect();
  const near = (v: number, lo: number, hi: number) => (v < lo + CORNER_ALONG ? 0 : v > hi - CORNER_ALONG ? 1 : -1);
  if (side === "e" || side === "w") return (["n", "s"][near(e.clientY, f.top, f.bottom)] ?? "") + side;
  return side + (["w", "e"][near(e.clientX, f.left, f.right)] ?? "");
}

/**
 * A resize grab (RZ2): an invisible zone OUTSIDE the frame - 32 dp along each edge, 48x48 dp off each corner - so it
 * never covers the app or the bar's buttons; a higher window's content is over a lower window's zones (z order: the
 * DOM's hit test). The frame follows the finger, the app's size paced ([pace]: RS1), the final on release; a haptic
 * tick on the grab, the live size outline ([resizeView]) while it lasts, tile sizes snapped to ([snapLen]: RZ4).
 */
function Edge({ id, side, height }: { id: number; side: (typeof EDGES)[number]; height?: string }) {
  const start = useRef<(Grab & { side: string }) | null>(null);
  const stop = (e: PointerEvent) => {
    if (!start.current) return;
    e.stopPropagation();
    start.current = null;
    resizeView.value = null;
    resizeEnd(id);
  };
  return (
    <div
      class={`ww-edge ww-edge-${side}`}
      style={{ height }}
      onPointerDown={(e) => {
        e.stopPropagation();
        const win = webWins.value.find((w) => w.id === id);
        if (!win) return;
        raise(id);
        flashGrips(id);
        capture(e);
        if (tiledOn(id) != null) untile(id, "keep");
        start.current = { px: e.clientX, py: e.clientY, x: win.x, y: win.y, w: win.w, h: win.h, side: sideAt(side, e) };
        hapticTick();
        resizeView.value = { id, snapped: "" };
        resizeStart(id);
        oneFinger.set(id, () => ((start.current = null), (resizeView.value = null), resizeEnd(id)));
      }}
      onPointerMove={(e) => {
        const s = start.current;
        if (!s) return;
        e.stopPropagation();
        resizeBy(id, { ...s, k: webWins.value.find((w) => w.id === id)?.scale ?? 1 }, e);
      }}
      onPointerUp={stop}
      onPointerCancel={stop}
    />
  );
}

const CORNERS = ["se", "sw", "ne", "nw"] as const;

/** RZ6 (the user, 10-31: "We just need to show this briefly ... like when we activate the windows"): how long the grips show. */
export const GRIPS_MS = 1500;
/** The window whose corner grips show now ([flashGrips]); null: none (the zones stay live without them). */
export const gripsOn = signal<number | null>(null);
let gripsTimer = 0;

/** Shows window [id]'s grips for [GRIPS_MS] (an activation, a press on its edge zones), then they fade out. */
export function flashGrips(id: number) {
  gripsOn.value = id;
  clearTimeout(gripsTimer);
  gripsTimer = window.setTimeout(() => {
    if (gripsOn.peek() === id) gripsOn.value = null;
  }, GRIPS_MS);
}

// A window coming to the front (opened, raised, focused): its grips flash.
let frontId: number | undefined;
effect(() => {
  const top = webWins.value.at(-1)?.id;
  if (top === frontId) return;
  frontId = top;
  if (top != null) flashGrips(top);
});

/** The screen's system strips (px from the top / bottom): the status bar's and the gesture bar's, 24 px at least. */
function systemStrips(): { top: number; bottom: number } {
  const css = getComputedStyle(document.documentElement);
  const inset = (name: string) => parseFloat(css.getPropertyValue(name)) || 0;
  return { top: Math.max(24, inset("--inset-top")), bottom: Math.max(24, inset("--inset-bottom")) };
}

/**
 * RZ5: zone [side]'s height clamped out of the system strips (frame px at scale [k]): an n/ne/nw zone never reaches
 * into the status strip, an s/se/sw one never into the bottom gesture area - those touches stay the system's. Undefined:
 * the zone's own size (CSS).
 */
function zoneHeight(win: WebWin, side: string): string | undefined {
  const k = win.scale ?? 1;
  const strips = systemStrips();
  const top = pageOrigin().y + win.y;
  const zone = side.length === 2 ? 48 : 32;
  if (side.startsWith("n")) {
    const room = Math.max(0, top - strips.top);
    return room < zone ? `${room / k}px` : undefined;
  }
  if (side.startsWith("s")) {
    const room = Math.max(0, innerHeight - strips.bottom - (top + win.h * k));
    return room < zone ? `${room / k}px` : undefined;
  }
  return undefined;
}

/** RZ1: a corner's grip - a short arc hugging the frame's rounded corner, outside it (drawn; the zone takes the press). */
function Grip({ corner }: { corner: (typeof CORNERS)[number] }) {
  return (
    <svg class={`ww-grip ww-grip-${corner}`} viewBox="0 0 22 22" aria-hidden="true">
      <path d="M19 2A17 17 0 0 1 2 19" />
    </svg>
  );
}

/**
 * A free window's 8 resize zones and 4 grips: only its id, so a frame of its own move or resize (the window re-renders)
 * leaves them, and their arrays' Fragments, alone (render scan 10-31: all 8 Edges, 4 Grips every frame).
 */
/** The top/bottom zones' heights near the system strips ([zoneHeight]), as one string: [Handles] re-renders only
 *  when one of them changes, not on every frame of a drag. */
const zoneKey = (win: WebWin) => EDGES.map((side) => zoneHeight(win, side) ?? "").join("|");

const Handles = memo(function Handles({ id, zones }: { id: number; zones: string }) {
  const heights = zones.split("|");
  return (
    <>
      {EDGES.map((side, i) => <Edge key={side} id={id} side={side} height={heights[i] || undefined} />)}
      {CORNERS.map((c) => <Grip key={c} corner={c} />)}
    </>
  );
});

/** RZ4: the live size outline round a frame being resized, its size (screen px) in it; brighter on a snapped tile size. */
function ResizeOutline({ win }: { win: WebWin }) {
  const k = win.scale ?? 1;
  const v = resizeView.value;
  return (
    <div class={`ww-outline ${v?.snapped ? "snapped" : ""}`}>
      <span class="ww-outline-size tile">
        {Math.round(win.w * k)} × {Math.round(win.h * k)}
      </span>
    </div>
  );
}

/**
 * WS1: a window's drop shadow, the widgets' lift but deeper (it floats higher), the focused one's stronger: its own
 * element under the frame, so the frame's mask (a higher window's hole) never cuts it; masked itself where the windows
 * above it are (a lower window's shadow never darkens a higher one's app). Outside the frame only: never on its app.
 */
function WindowShadow({ win, z, above, focused }: { win: WebWin; z: number; above: WebWin[]; focused: boolean }) {
  if (win.restore) return null;
  const b = frameBox(win);
  const style = {
    left: `${b.x - SHADOW_PAD}px`,
    top: `${b.y - SHADOW_PAD}px`,
    width: `${b.w + 2 * SHADOW_PAD}px`,
    height: `${b.h + 2 * SHADOW_PAD}px`,
    zIndex: 20 + z,
    ...holes(above, { x: b.x - SHADOW_PAD, y: b.y - SHADOW_PAD, s: 1 }),
  };
  return (
    <div class={`ww-shadow ${focused ? "focused" : ""} ${reflowing.value === win.page ? "ww-reflow" : ""}`} style={style}>
      <div style={{ inset: `${SHADOW_PAD}px` }} />
    </div>
  );
}
/** How far past the frame its shadow's element reaches (its blur and offset fit in it). */
const SHADOW_PAD = 64;

/**
 * The app's place. Live, it paints NOTHING: the page is transparent over it and the app's layer (under home's buffer)
 * shows there. Until its first frame it is a solid placeholder (the app's icon and a quiet progress line on the theme's
 * surface: the manager's LW1), never a hole. A press on it (the DOM's hit test: anything above it in the DOM wins) goes
 * to the app - the window raised, so it is in front and focused, the same for Android and Linux apps.
 */
function Body({ win, body }: { win: WebWin; body: { current: HTMLDivElement | null } }) {
  // PZ1: its fingers down now (pointer id -> finger 0, 1, ...: the lowest free), each sent to the app as that finger.
  const pressed = useRef(new Map<number, number>());
  const toApp = (e: PointerEvent, action: "down" | "move" | "up" | "cancel", finger = 0) => {
    e.stopPropagation();
    const el = body.current;
    const r = el?.getBoundingClientRect();
    // The body's on-screen scale as measured (its own scale times every ancestor's: the page's zoom, a swipe), the same
    // as entry()'s: dividing by win.scale alone put presses in the wrong place at a page zoom (x0.53).
    const s = el && el.offsetWidth ? r!.width / el.offsetWidth : (win.scale ?? 1);
    if (r && win.id >= 0) void powos.webwindows?.input(win.id, action, { x: (e.clientX - r.left) / s, y: (e.clientY - r.top) / s, finger });
  };
  const down = (e: PointerEvent) => {
    const p = pressed.current;
    // A new touch: fingers whose up this body never saw end first (the app's gesture never keeps a stale finger).
    if (e.isPrimary && p.size) (p.clear(), toApp(e, "cancel"));
    if (!p.size) raise(win.id);
    try {
      body.current?.setPointerCapture(e.pointerId);
    } catch {}
    let n = 0;
    while ([...p.values()].includes(n)) n++;
    p.set(e.pointerId, n);
    toApp(e, "down", n);
    if (n === 0)
      oneFinger.set(win.id, () => {
        if (!p.size) return;
        p.clear();
        toApp(e, "cancel");
      });
  };
  bodyFinger.set(win.id, down);
  const end = (e: PointerEvent, action: "up" | "cancel") => {
    const n = pressed.current.get(e.pointerId);
    if (n === undefined) return;
    pressed.current.delete(e.pointerId);
    // A cancel ends the app's whole gesture (the host's ACTION_CANCEL is every finger's).
    if (action === "cancel") pressed.current.clear();
    if (n === 0 && appDragEnd(win.id, e, action === "cancel")) return;
    toApp(e, action, n);
  };
  const icon = iconOf(win.key);
  return (
    <div
      class={`webwindow-body ${win.live ? "live" : "placeholder"}`}
      ref={body}
      style={{ flex: 1, touchAction: "none" }}
      onPointerDown={down}
      onPointerMove={(e) => {
        const n = pressed.current.get(e.pointerId);
        if (n !== undefined && !(n === 0 && appDragMove(win.id, e))) toApp(e, "move", n);
      }}
      onPointerUp={(e) => end(e, "up")}
      onPointerCancel={(e) => end(e, "cancel")}
    >
      {!win.live && <Placeholder win={win} icon={icon} />}
    </div>
  );
}

/** Until its first frame: its icon and a progress line; one that couldn't start (LW3) says so, with a close. */
function Placeholder({ win, icon }: { win: WebWin; icon: string | undefined }) {
  return (
    <div class={`ww-placeholder ${win.failed ? "failed" : ""}`}>
      {icon && <img class="ww-placeholder-icon" src={icon} alt="" draggable={false} />}
      {!win.failed && <div class="ww-progress" />}
      {win.failed && <div class="ww-failed-text">Couldn't start {win.label}. {win.failed}</div>}
      {win.failed && (
        <button class="ww-failed-close" onPointerDown={(e) => e.stopPropagation()} onClick={(e) => (e.stopPropagation(), close(win.id))}>
          Close
        </button>
      )}
    </div>
  );
}

/**
 * The app's own frame drag ([appDrags]) with this body's pointer: true = the move was the frame's (the host stopped
 * sending the touch to the app). Its first move is the start; a move as the bar's drag (untiles, clamped), a resize as
 * an edge grab. Held still for [HOLD_MS] from its start: the tile menu instead (PowOS's frame features without a bar).
 */
function appDragMove(id: number, e: PointerEvent): boolean {
  const d = appDrags.get(id);
  if (!d) return false;
  e.stopPropagation();
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return true;
  if (!d.start) {
    d.start = { px: e.clientX, py: e.clientY, x: w.x, y: w.y, w: w.w, h: w.h };
    d.hold = window.setTimeout(() => {
      if (appDrags.get(id) !== d || d.moved) return;
      appDrags.delete(id);
      tileMenu.value = id;
    }, HOLD_MS);
    return true;
  }
  const dx = e.clientX - d.start.px;
  const dy = e.clientY - d.start.py;
  if (!d.moved && Math.hypot(dx, dy) < SLOP) return true;
  if (!d.moved) appDragBegins(id, d.edges);
  d.moved = true;
  if (d.edges === "move") update(id, { ...clampPlace(d.start.x + dx, d.start.y + dy, w.w), restore: undefined });
  else resizeBy(id, { ...d.start, side: d.edges, k: w.scale ?? 1 }, e);
  return true;
}

/** An app's own frame drag's first move: a tiled window untiled; a resize's app size paced from now (RS1). */
function appDragBegins(id: number, edges: string) {
  if (tiledOn(id) != null) untile(id, "keep");
  if (edges !== "move") resizeStart(id);
}

/** The press ended: an app's own frame drag ends with it (let go at an edge: tiled, as the bar's). True: it was one. */
function appDragEnd(id: number, e: PointerEvent, cancelled: boolean): boolean {
  const d = appDrags.get(id);
  if (!d) return false;
  appDrags.delete(id);
  clearTimeout(d.hold);
  e.stopPropagation();
  if (d.edges !== "move") (resizeEnd(id), (resizeView.value = null));
  if (!cancelled && d.moved && d.edges === "move") {
    const slot = snapSlot(e.clientX, e.clientY);
    if (slot) tile(id, slot);
  }
  return true;
}

/**
 * The window: an element of its page (it slides with it, sits in z by DOM order). Its frame, bar and edges paint
 * here; over its body the page is transparent (the app's layer). A lower window is masked where a higher window is
 * (the app's pixels are under home's buffer, so DOM there would paint over that app, or show through its bar's glass).
 */
function WebWindowEl({ win, z, above }: { win: WebWin; z: number; above: WebWin[] }) {
  const body = useRef<HTMLDivElement>(null);
  const pinch = usePinch(win);
  // SC1: a pinch's scale zooms the whole frame (bar and body); the app keeps its size (sizeOf sends the layout size).
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
    ...holes(above, { x: win.x, y: win.y, s }),
  } as const;
  const free = !win.restore && tiledOn(win.id) == null;
  const focused = !above.length;
  const sizing = resizeView.value?.id === win.id;
  const cls = frameClass(win, focused, sizing);
  return (
    <>
      <WindowShadow win={win} z={z} above={above} focused={focused} />
      <div class={cls} data-wwid={win.id} data-z={z} style={{ ...frame, "--ww-k": s }} {...pinch}>
        {(!win.ownFrame || orphaned(win.id)) && <TitleBar win={win} />}
        <Body win={win} body={body} />
        {free && <Handles id={win.id} zones={zoneKey(win)} />}
        {sizing && <ResizeOutline win={win} />}
        {tileMenu.value === win.id && <TileMenu win={win} />}
      </div>
    </>
  );
}

/** The frame element's classes: maximised, live, focused (the top window: its grips, RZ1), being resized. */
function frameClass(win: WebWin, focused: boolean, sizing: boolean): string {
  const on: [boolean, string][] = [[!!win.restore, "maximised"], [!!win.live, "live"], [focused, "focused"], [sizing, "ww-resizing"], [gripsOn.value === win.id, "ww-grips"], [reflowing.value === win.page, "ww-reflow"]];
  return ["webwindow", ...on.filter(([b]) => b).map(([, c]) => c)].join(" ");
}

/** A window's whole frame (bar and body) in its page's px (the model; scaled about its top left). */
export function frameBox(w: WebWin): Box {
  const s = w.scale ?? 1;
  return { x: w.x, y: w.y, w: w.w * s, h: w.h * s };
}

/**
 * A CSS mask that leaves out [cut] (whole windows: the body is the app's layer, and the bar's glass must show what is
 * UNDER home's surface - the wallpaper, a lower app - blurred, never the page's own widget pixels) from an element at [at] in the page (page px; [at].s: the element's
 * own scale, the mask is in its unscaled box): the whole box minus each body. Undefined: nothing to cut.
 */
export function holes(cut: WebWin[], at: { x: number; y: number; s: number }): Record<string, string> | undefined {
  if (!cut.length) return undefined;
  const full = "linear-gradient(black, black)";
  const boxes = cut.map(frameBox).map((b) => ({ x: (b.x - at.x) / at.s, y: (b.y - at.y) / at.s, w: b.w / at.s, h: b.h / at.s }));
  return {
    maskImage: [full, ...boxes.map(() => full)].join(", "),
    maskSize: ["100% 100%", ...boxes.map((b) => `${px(b.w)}px ${px(b.h)}px`)].join(", "),
    maskPosition: ["0 0", ...boxes.map((b) => `${px(b.x)}px ${px(b.y)}px`)].join(", "),
    maskRepeat: "no-repeat",
    maskComposite: ["subtract", ...boxes.map(() => "add")].join(", "),
  };
}

/** The page's own content (widgets, apps, its glass) masked where its windows are: grid.tsx's .page-under. */
export function underWindows(page: number): Record<string, string> | undefined {
  return holes(
    webWins.value.filter((w) => w.page === page && !w.minimised && !w.full && !hiddenTab(w.id)),
    { x: 0, y: 0, s: 1 },
  );
}

/**
 * For the compositor's glass (nativeglass.ts): the windows (bar and body) on screen (viewport CSS px, l t r b) above a
 * surface in [el] (a window's own bar: the windows above that one; page content: every window on its page; anything
 * outside the pages: none). A surface one of them overlaps is blurred on the host's layer under the windows.
 */
export function bodiesOver(el: Element): Clip[] {
  const page = el.closest(".page");
  if (!page) return [];
  const own = el.closest<HTMLElement>(".webwindow[data-wwid]");
  const z = own ? Number(own.dataset.z) : -1;
  const out: Clip[] = [];
  for (const w of page.querySelectorAll<HTMLElement>(".webwindow[data-wwid]")) {
    if (Number(w.dataset.z) <= z) continue;
    const b = w.getBoundingClientRect();
    out.push([b.left, b.top, b.right, b.bottom]);
  }
  return out;
}
// To the glass (nativeglass.ts reads it; an import either way would close a module cycle through apps/native.ts).
(globalThis as { __wwCutouts?: typeof bodiesOver }).__wwCutouts = bodiesOver;
