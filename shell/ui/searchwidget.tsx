/**
 * The search pill as a home widget (a "panel" home item, "search": moved and resized like any other in edit mode, its
 * width the cells it spans). By default the pill sits in home's foot, above the dock; put on the grid it leaves the
 * foot. In the foot it can sit above the dock or below it (footBelow, swapped from the edit bar).
 */
import { home, stored } from "../state.ts";
import { Bar } from "./bar.tsx";

export const hasSearchWidget = () => home.value.items.some((i) => i.kind === "panel" && i.name === "search");

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
