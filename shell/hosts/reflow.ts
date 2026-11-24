/**
 * ONE home layout on two screens (the user, 11-24: "changed the home layout unfolded to see more lights and widgets,
 * and it isn't reflected folded"). Pure functions - no DOM, no bridge - tested on their own (shell/test/reflow.test.ts);
 * hosts/flowsync.ts wires them to the host and the stores.
 *
 * The logical layout is what both screens share: the items, the host page each one is on, their order on that page
 * (reading order: row, then column) and their size in grid cells. Each screen is that layout laid out on its own grid:
 *   folded   - the host's pages, 6 columns (ShellHome.kt GRID_COLUMNS), as many rows as fit square cells;
 *   unfolded - one wide page of 13 columns per PAIR of host pages (hosts/wide.ts): the first page of the pair is the
 *              left half (columns 0-5), the second the right half (7-12). A tile there belongs to the half its middle
 *              is over (wide.ts toHost) - that is its page.
 * An edit on one screen (move, resize, add, remove) is laid out again on the other: same pages, same order, each item
 * at its old spot when that is still free and still in order, else the next free spot after the item before it, else
 * any free spot on its page, else the next page - never dropped. Wider than the other grid: as wide as it allows.
 *
 * Fine placement: an item the user placed by hand on a screen is PINNED there (flowsync.ts keeps the pins) - laid out
 * again from the other screen it keeps its spot while that spot is free; the item edited is never pinned on the other
 * screen (an edit always shows up on the other one).
 */
import type { Cell } from "../types.ts";

export interface Placed {
  key: string;
  page: number;
  cell: Cell;
}

/** A region of a page that one host page's items flow into: [x0] its first column, [cols] wide, [rows] deep. */
interface Region {
  page: number;
  x0: number;
  cols: number;
  rows: number;
}

/** One thing to place: an item, or a widget stack (its members all go where the anchor goes). */
interface Unit {
  key: string;
  w: number;
  h: number;
  /** Where it was, in the region's own columns (tried first). */
  pref: { x: number; y: number } | null;
  /** Pinned: its spot on the target screen (absolute cell), kept while free. */
  pin: Placed | null;
}

/** Rows a folded page holds when the page hasn't measured one yet (the cover: 404x899 CSS px, 6 columns). */
export const FOLDED_ROWS = 10;
/** The wide page's rows are not a limit here: a page that grows gets more, smaller rows (grid.tsx usedRows). */
const DEEP = 256;

/** The cells a page has taken. */
class Taken {
  private pages = new Map<number, Set<string>>();
  private on(page: number) {
    if (!this.pages.has(page)) this.pages.set(page, new Set());
    return this.pages.get(page)!;
  }
  free(page: number, c: Cell) {
    const s = this.on(page);
    for (let y = c.y; y < c.y + c.h; y++) for (let x = c.x; x < c.x + c.w; x++) if (s.has(`${x},${y}`)) return false;
    return true;
  }
  take(page: number, c: Cell) {
    const s = this.on(page);
    for (let y = c.y; y < c.y + c.h; y++) for (let x = c.x; x < c.x + c.w; x++) s.add(`${x},${y}`);
  }
}

/** Reading order: row, then column (top-left corner). */
export const byReading = (a: { cell: Cell }, b: { cell: Cell }) => a.cell.y - b.cell.y || a.cell.x - b.cell.x;

/** The first free spot at size w x h in [r], at reading index [from] or after (region columns), or null. */
function spotFrom(t: Taken, r: Region, size: { w: number; h: number }, from: number): Cell | null {
  const last = Math.min(r.rows, DEEP) - size.h;
  for (let i = Math.max(0, from); ; i++) {
    const y = Math.floor(i / r.cols), x = i % r.cols;
    if (y > last) return null;
    if (x + size.w > r.cols) continue;
    const c = { x: r.x0 + x, y, w: size.w, h: size.h };
    if (t.free(r.page, c)) return c;
  }
}

/** Its old spot, when that is free, inside the region and not before the item placed before it. */
function prefSpot(t: Taken, r: Region, u: Unit, from: number): Cell | null {
  if (!u.pref) return null;
  const w = Math.min(u.w, r.cols);
  const x = Math.max(0, Math.min(r.cols - w, u.pref.x));
  const c = { x: r.x0 + x, y: u.pref.y, w, h: u.h };
  if (u.pref.y * r.cols + x < from || c.y + c.h > Math.min(r.rows, DEEP)) return null;
  return t.free(r.page, c) ? c : null;
}

