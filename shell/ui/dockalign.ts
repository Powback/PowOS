/**
 * Where a side dock's apps sit along its column (the user, 2026-11-23: "when the dock is pinned to the side, we should
 * have an option to make it bottom aligned so the docked ones are on the bottom and on top are the recent ... I cant
 * really reach my docked icons easily cause they are so far up"). Settings > style > home > "side dock alignment".
 *
 * "bottom" (the default): the pinned apps anchored to the column's foot, within thumb reach; the recent apps stacked
 * above them, the newest nearest the pinned ones, growing upward - only the recents scroll, the pinned never leave the
 * screen (shell.css .home.dock-end). "top": the pinned apps first from the top, the recents under them, the whole
 * column scrolling (as before). A bottom (horizontal) dock has no alignment. Pure: state.ts and dockdrop.ts read it,
 * shell/test/dockalign.test.ts tests it.
 */
export type DockAlign = "top" | "bottom";
export const DOCK_ALIGNS: readonly DockAlign[] = ["top", "bottom"];

/** [value] if it names an alignment, else [fallback] ("bottom": thumb reach). */
export function validDockAlign(value: string, fallback: DockAlign = "bottom"): DockAlign {
  return (DOCK_ALIGNS as readonly string[]).includes(value) ? (value as DockAlign) : fallback;
}

/** A side dock (left/right) aligned to the bottom: its pinned apps at the foot, recents above. */
export function dockAtEnd(position: string, align: string): boolean {
  return position !== "bottom" && validDockAlign(align) === "bottom";
}

/**
 * The search button's index among [cells] pinned cells (docksearch.tsx): it is the separator between the pinned apps
 * and the recent ones. A bottom dock: its middle (an odd extra app on the right). A side column aligned to the top: the
 * pinned group's end (the recents follow below); aligned to the bottom: its start (the recents are above).
 */
export function searchButtonIndex(position: string, align: string, cells: number): number {
  if (position === "bottom") return Math.floor(cells / 2);
  return dockAtEnd(position, align) ? 0 : cells;
}

/** The slot a carried search widget's gap opens at among [n] pinned apps: where its button would go. */
export function searchGapSlot(position: string, align: string, n: number): number {
  if (position === "bottom") return Math.floor((n + 1) / 2);
  return dockAtEnd(position, align) ? 0 : n;
}

/** The pinned home page's class words for [position] and [align]: "dock-<side>", plus "dock-end" when bottom-aligned. */
export function dockClasses(position: string, align: string): string {
  return dockAtEnd(position, align) ? `dock-${position} dock-end` : `dock-${position}`;
}
