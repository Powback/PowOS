/**
 * Dropping a carried app on the dock (grid.tsx startCarry): any app held and moved - from the drawer, its search, the
 * recent strip, home's grid, or out of the dock itself - pins where it's let go over the dock. While it hovers there
 * the dock makes room for it (home.tsx Dock reads [dockAim]); a full dock offers to swap the app under the finger.
 */
import { byKey, dock, dockPosition, dockAim, editing, homePage, searchInDock, selected, setDock, type Carry } from "../state.ts";
import { powos } from "../bridge.ts";
import { wideHome } from "../hosts/wide.ts";
import { aimSearch } from "./searchwidget.tsx";

/** The most apps the dock holds; a full one swaps instead of growing. */
export const DOCK_MAX = 6;
/** How far above the dock's top edge a carried app already counts as over it. */
const REACH = 16;

/** The app key a carried thing would pin: a drawer app's, or an app tile's on home (not a widget's or a folder's). */
export const carriedApp = (c: Carry | null) => (c ? (c.app ?? (c.item?.kind === "app" ? c.item.app : undefined)) : undefined);

/**
 * The dock's apps as it shows them, less [key]: pins of apps not installed (kept, so a reinstalled app comes back to
 * its place) aren't drawn, so they don't count for slots.
 */
export const shownLess = (key: string) => dock.value.filter((k) => k !== key && byKey.value.has(k));

/** The dock's element on screen (the ghost drop zone, when nothing is pinned yet). */
const dockEl = () => document.querySelector<HTMLElement>(".home .dock");

/** Where over the dock the finger at [x], [y] would put [c], or null when it's not over the dock. */
export function aimDock(c: Carry, x: number, y: number) {
  const key = carriedApp(c);
  const el = dockEl();
  if (!key || !el) return null;
  const r = el.getBoundingClientRect();
  const vertical = dockPosition.value !== "bottom";
  if (!overDock(r, x, y, vertical)) return null;
  const rest = shownLess(key);
  const full = rest.length >= DOCK_MAX && !dock.value.includes(key);
  // Inserting: one more slot than there are others (the gap counts); swapping: one of the others.
  const n = full ? rest.length : rest.length + 1;
  return { key, slot: slotAt(el, r, { x, y }, n), swap: full };
}

function overDock(r: DOMRect, x: number, y: number, vertical: boolean) {
  const reach = vertical ? REACH : 0;
  return r.width > 0 && y >= r.top - REACH && x >= r.left - reach && x <= r.right + reach && (!vertical || y <= r.bottom);
}

/**
 * The search button's index among [cells] dock cells (docksearch.tsx): a bottom dock's middle, an odd extra app on the
 * right; a side column's end - the button is the separator between its pinned apps and its recent ones (the user,
 * 2026-10-31 13:31), never also mid-column.
 */
export const buttonSlot = (cells: number) => (dockPosition.value !== "bottom" ? cells : Math.floor(cells / 2));

/** The app slot (of [n]) for the dock's rendered cell [cell], which counts the search button when it's there. */
export function slotPast(cell: number, n: number) {
  return homePage && searchInDock.value && cell > buttonSlot(n) ? cell - 1 : cell;
}

/** Which of [n] slots of the dock [el] (at [r]) [x] is over. */
function slotAt(el: HTMLElement, r: DOMRect, point: { x: number; y: number }, n: number) {
  const cells = n + (homePage && searchInDock.value ? 1 : 0);
  if (dockPosition.value !== "bottom") {
    const row = el.querySelector<HTMLElement>(".dock-page");
    const top = row?.getBoundingClientRect().top ?? r.top;
    return Math.max(0, Math.min(n - 1, slotPast(Math.floor((point.y - top) / 56), n)));
  }
  // Wide (one bar: home.tsx .home.wide), the pinned row is as long as its icons, not the dock's whole side.
  const row = wideHome.value ? el.querySelector<HTMLElement>(".dock-page")?.getBoundingClientRect() : null;
  const s = row?.width ? row : r;
  return Math.max(0, Math.min(n - 1, slotPast(Math.floor(((point.x - s.left) / s.width) * cells), n)));
}

/** Follows the finger: the dock makes room as it comes and goes, with a tick for each new slot. */
export function hoverDock(c: Carry, x: number, y: number) {
  // The search widget makes room too: a gap where its button would go (searchwidget.tsx; its drop is the foot's).
  const a = aimDock(c, x, y) ?? aimSearch(c, x, y);
  const was = dockAim.value;
  if (a?.slot !== was?.slot || a?.key !== was?.key) {
    if (a) navigator.vibrate?.(5);
    dockAim.value = a;
  }
}

/** Lets [c] go over the dock at [x], [y]: true when it was pinned there (the drop was the dock's). */
export function dropOnDock(c: Carry, x: number, y: number): boolean {
  const a = aimDock(c, x, y);
  dockAim.value = null;
  if (!a) return false;
  navigator.vibrate?.(10);
  const rest = shownLess(a.key);
  const hidden = dock.value.filter((k) => k !== a.key && !byKey.value.has(k));
  let out: string | undefined;
  if (a.swap) {
    out = rest[a.slot];
    rest[a.slot] = a.key;
  } else rest.splice(a.slot, 0, a.key);
  setDock([...rest, ...hidden]);
  // A home tile moved into the dock leaves home; the app it swapped out takes its place there.
  const item = c.item;
  // Picked up from home's grid it had home in edit mode, which hides the dock: out of it, so the dock shows its new app.
  if (item) {
    editing.value = false;
    selected.value = null;
  }
  if (item)
    void (async () => {
      await powos.home.remove(item.key);
      if (out && item.cell) await addHome(out, item.page, item.cell);
    })();
  return true;
}

/** Pins [app] on home at [cell] of [page]; false when the host can't (see the HACK). */
export async function addHome(app: string, page: number, cell?: { x: number; y: number; w: number; h: number }) {
  try {
    await powos.home.add(app, page, cell);
    return true;
  } catch {
    // HACK: the Android host's home (ShellHome.add) only knows a:/l: keys and refuses a PowOS app's p: key, so a
    // PowOS app dragged off the dock (or swapped out) is only unpinned, not put on home. Real fix: ShellHome.add
    // stores p: apps as shortcuts the page launches (openApp), as it does Android's and Linux's.
    return false;
  }
}

