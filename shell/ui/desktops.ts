/**
 * Home's pages as desktops (unfolded home, the user's design 2026-10-22): every floating app window belongs to a home
 * page, like a widget - the page on screen when it opened. Swiping pages switches desktops: that page's windows show,
 * the others leave the screen (the host minimises them, the task keeps running: WindowFrames.desktop). A window
 * brought back from the dock or the drawer ("windows.raised") moves to the page on screen; one let go at the screen's side
 * ("windows.edge") moves to the page that way, and home goes with it. Folded, apps are full screen
 * and the host lists no windows: nothing here acts.
 *
 * Kept in the store ("home.windows": task id -> page id, next to the dock's pins), so a reload of the page (an update,
 * a hot reload) puts each window back on its page. Page ids are the layout's (Home.pages; -1 is PowOS AI's page).
 */
import { batch, effect, signal, untracked } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { AppWindow } from "../types.ts";
import { byKey, desktopPages, launch, page, pages, windows } from "../state.ts";
import { pageDrag } from "./gesture.ts";

const STORE = "home.windows";
/** Window ids kept for closed tasks at most (folded, the list is empty but the windows aren't gone). */
const KEEP = 48;

/** Task id -> the page id it lives on. */
export const placed = signal<Record<number, number>>({});
let loaded = false;
/** The hide list the host has; null: tell it whatever it is (it may still hide windows of an earlier page). */
let sent: string | null = null;

/** The app library's desktop (the page after the last, ui/library.tsx): a page of its own, not page 1's. */
const LIBRARY = -2;

/** The page id on screen: the layout's id for the index, -1 for PowOS AI's page, LIBRARY for the app library. */
export function pageId(): number {
  if (page.value < 0) return -1;
  if (page.value >= pages.value.length) return LIBRARY;
  return pages.value[page.value] ?? pages.value[0] ?? 1;
}

/** The page index showing page id [id], or null when that page is gone. */
function indexOf(id: number): number | null {
  if (id === -1) return -1;
  if (id === LIBRARY) return pages.value.length;
  const i = pages.value.indexOf(id);
  return i < 0 ? null : i;
}

function save(next: Record<number, number>) {
  const ids = Object.keys(next);
  const live = new Set(windows.value.map((w) => String(w.id)));
  // Closed tasks' ids go first when there are too many (ids grow, so the oldest are the smallest).
  for (const id of ids.filter((k) => !live.has(k)).slice(0, Math.max(0, ids.length - KEEP))) delete next[Number(id)];
  placed.value = next;
  powos.store.set(STORE, next).catch(() => {});
}

/** New windows onto the page on screen; a window whose page is gone, too. */
function place(list: AppWindow[]) {
  const cur = pageId();
  const next = { ...placed.value };
  let changed = false;
  for (const w of list) {
    const p = next[w.id];
    if (p !== undefined && indexOf(p) !== null) continue;
    next[w.id] = cur;
    changed = true;
  }
  if (changed) save(next);
}

/** Moves window [id] onto page id [to] (a drop on the screen's edge: the next page). */
export function moveTo(id: number, to: number) {
  save({ ...placed.value, [id]: to });
}

/**
 * Window [id] let go at the screen's [side] edge (-1 left, 1 right): onto the page that way, home there too - in one
 * step, so it never counts as another page's window (hidden) in between. No page that way: it stays.
 */
export function toEdge(id: number, side: number) {
  const next = page.value + Math.sign(side);
  if (page.value < 0 || next < 0 || next >= pages.value.length) return;
  batch(() => {
    moveTo(id, pages.value[next]);
    page.value = next;
  });
}

/** The windows of the other pages: out of sight. Sent only when it changes. */
function hidden(): number[] {
  const cur = pageId();
  return windows.value.filter((w) => (placed.value[w.id] ?? cur) !== cur).map((w) => w.id).sort((a, b) => a - b);
}

/**
 * Windows slide with their page (the user, 2026-10-23/24: they stayed put and popped at the end): a page swipe hands
 * the host the windows of the page on screen and of its neighbours, the track's offset at each move and its settle;
 * the host moves their surfaces frame by frame (PageSlide.kt) and commits the desktop change (hidden()) once the
 * page has landed - never in the middle of the settle, where the minimise/raise work made it stutter.
 */