/** The pinned units on [r]'s page: placed first, where the user put them (while free and on the grid). */
function placePins(t: Taken, r: Region, units: Unit[], out: Map<string, Placed>) {
  for (const u of units) {
    const p = u.pin;
    if (!p || p.page !== r.page || out.has(u.key)) continue;
    const c = p.cell;
    if (c.x < r.x0 || c.x + c.w > r.x0 + r.cols || !t.free(r.page, c)) continue;
    t.take(r.page, c);
    out.set(u.key, { key: u.key, page: r.page, cell: c });
  }
}

/**
 * Flows [units] (in order) into region [r]: pins first (out of the order), then each other unit at its old spot (when
 * in order), the next free spot after the one before it, or any free spot on the region. Returns the units that didn't fit (for the next page).
 */
function flowRegion(t: Taken, r: Region, units: Unit[], out: Map<string, Placed>): Unit[] {
  placePins(t, r, units, out);
  const carry: Unit[] = [];
  let at = 0;
  for (const u of units) {
    // A pin is out of the flow: where the user put it says nothing about the order of the rest.
    if (out.has(u.key)) continue;
    const size = { w: Math.min(u.w, r.cols), h: u.h };
    const c = prefSpot(t, r, u, at) ?? spotFrom(t, r, size, at) ?? spotFrom(t, r, size, 0);
    if (!c) {
      carry.push(u);
      continue;
    }
    t.take(r.page, c);
    out.set(u.key, { key: u.key, page: r.page, cell: c });
    at = c.y * r.cols + (c.x - r.x0);
  }
  return carry;
}

/** Stack members follow their anchor: [follow] member key -> anchor key (only members other than the anchor). */
export type Follow = Record<string, string>;

/** Items that place themselves (not a member following an anchor that is there too). */
const leaders = (items: Placed[], follow: Follow) => {
  const keys = new Set(items.map((i) => i.key));
  return items.filter((i) => !(follow[i.key] && follow[i.key] !== i.key && keys.has(follow[i.key])));
};

/** Every member of [follow] gets its anchor's placement. */
function withFollowers(items: Placed[], follow: Follow, out: Map<string, Placed>): Placed[] {
  return items.flatMap((i) => {
    const own = out.get(i.key);
    if (own) return [own];
    const lead = out.get(follow[i.key]);
    return lead ? [{ key: i.key, page: lead.page, cell: lead.cell }] : [];
  });
}

/** The half of a wide page (13 columns over two 6-column host pages) a cell's middle is over: 0 left, 1 right. */
export const halfOf = (c: Cell, cols: number) => (c.x + c.w / 2 > cols + 0.5 ? 1 : 0);

export interface ToFolded {
  /** Items as the wide screen has them (page = the wide page, 1-based). */
  wide: Placed[];
  /** Wide page n (index n-1) -> the host pages it shows. */
  pairs: number[][];
  /** The folded grid: columns and rows a page holds. */
  cols: number;
  rows: number;
  /** The folded layout now (for the pins and every page that exists). */
  folded: Placed[];
  /** Keys placed by hand folded: they keep their folded spot while it's free. */
  pins: Set<string>;
  /** Keys just edited wide: their old folded spot doesn't count, the wide one does. */
  edited?: Set<string>;
  follow?: Follow;
}

/**
 * The units of one host page's items, in reading order on the wide page. Each one's old spot is its folded one (an
 * item the wide edit didn't touch stays put where it can); the item edited, and one new to the page, its wide spot.
 */
function foldedUnits(items: Placed[], o: ToFolded, half: { page: number; x0: number }): Unit[] {
  const now = new Map(o.folded.map((f) => [f.key, f]));
  const was = (key: string) => {
    const f = now.get(key);
    return f && f.page === half.page && !o.edited?.has(key) ? f.cell : null;
  };
  return [...items].sort(byReading).map((i) => ({
    key: i.key,
    w: i.cell.w,
    h: i.cell.h,
    pref: was(i.key) ?? { x: i.cell.x - half.x0, y: i.cell.y },
    pin: o.pins.has(i.key) && !o.edited?.has(i.key) ? (now.get(i.key) ?? null) : null,
  }));
}

/** A page number that no page has yet (then the next one). */
function pageMaker(o: ToFolded) {
  let next = Math.max(0, ...o.pairs.flat(), ...o.folded.map((f) => f.page)) + 1;
  return () => next++;
}

