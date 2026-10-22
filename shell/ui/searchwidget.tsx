/**
 * The search pill as a home widget (a "panel" home item, "search": moved and resized like any other in edit mode, its
 * width the cells it spans). By default the pill sits in home's foot, above the dock; put on the grid it leaves the
 * foot. In the foot it can sit above the dock or below it (footBelow, swapped from the edit bar).
 */
import { computed } from "@preact/signals";
import { editing, home, page, pages, stored } from "../state.ts";
import type { Cell, HomeItem } from "../types.ts";
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
  if (!editing.value || hasSearchWidget()) return null;
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

/** In the foot: the pill under the dock ("1"), else over it. */
export const footBelow = stored("search.belowDock", "");

/** The widget's face: the pill, centred in its cells - no tile of its own (the pill is the surface). */
export function SearchPanel() {
  return (
    <div class="search-face">
      <Bar />
    </div>
  );
}
