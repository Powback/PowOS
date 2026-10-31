/**
 * Docking into a grid of tiles, Golden Layout's way (the user, 10-31 01:28: "Currently able to like drag icons out of a
 * grid but I want to be able to like drag them into a grid again. Like check out how golden layout work"). GL1: while
 * something is dragged over the grid, the point under the finger picks a zone - a tile's outer quarter on a side (the
 * tile splits, the new one on that side), its centre (swap), or the whole grid's outer edge (a new full-height column
 * or full-width row) - and the caller's [landing] says what the grid would become, so the preview shows exactly where
 * it lands. Generic over boxes and split trees: web-window tiles (ui/webwindows.tsx) now, the native split overview
 * grid later. A tile's bar strip ([Grid.bar]) is a "tab" zone: the dragged window joins that tile's window as a tab
 * (WT1, [tabAt] for any window's bar, floating or tiled).
 */

export interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}
export type Side = "left" | "right" | "top" | "bottom";
/**
 * "split": tile [tile]'s [side] half (the tile splits in two there); "swap": tile [tile]'s centre; "outer": the grid's
 * [side] edge (tile -1); "tab": a bar's tab strip - [tile] is the tile (from [zoneAt]) or the window's id (from
 * [tabAt]), [at] the insert index among its tabs (-1: the end).
 */
export type Zone =
  | { kind: "split"; tile: number; side: Side }
  | { kind: "swap"; tile: number }
  | { kind: "outer"; tile: -1; side: Side }
  | { kind: "tab"; tile: number; at: number };

/** A tile's outer share on each side that splits it; the rest is its centre. */
export const EDGE_SHARE = 0.25;
/** The grid's own outer edge band (CSS px inside the area): a new full column / row. */
export const OUTER_PX = 40;

export interface Grid {
  tiles: Box[];
  area: Box;
  /** The outer edge band, px (default [OUTER_PX]). */
  outer?: number;
  /** Each tile's top strip (its bar), px: a "tab" zone there. */
  bar?: number;
  /** Each tile's tabs on its bar (the insert index of a "tab" zone); none: the zone's [at] is -1 (the end). */
  tabs?: Box[][];
}

const inside = (b: Box, x: number, y: number) => x >= b.x && x < b.x + b.w && y >= b.y && y < b.y + b.h;
const dist = (b: Box, x: number, y: number) => Math.hypot(Math.max(b.x - x, 0, x - b.x - b.w), Math.max(b.y - y, 0, y - b.y - b.h));

/** The side of [b] nearest (x, y), and how far in, px and as a share of [b]'s size across that side. */
function nearestSide(b: Box, x: number, y: number): { side: Side; px: number; share: number } {
  const all: [Side, number, number][] = [
    ["left", x - b.x, b.w],
    ["right", b.x + b.w - x, b.w],
    ["top", y - b.y, b.h],
    ["bottom", b.y + b.h - y, b.h],
  ];
  const [side, px, span] = all.reduce((m, v) => (v[1] / v[2] < m[1] / m[2] ? v : m));
  return { side, px, share: px / span };
}

/** The zone at (x, y) over [g]'s tiles (the grid in its area), or null: outside it or no tiles. */
export function zoneAt(x: number, y: number, g: Grid): Zone | null {
  const { tiles, area } = g;
  if (!tiles.length || !inside(area, x, y)) return null;
  const edge = nearestSide(area, x, y);
  if (edge.px <= (g.outer ?? OUTER_PX)) return { kind: "outer", tile: -1, side: edge.side };
  // In a gap between tiles: the nearest one (no flicker crossing a gap).
  const i = tiles.reduce((m, b, k) => (dist(b, x, y) < dist(tiles[m], x, y) ? k : m), 0);
  const b = tiles[i];
  if (g.bar && inside({ ...b, h: g.bar }, x, y)) return { kind: "tab", tile: i, at: g.tabs?.[i] ? insertAt(g.tabs[i], x) : -1 };
  const s = nearestSide(b, x, y);
  return s.share <= EDGE_SHARE ? { kind: "split", tile: i, side: s.side } : { kind: "swap", tile: i };
}

