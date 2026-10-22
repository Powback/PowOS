/**
 * Home's pages as desktops (unfolded home, the user's design 2026-10-22): every floating app window belongs to a home
 * page, like a widget - the page on screen when it opened. Swiping pages switches desktops: that page's windows show,
 * the others leave the screen (the host minimises them, the task keeps running: WindowFrames.desktop). A window
 * brought back from the dock or the drawer ("windows.raised") takes home to its page; one let go at the screen's side
 * ("windows.edge") moves to the page that way, and home goes with it. Folded, apps are full screen
 * and the host lists no windows: nothing here acts.
 *
 * Kept in the store ("home.windows": task id -> page id, next to the dock's pins), so a reload of the page (an update,
 * a hot reload) puts each window back on its page. Page ids are the layout's (Home.pages; -1 is PowOS AI's page).
 */
import { batch, effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { AppWindow } from "../types.ts";
import { launch, page, pages, windows } from "../state.ts";

const STORE = "home.windows";
/** Window ids kept for closed tasks at most (folded, the list is empty but the windows aren't gone). */
const KEEP = 48;

/** Task id -> the page id it lives on. */
export const placed = signal<Record<number, number>>({});
let loaded = false;
/** The hide list the host has; null: tell it whatever it is (it may still hide windows of an earlier page). */
let sent: string | null = null;

/** The page id on screen: the layout's id for the index, -1 for PowOS AI's page. */
export function pageId(): number {
  return page.value < 0 ? -1 : (pages.value[page.value] ?? pages.value[0] ?? 1);
}

/** The page index showing page id [id], or null when that page is gone. */
function indexOf(id: number): number | null {
  if (id === -1) return -1;
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

/** Home's page only (app.tsx, after load(): the layout's pages must be known before a window's page is judged gone). */
export async function startDesktops() {
  const kept = await powos.store.get<Record<number, number>>(STORE).catch(() => null);
  if (kept && typeof kept === "object") placed.value = { ...kept, ...placed.value };
  loaded = true;
  effect(() => {
    const list = windows.value;
    if (powos.floating) place(list);
  });
  effect(() => {
    const hide = hidden();
    const key = hide.join();
    // No windows listed (folded, or none open): told again once they're back, as Android may have raised them.
    if (!windows.value.length) sent = null;
    if (key === sent || !powos.floating) return;
    sent = key;
    powos.floating.desktop(hide).catch(() => (sent = null));
  });
  powos.on("windows.edge", (d: { id: number; side: number }) => toEdge(d.id, d.side));
  // Read from the page, never assumed: the bottom bar's layout is home's (one wide bar unfolded, pill + dock folded).
  tellBar();
  addEventListener("resize", () => requestAnimationFrame(tellBar));
  const sized = new ResizeObserver(() => tellBar());
  for (const el of document.querySelectorAll(".home, .home > .bar, .home > .dock, .home > .bottom-bar")) sized.observe(el);
  powos.on("windows.raised", (id: number) => {
    const p = placed.value[id];
    const i = p === undefined ? null : indexOf(p);
    if (i === null) return moveTo(id, pageId());
    if (i !== page.value) page.value = i;
  });
}

/**
 * A tap on an app in the dock, taskbar style (the user, 2026-10-22): its window open and in front (the top-most one
 * showing) goes into the dock (minimised); minimised, on another page or under another window, it comes back in front
 * (the host restores rather than launches: ShellBridge.launch, then "windows.raised"); no window, the app launches.
 * Linux (KWin) windows: HOOK - the same rule once the Plasma backend lists them to the web launcher (planned in
 * docs/DESKTOP-WEB-SHELL.md; Runtime.launch brings a running one to the front meanwhile).
 */
export async function dockTap(key: string) {
  const pkg = key.startsWith("a:") ? key.slice(2).split("/")[0] : null;
  const front = windows.value.find((w) => !w.minimised && !w.away);
  if (pkg && front?.pkg === pkg && powos.floating?.minimise) {
    const done = await powos.floating.minimise(front.id).catch(() => false);
    if (done) return;
  }
  await launch(key);
}

/** The top of home's bottom bar (search pill, dock): the lowest edge a window may reach, told the host on change. */
export function barTop(): number | null {
  let top = Infinity;
  for (const el of document.querySelectorAll<HTMLElement>(".home > .bar, .home > .dock, .home > .bottom-bar")) {
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
