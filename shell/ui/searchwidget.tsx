/**
 * The search pill as a home widget (a "panel" home item, "search": moved and resized like any other in edit mode, its
 * width the cells it spans). By default the pill sits in home's foot, above the dock; put on the grid it leaves the
 * foot. In the foot it can sit above the dock or below it (footBelow, swapped from the edit bar). On the grid the foot's
 * pill stays the drawer's search (home.tsx .search-parked): the tile opens the drawer, the foot's pill types. Never
 * removed: put back (its button, a drop on the bar's slot or the dock) it's the foot's again. Edit mode leaves the foot's
 * pill as it is - same size, width, glass and place, the edit bar below it (the user, 2026-10-30: "The search bar turns
 * weird"); it no longer turns into a grid tile there. It goes on the grid from the widget picker.
 */
import { signal } from "@preact/signals";
import { byKey, carry, dock, dockAim, dockMode, dockPosition, home, searchInDock, searchPlacement, searchSpot, selected, stored, type Carry } from "../state.ts";
import type { Cell, HomeItem } from "../types.ts";
import { wideHome } from "../hosts/wide.ts";
import { powos } from "../bridge.ts";
import { Bar } from "./bar.tsx";

/** The search widget on this screen's grid (not where this screen has the search docked: dockSearch). */
export const hasSearchWidget = () => !searchInDock.value && onHome();
/** The search widget is a home item (either screen's: the host keeps one layout). */
const onHome = () => home.value.items.some((i) => i.key === SEARCH_KEY);

/** The search widget's key on home (the host's "panel:<name>"). */
export const SEARCH_KEY = "panel:search";

/** A tile moved or resized: placed as it is. */
export function placeItem(key: string, cell: Cell, page: number): Promise<unknown> {
  return powos.home.place(key, cell, page);
}

/**
 * Back in the bar (the tile's "put back in bar", a drop on the bar's slot): the search widget leaves home and the pill
 * is the foot's again. Never removed otherwise - the foot is where it goes when home has none, so it can't be lost.
 */
export function putBackInBar(): Promise<unknown> {
  navigator.vibrate?.(10);
  if (!onHome()) return Promise.resolve();
  return powos.home.remove(SEARCH_KEY);
}

/** Sets this mode's search spot (state.ts searchSpot), logged as the old edit-sheet pick was: only edit mode's drag writes it. */
function setSpot(v: "dock" | "bar", how: string) {
  const place = searchPlacement.value;
  if (!place || place.value === v) return;
  console.info(`[powos] search placement (${dockMode.value}): ${place.value} -> ${v}, ${how}`);
  place.value = v;
}

/**
 * The search widget let go on the dock: docked - the round button between the pinned apps and the recent ones
 * (docksearch.tsx).
 */
export function dockSearch(): Promise<unknown> {
  setSpot("dock", "dragged onto the dock");
  // One home item for both screens (the host keeps one layout): the other screen's widget stays, hidden on this one
  // (grid.tsx itemsOn), until both are docked.
  return otherSpot() === "dock" ? putBackInBar() : Promise.resolve();
}

/** The search spot of the screen not in use (folded / unfolded). */
const otherSpot = () => (dockMode.value === "unfolded" ? searchSpot.mobile : searchSpot.unfolded).value;

/** The dock's button (or the foot's pill) let go on home's grid at [cell] of [page]: the bar widget there. */
export function undockSearch(page: number, cell: Cell): Promise<unknown> {
  setSpot("bar", "dragged onto home");
  return onHome() ? placeItem(SEARCH_KEY, cell, page) : powos.home.addPanel("search", page, cell);
}

/** The search as a home item to carry (grid.tsx startCarry): the grid's widget, or the foot's pill / the dock's button. */
export function searchItem(): HomeItem {
  const own = home.value.items.find((i) => i.key === SEARCH_KEY);
  // Not on the grid yet: a full-width row, as the widget picker adds it (editsheet.tsx fullRow).
  const cell = { x: 0, y: 0, w: home.value.columns, h: 1 };
  return own?.cell ? own : { key: SEARCH_KEY, kind: "panel", name: "search", page: 1, cell, resizable: true, minSize: [2, 1], size: null };
}

/** The search is being carried (its button leaves the dock, its pill the foot, while it is). */
export const carryingSearch = () => carry.value?.item?.key === SEARCH_KEY;

/**
 * The dock making room for the carried search widget (dockdrop.ts hoverDock reads it): a gap where the button would go,
 * the dock's separator (dockdrop.ts buttonSlot). Null when it's not the search or not over the dock.
 */
