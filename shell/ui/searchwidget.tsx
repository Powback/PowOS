/**
 * The search pill as a home widget (a "panel" home item, "search": moved and resized like any other in edit mode, its
 * width the cells it spans). By default the pill sits in home's foot, above the dock; put on the grid it leaves the
 * foot. In the foot it can sit above the dock or below it (footBelow, swapped from the edit bar). On the grid the foot's
 * pill stays the drawer's search (home.tsx .search-parked): the tile opens the drawer, the foot's pill types. Never
 * removed: put back (its button, a drop on the bar's slot or the dock) it's the foot's again.
 */
import { computed, signal } from "@preact/signals";
import { carry, editing, home, page, pages, selected, stored, type Carry } from "../state.ts";
import type { Cell, HomeItem } from "../types.ts";
import { wideHome } from "../hosts/wide.ts";
import { powos } from "../bridge.ts";
import { Bar } from "./bar.tsx";
import { geometry } from "./grid.tsx";
import { recentsSpot } from "./recentwidget.tsx";

export const hasSearchWidget = () => home.value.items.some((i) => i.kind === "panel" && i.name === "search");

/** The search widget's key on home (the host's "panel:<name>"). */
export const SEARCH_KEY = "panel:search";

/**
 * In edit mode the foot's pill is on the grid too, a tile like the others (the user, 2026-10-22: in edit mode the
 * search bar is a widget, folded and unfolded): on the page on screen, in its lowest free row - the whole row folded,
 * the middle five columns wide. Moved or resized there (placeItem), it's put on home as the search widget and leaves
 * the foot; left where it is, "done" gives the pill back to the foot.
 */
export const footSearch = computed<HomeItem | null>(() => {
  // Folded under the dock (footBelow) the pill stays in the foot, under the dock, in edit mode too: the grid's lowest
  // free row is above the dock, so the tile there read as the pill jumping back on top (the user, 2026-10-28: "i put
  // the search bar under the dock and it moved back on top when in edit mode"). Over the dock it's the grid's tile.
  if (!editing.value || hasSearchWidget() || (footBelow.value && !wideHome.value)) return null;
  const n = pages.value[page.value] ?? 1;
  const spot = recentsSpot(n, geometry.value.rows || 6);
  if (!spot) return null;
  const cols = home.value.columns;
  const w = cols > 6 ? 5 : cols;
  const cell = { ...spot.cell, x: Math.floor((cols - w) / 2), w };
  return { key: SEARCH_KEY, kind: "panel", name: "search", page: n, cell, resizable: true, minSize: [2, 1], size: null };
});

/** The foot's pill shown on the grid in edit mode, not (yet) on home. */
export const isFootSearch = (key: string) => key === SEARCH_KEY && footSearch.value != null;

/** A tile moved or resized: the foot's pill becomes the search widget there; anything else is placed as it is. */
export function placeItem(key: string, cell: Cell, page: number): Promise<unknown> {
  if (isFootSearch(key)) return powos.home.addPanel("search", page, cell);
  return powos.home.place(key, cell, page);
}

/**
 * Back in the bar (the tile's "put back in bar", a drop on the bar's slot): the search widget leaves home and the pill
 * is the foot's again. Never removed otherwise - the foot is where it goes when home has none, so it can't be lost.
 */
export function putBackInBar(): Promise<unknown> {
  navigator.vibrate?.(10);
  if (!hasSearchWidget()) return Promise.resolve();
  return powos.home.remove(SEARCH_KEY);
}

/** [el]'s box grown by [reach] px on every side contains [x], [y]. */
const near = (el: Element | null, x: number, y: number, reach: number) => {
  const r = el?.getBoundingClientRect();
  return !!r?.width && y >= r.top - reach && y <= r.bottom + reach && x >= r.left - reach && x <= r.right + reach;
};
/** How far around the foot's places a carried search widget already counts as over them. */
const REACH = 24;

/**
 * Where in the foot the search widget carried to [x], [y] would go: "bar" (the bar's slot - in edit mode the edit sheet
 * holds it: folded the pill's row, wide the one bar's middle), "below" (the dock's row or under it, folded: the pill
 * under the dock - the user, 2026-10-23: "move the search bar down to the dock"), or null (home's grid).
 */
export function footAimAt(key: string | undefined, x: number, y: number): "bar" | "below" | null {
  if (key !== SEARCH_KEY) return null;
  // On the dock itself first: in edit mode the edit sheet sits just under the dock (shell.css), so its reach would
  // otherwise take a drop on the dock's lower half.
  if (!wideHome.value && near(document.querySelector(".home > .dock:not(.dock-tray)"), x, y, 0)) return "below";
  if (near(document.querySelector(".home > .edit-sheet"), x, y, REACH)) return "bar";
  const dock = document.querySelector(".home > .dock:not(.dock-tray)")?.getBoundingClientRect();
  if (!dock?.width) return null;
  if (y >= dock.top - REACH / 2) return wideHome.value ? "bar" : "below";
  return null;
}

/** The search widget hovering over the foot (editsheet.tsx and the dock light up as the drop target). */
export const footAim = signal<"bar" | "below" | null>(null);

/** Follows a carried tile (grid.tsx startCarry): lights up the foot when it's the search widget over it. */
export function hoverFoot(c: Carry | null, x: number, y: number) {
  const a = footAimAt(c?.item?.key, x, y);
  if (a !== footAim.value) {
    if (a) navigator.vibrate?.(5);
    footAim.value = a;
  }
}

/** [c] let go at [ev]: the search widget over the foot goes back there (over or under the dock). True: handled. */
export function dropSearchOnFoot(c: Carry | null, ev: PointerEvent): boolean {
  footAim.value = null;
  const a = ev.type === "pointerup" ? footAimAt(c?.item?.key, ev.clientX, ev.clientY) : null;
  if (!a) return false;
  carry.value = null;
  selected.value = null;
  footBelow.value = a === "below" ? "1" : "";
  void putBackInBar();
  return true;
}

/** Home's classes for the search widget (shell.css): on the grid (the foot's pill parked), carried under the dock. */
export const searchClasses = () => `${hasSearchWidget() ? "search-parked" : ""} ${footAim.value === "below" ? "search-below-aim" : ""}`;

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