let slide: "off" | "on" = "off";
/** The page the slide started on. */
let slideFrom = 0;

function slideFollow(dx: number | null) {
  const f = powos.floating;
  if (!f?.slide) return;
  if (dx == null) {
    // The finger let go: settlePages sets the page right after the drag ends; read it once both are in.
    // Its time now: the track's settle starts in this frame, and the host runs its curve from then (PageSlide.settle).
    const at = Date.now();
    if (slide === "on") queueMicrotask(() => slideSettle(at));
    return;
  }
  // t: when the track was there (the host logs how late each move came - the windows' lag behind the page).
  if (slide === "on") return void f.slide("move", { x: dx, t: Date.now() }).catch(() => {});
  slideStart(dx);
}

/** The windows that ride the swipe: window id -> its page offset from the page on screen (-1, 0, 1). */
function slideRels(cur: number): Record<number, number> {
  const rels: Record<number, number> = {};
  for (const w of windows.value) {
    const i = indexOf(placed.value[w.id] ?? pageId());
    if (w.minimised || i === null || Math.abs(i - cur) > 1 || (i === cur && w.away)) continue;
    rels[w.id] = i - cur;
  }
  return rels;
}

function pagesWidth() {
  return document.querySelector(".pages")?.clientWidth || innerWidth;
}

function slideStart(dx: number) {
  const cur = page.value;
  const rels = slideRels(cur);
  if (!Object.keys(rels).length) return;
  slide = "on";
  slideFrom = cur;
  powos.floating?.slide?.("start", { rels, width: pagesWidth(), x: dx }).catch(() => false).then((ok) => {
    if (!ok && slide === "on" && pageDrag.peek() != null) slide = "off";
  });
}

/** The track's CSS transition (duration ms, cubic-bezier points), read so the host runs the same curve. */
function trackCurve(): { ms: number; curve?: number[] } {
  const track = document.querySelector<HTMLElement>(".page-track");
  if (!track) return { ms: 280 };
  const cs = getComputedStyle(track);
  const d = cs.transitionDuration;
  const ms = parseFloat(d) * (d.endsWith("ms") ? 1 : 1000) || 280;
  return { ms, curve: cs.transitionTimingFunction.match(/cubic-bezier\(([^)]+)\)/)?.[1].split(",").map(Number) };
}

/** The track's settle and the desktop change after it. */
function slideSettle(at: number) {
  slide = "off";
  const { ms, curve } = trackCurve();
  const hide = hidden();
  sent = hide.join();
  powos.floating?.slide?.("settle", { to: (slideFrom - page.value) * pagesWidth(), ms, curve, hide, at }).catch(() => {
    // An app without the slide: the change as before, once the page has landed.
    setTimeout(() => powos.floating?.desktop(hide).catch(() => (sent = null)), ms);
  });
}

/** Home's page only (app.tsx, after load(): the layout's pages must be known before a window's page is judged gone). */
export async function startDesktops() {
  const kept = await powos.store.get<Record<number, number>>(STORE).catch(() => null);
  if (kept && typeof kept === "object") placed.value = { ...kept, ...placed.value };
  loaded = true;
  effect(() => {
    const list = windows.value;
    if (powos.floating) place(list);
  });
  // The pages live windows are on stay pages of home (state.ts pages): unfolded, a desktop needs no tiles.
  effect(() => {
    const ids = [...new Set(windows.value.map((w) => placed.value[w.id]).filter((p) => p > 0))].sort((a, b) => a - b);
    if (ids.join() !== desktopPages.peek().join()) desktopPages.value = ids;
  });
  effect(() => {
    const hide = hidden();
    const key = hide.join();
    // No windows listed (folded, or none open): told again once they're back, as Android may have raised them.
    if (!windows.value.length) sent = null;
    // A page slide commits the change itself, once it has landed (slideSettle).
    if (key === sent || !powos.floating || slide !== "off") return;
    sent = key;
    powos.floating.desktop(hide).catch(() => (sent = null));
  });
  effect(() => {
    const dx = pageDrag.value;
    untracked(() => slideFollow(dx));
  });
  powos.on("windows.edge", (d: { id: number; side: number }) => toEdge(d.id, d.side));
  // Read from the page, never assumed: the bottom bar's layout is home's (one wide bar unfolded, pill + dock folded).
  tellBar();
  addEventListener("resize", () => requestAnimationFrame(tellBar));
  const sized = new ResizeObserver(() => tellBar());
  for (const el of document.querySelectorAll(".home, .home > .bar, .home > .dock, .home > .bottom-bar")) sized.observe(el);
  // Brought back from another page (its app opened, a dock tap): it moves to the page on screen - the user's page
  // stays put, the window comes to them (the simpler of "move it" / "ask", 2026-10-23).
  powos.on("windows.raised", (id: number) => {
    if (placed.value[id] !== pageId()) moveTo(id, pageId());
  });
}