/**
 * The folded layout for what the wide screen shows: per wide page, the left half's items flow onto its first host
 * page and the right half's onto its second, in the wide page's reading order. What doesn't fit goes on to the next
 * page (the second of the pair, then new pages after all of them).
 */
export function foldedFromWide(o: ToFolded): Placed[] {
  const follow = o.follow ?? {};
  const lead = leaders(o.wide, follow);
  const newPage = pageMaker(o);
  const t = new Taken();
  const out = new Map<string, Placed>();
  // A page holds at least its tallest tile (a fresh page always takes the next one: never an endless run of pages).
  const grid = { cols: o.cols, rows: Math.max(o.rows, ...lead.map((w) => w.cell.h)) };
  o.pairs.forEach((pair, i) => {
    const on = lead.filter((w) => w.page === i + 1);
    const pages = [pair[0] ?? newPage(), pair[1] ?? 0];
    let carry: Unit[] = [];
    for (const half of [0, 1]) {
      const mine = on.filter((w) => halfOf(w.cell, o.cols) === half);
      if (half === 1 && !mine.length && !carry.length) break;
      if (half === 1 && !pages[1]) pages[1] = newPage();
      const units = foldedUnits(mine, o, { page: pages[half], x0: half * (o.cols + 1) });
      carry = flowRegion(t, region(pages[half], grid), [...carry, ...units], out);
    }
    while (carry.length) carry = flowRegion(t, region(newPage(), grid), carry, out);
  });
  return withFollowers(o.wide, follow, out);
}

const region = (page: number, o: { cols: number; rows: number }): Region => ({ page, x0: 0, cols: o.cols, rows: o.rows });

export interface ToWide {
  /** The folded layout (host pages). */
  folded: Placed[];
  pairs: number[][];
  /** Folded columns (a wide page is 2 x cols + 1). */
  cols: number;
  /** The wide layout now (page = the wide page): pinned keys keep their cell there while it's free. */
  wide: Placed[];
  pins: Set<string>;
  follow?: Follow;
}

/** The units of host page [page]'s items, in its reading order, their old spot their folded one. */
function wideUnits(items: Placed[], o: ToWide, wp: number): Unit[] {
  const now = new Map(o.wide.map((w) => [w.key, w]));
  return [...items].sort(byReading).map((i) => {
    const w = now.get(i.key);
    return { key: i.key, w: i.cell.w, h: i.cell.h, pref: { x: i.cell.x, y: i.cell.y }, pin: o.pins.has(i.key) && w?.page === wp ? w : null };
  });
}

/**
 * The wide layout for the folded one: each pair of host pages is one wide page, the first page's items in the left
 * half and the second's in the right half, in their folded order (at their folded spots where nothing pinned is).
 */
export function wideFromFolded(o: ToWide): Placed[] {
  const follow = o.follow ?? {};
  const lead = leaders(o.folded, follow);
  const t = new Taken();
  const out = new Map<string, Placed>();
  const wideCols = o.cols * 2 + 1;
  o.pairs.forEach((pair, i) => {
    const wp = i + 1;
    // Every pin on this wide page first, whichever half it is in (a pin may span the middle).
    const units = pair.map((p) => wideUnits(lead.filter((f) => f.page === p), o, wp));
    placePins(t, { page: wp, x0: 0, cols: wideCols, rows: DEEP }, units.flat(), out);
    pair.forEach((_, half) => flowRegion(t, { page: wp, x0: half * (o.cols + 1), cols: o.cols, rows: DEEP }, units[half], out));
  });
  return withFollowers(o.folded, follow, out);
}

/** Host pages two by two: wide page n shows pairs[n-1] (hosts/wide.ts). */
export function pairsOf(pages: number[]): number[][] {
  const sorted = [...pages].sort((a, b) => a - b);
  const out: number[][] = [];
  for (let i = 0; i < sorted.length; i += 2) out.push(sorted.slice(i, i + 2));
  return out.length ? out : [[1]];
}

/** Two placements overlap (a check: neither screen may have two tiles on one cell). */
export function overlaps(items: Placed[]): [string, string][] {
  const bad: [string, string][] = [];
  const hit = (a: Cell, b: Cell) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  items.forEach((a, i) => items.slice(i + 1).forEach((b) => a.page === b.page && hit(a.cell, b.cell) && a.cell !== b.cell && bad.push([a.key, b.key])));
  return bad;
}