export const zoneKey = (z: Zone | null | undefined) => (z ? `${z.kind}:${z.tile}:${"side" in z ? z.side : "at" in z ? z.at : ""}` : "");

/** Where a tab dropped at [x] goes among [tabs] (left to right): before the first whose centre is right of it. */
export const insertAt = (tabs: Box[], x: number) => tabs.filter((t) => t.x + t.w / 2 < x).length;

/** A window under a dragged one: its whole [frame], its [bar] strip (none: it has no bar) and the tabs on that bar. */
export interface Bar {
  id: number;
  frame: Box;
  bar?: Box;
  tabs: Box[];
}

/**
 * WT1 (the user, 10-31 01:31: "grab the title bar of Dolphin and drag it into the title bar of Chrome, and then they can
 * share a title bar"): the "tab" zone at (x, y) over [bars] (bottom first: z order), or null - the top-most window under
 * the point decides, so a bar covered by another window's body is no target.
 */
export function tabAt(x: number, y: number, bars: Bar[]): Zone | null {
  for (let k = bars.length - 1; k >= 0; k--) {
    const b = bars[k];
    if (!inside(b.frame, x, y)) continue;
    return b.bar && inside(b.bar, x, y) ? { kind: "tab", tile: b.id, at: insertAt(b.tabs, x) } : null;
  }
  return null;
}

/** The zone at (x, y) and what it makes ([landing]: its rect in the re-flowed grid and the caller's own; null: nothing). */
export function dropAt<T extends { rect: Box }>(x: number, y: number, grid: Grid, landing: (z: Zone) => T | null): (T & { zone: Zone }) | null {
  const zone = zoneAt(x, y, grid);
  const got = zone && landing(zone);
  return zone && got ? { ...got, zone } : null;
}

// ---- split trees: a grid as nested two-way splits -----------------------------------------------------------------

/** A leaf (an id), or [axis] split at share [at] of the box into [a] (left / top) and [b]. */
export type Tree = number | { axis: "x" | "y"; at: number; a: Tree; b: Tree };

export const leaves = (t: Tree): number[] => (typeof t === "number" ? [t] : [...leaves(t.a), ...leaves(t.b)]);

/** Each leaf's rect in [box], [gap] px between siblings, in leaf order. */
export function treeRects(t: Tree, box: Box, gap: number): Map<number, Box> {
  const out = new Map<number, Box>();
  const walk = (n: Tree, b: Box) => {
    if (typeof n === "number") return void out.set(n, b);
    const [a, c] = splitBox(b, n.axis, n.at, gap);
    walk(n.a, a);
    walk(n.b, c);
  };
  walk(t, box);
  return out;
}

/** [b] split along [axis] at share [at], [gap] px between the two. */
export function splitBox(b: Box, axis: "x" | "y", at: number, gap: number): [Box, Box] {
  const g = gap / 2;
  if (axis === "x") {
    const s = b.x + b.w * at;
    return [{ ...b, w: s - g - b.x }, { ...b, x: s + g, w: b.x + b.w - s - g }];
  }
  const s = b.y + b.h * at;
  return [{ ...b, h: s - g - b.y }, { ...b, y: s + g, h: b.y + b.h - s - g }];
}

const axisOf = (s: Side) => (s === "left" || s === "right" ? "x" : "y");
const first = (s: Side) => s === "left" || s === "top";

/** [id] put on [side] of [n]: a split of the two halves. */
const beside = (n: Tree, id: number, side: Side): Tree => ({ axis: axisOf(side), at: 0.5, a: first(side) ? id : n, b: first(side) ? n : id });

/** [t] with [id] dropped at [zone] (its [target]: the zone's tile's leaf): split beside it, swapped in, or along the edge. */
export function dropInto(t: Tree, zone: Zone, target: number, id: number): Tree {
  if (zone.kind === "outer") return beside(t, id, zone.side);
  // A tab drop stacks onto the window (webwindows.tsx joinStack): the tiling itself doesn't change.
  if (zone.kind === "tab") return t;
  const map = (n: Tree): Tree => {
    if (typeof n !== "number") return { ...n, a: map(n.a), b: map(n.b) };
    if (n !== target) return n;
    return zone.kind === "swap" ? id : beside(n, id, zone.side);
  };
  return map(t);
}