/**
 * A tap on an app in the dock, taskbar style (the user, 2026-10-22): its window open and in front (the top-most one
 * showing) goes into the dock (minimised); minimised, on another page or under another window, it comes back in front
 * (the host restores rather than launches: ShellBridge.launch, then "windows.raised"); no window, the app launches.
 * A PowOS (Linux) app's window floats as its own task too (WindowTasks): the same rule, by its app key (appOf).
 * Linux windows still on the Plasma desktop: HOOK - the same rule once the Plasma backend lists them to the web
 * launcher (planned in docs/DESKTOP-WEB-SHELL.md; Runtime.launch brings a running one to the front meanwhile).
 */
export async function dockTap(key: string) {
  // The top-most one SHOWING: a listed task that isn't visible (no bounds - e.g. a translucent PowOS task left in
  // freeform, seen 2026-10-23) is no one's front, or a tap on Chrome in front launched instead of minimising (e2e r3).
  // PowOS's own non-Linux tasks (no app key: a translucent host left in freeform) are no one's front either - likely why
  // a dock tap on Chrome in front launched it again (e2e 1023-1807: minimised=false); dock-taskbar.sh measures it.
  const front = windows.value.find((w) => !w.minimised && !w.away && !!w.bounds && (!!w.app || w.pkg !== "com.powos.app"));
  if (front && isOf(front, key) && powos.floating?.minimise) {
    const done = await powos.floating.minimise(front.id).catch(() => false);
    if (done) return;
  }
  await launch(key);
}

/** Whether window [w] is app [key]'s: a PowOS (Linux) app's by its key, an Android app's by its package. */
function isOf(w: AppWindow, key: string): boolean {
  if (w.app) return w.app === key;
  return key.startsWith("a:") && key.slice(2).split("/")[0] === w.pkg;
}

/** The app key window [w] is of: a PowOS (Linux) app's own ("l:...", the host says), else its Android package's. */
export function appOf(w: AppWindow): string | undefined {
  return w.app ?? [...byKey.value.keys()].find((k) => k.startsWith(`a:${w.pkg}/`));
}

/** Whether CSS point ([x], [y]) on home is inside a floating window showing now (its bounds are device px). */
export function inWindow(x: number, y: number): boolean {
  const px = x * devicePixelRatio;
  const py = y * devicePixelRatio;
  return windows.value.some((w) => !w.minimised && !w.away && !!w.bounds && px >= w.bounds[0] && px < w.bounds[2] && py >= w.bounds[1] && py < w.bounds[3]);
}

/** The top of home's bottom bar (search pill, dock): the lowest edge a window may reach, told the host on change. */
export function barTop(): number | null {
  let top = Infinity;
  for (const el of document.querySelectorAll<HTMLElement>(".home > .bar, .home > .dock, .home > .bottom-bar")) {
    if (el.matches(".dock-left > .dock, .dock-right > .dock")) continue;
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.top < top) top = r.top;
  }
  return top === Infinity ? null : Math.round(top);
}

let toldBar: number | null = null;
function tellBar() {
  const top = barTop();
  if (top === null || top === toldBar || !powos.floating?.area) return;
  toldBar = top;
  powos.floating.area(top).catch(() => (toldBar = null));
}

/** Ready once the kept placement is read (the gate waits on it). */
export const ready = () => loaded;
