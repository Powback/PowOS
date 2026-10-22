/**
 * Home's pages as desktops (unfolded home, the user's design 2026-10-22): every floating app window belongs to a home
 * page, like a widget - the page on screen when it opened. Swiping pages switches desktops: that page's windows show,
 * the others leave the screen (the host minimises them, the task keeps running: WindowFrames.desktop). A window
 * brought back from the dock or the drawer ("windows.raised") takes home to its page. Folded, apps are full screen
 * and the host lists no windows: nothing here acts.
 *
 * Kept in the store ("home.windows": task id -> page id, next to the dock's pins), so a reload of the page (an update,
 * a hot reload) puts each window back on its page. Page ids are the layout's (Home.pages; -1 is PowOS AI's page).
 */
import { effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { AppWindow } from "../types.ts";
import { page, pages, windows } from "../state.ts";

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
  powos.on("windows.raised", (id: number) => {
    const p = placed.value[id];
    const i = p === undefined ? null : indexOf(p);
    if (i === null) return moveTo(id, pageId());
    if (i !== page.value) page.value = i;
  });
}

/** Ready once the kept placement is read (the gate waits on it). */
export const ready = () => loaded;