export function aimSearch(c: Carry, x: number, y: number) {
  if (c.item?.key !== SEARCH_KEY || footAimAt(SEARCH_KEY, x, y) !== "dock") return null;
  const n = dock.value.filter((k) => byKey.value.has(k)).length;
  return { key: SEARCH_KEY, slot: dockPosition.value !== "bottom" ? n : Math.floor((n + 1) / 2), swap: false };
}

/** [el]'s box grown by [reach] px on every side contains [x], [y]. */
const near = (el: Element | null, x: number, y: number, reach: number) => {
  const r = el?.getBoundingClientRect();
  return !!r?.width && y >= r.top - reach && y <= r.bottom + reach && x >= r.left - reach && x <= r.right + reach;
};
/** How far around the foot's places a carried search widget already counts as over them. */
const REACH = 24;

/**
 * Where the search widget carried to [x], [y] would go: "dock" (on the dock: docked as its button - the user,
 * 2026-10-31 15:34), "bar" (the bar's slot - in edit mode the edit sheet holds it: folded the pill's row, wide the one
 * bar's middle), "below" (under a bottom dock, folded: the pill under the dock - the user, 2026-10-23), or null (home's
 * grid).
 */
export function footAimAt(key: string | undefined, x: number, y: number): "dock" | "bar" | "below" | null {
  if (key !== SEARCH_KEY) return null;
  // On the dock itself first: in edit mode the edit sheet sits just under the dock (shell.css), so its reach would
  // otherwise take a drop on the dock's lower half.
  const dockEl = document.querySelector(".home > .dock:not(.dock-tray)");
  const bottom = dockPosition.value === "bottom";
  if (near(dockEl, x, y, bottom ? 0 : REACH / 2)) return "dock";
  if (near(document.querySelector(".home > .edit-sheet"), x, y, REACH)) return "bar";
  return bottom ? byBottomDock(dockEl?.getBoundingClientRect(), y) : null;
}

/** Off a bottom dock at [r], [y] down: under it the pill below it (wide: the bar's), just over it the dock. */
function byBottomDock(r: DOMRect | undefined, y: number) {
  if (!r?.width) return null;
  if (y > r.bottom) return wideHome.value ? "bar" : "below";
  return y >= r.top - REACH / 2 ? "dock" : null;
}

/** The search widget hovering over the foot (editsheet.tsx and the dock light up as the drop target). */
export const footAim = signal<"dock" | "bar" | "below" | null>(null);

/** Follows a carried tile (grid.tsx startCarry): lights up the foot when it's the search widget over it. */
export function hoverFoot(c: Carry | null, x: number, y: number) {
  const a = footAimAt(c?.item?.key, x, y);
  if (a !== footAim.value) {
    if (a) navigator.vibrate?.(5);
    footAim.value = a;
  }
}

/**
 * [c] let go at [ev]: the search widget over the dock docks (its button), over the foot it goes back there (over or
 * under the dock). True: handled.
 */
export function dropSearchOnFoot(c: Carry | null, ev: PointerEvent): boolean {
  footAim.value = null;
  const a = ev.type === "pointerup" ? footAimAt(c?.item?.key, ev.clientX, ev.clientY) : null;
  if (!a) return false;
  dockAim.value = null;
  carry.value = null;
  selected.value = null;
  navigator.vibrate?.(10);
  if (a === "dock") return void dockSearch(), true;
  footBelow.value = a === "below" ? "1" : "";
  setSpot("bar", "dragged onto the foot");
  void putBackInBar();
  return true;
}

/** Home's classes for the search widget (shell.css): on the grid (the foot's pill parked), carried under the dock. */
export const searchClasses = () => `${hasSearchWidget() ? "search-parked" : ""} ${footAim.value === "below" ? "search-below-aim" : ""} ${carryingSearch() ? "search-carried" : ""}`;

/** In the foot: the pill under the dock ("1"), else over it. */
export const footBelow = stored("search.belowDock", "");

/**
 * The widget's face: the pill, centred in its cells - no tile of its own (the pill is the surface). Its face only (the
 * user, 2026-10-23: as a widget it "no longer works with the pull-up launcher"): a tap or a pull up opens the drawer as
 * the foot's pill does, and the foot's pill (home.tsx, parked) comes up with it to type in - one field, one drawer.
 */
export function SearchPanel() {
  return (
    <div class="search-face">
      <Bar proxy />
    </div>
  );
}
