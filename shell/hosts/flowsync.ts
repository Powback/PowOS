/**
 * The two screens' layouts kept as ONE (hosts/reflow.ts has the model): an edit on the wide screen is laid out on the
 * folded one (the host's own layout, through home.place) and an edit folded on the wide one (the store "home.wide").
 * hosts/wide.ts calls in here after each of its edits; nothing here runs on its own but the migration.
 *
 * Store "home.flow" = { v: 1, at, pins: { wide: [keys], folded: [keys] }, rows: { folded, wide } }:
 *   pins  - items the user placed by hand on that screen (kept there when the other screen is edited, while free);
 *   rows  - the rows a page of each screen holds, as last measured there (grid.tsx noteRows): the folded page's depth
 *           is what the wide screen's edits flow into while folded isn't on screen.
 * No store = the old, separate layouts: migrated once (migrate): the union of both, the most recently edited winning.
 */
import type { Bridge, Cell, Home } from "../types.ts";
import { parseStacks } from "../ui/stackmodel.ts";
import { FOLDED_ROWS, foldedFromWide, pairsOf, wideFromFolded, type Follow, type Placed } from "./reflow.ts";

export const FLOW = "home.flow";
type Screen = "wide" | "folded";
interface Flow {
  v: 1;
  at: number;
  pins: Record<Screen, string[]>;
  rows: Partial<Record<Screen, number>>;
}
/** A tile's cell on the wide page and the host page it is on (hosts/wide.ts). */
export type WideCell = Cell & { hp: number };

/** What wide.ts gives this: the host underneath and its wide cells. */
export interface Ctx {
  n: Bridge;
  cells: () => Promise<Record<string, WideCell>>;
  saveCells: () => void;
}

let flow: Flow | null = null;
const fresh = (): Flow => ({ v: 1, at: Date.now(), pins: { wide: [], folded: [] }, rows: {} });
/** Rows measured before the store was read (grid.tsx measures at once). */
const seenRows: Partial<Record<Screen, number>> = {};
let store: Bridge["store"] | null = null;
const saveFlow = () => flow && store?.set(FLOW, flow).catch(() => {});

async function loadFlow(n: Bridge): Promise<Flow | null> {
  store = n.store;
  if (flow) return flow;
  const v = await n.store.get<Flow>(FLOW).catch(() => null);
  if (!v || v.v !== 1 || !v.pins) return null;
  flow = { ...fresh(), ...v, rows: { ...v.rows, ...seenRows } };
  return flow;
}

/** grid.tsx: the rows a page holds on the screen on now (square cells), kept for laying out the other screen. */
export function noteRows(wide: boolean, rows: number) {
  const s: Screen = wide ? "wide" : "folded";
  if (!(rows > 0) || seenRows[s] === rows) return;
  seenRows[s] = rows;
  if (!flow || flow.rows[s] === rows) return;
  flow.rows[s] = rows;
  saveFlow();
}

/** Stack members (other than the anchor) -> the anchor: a stack is one tile to lay out. */
async function follow(n: Bridge): Promise<Follow> {
  const stacks = parseStacks(await n.store.get("home.stacks").catch(() => null));
  const out: Follow = {};
  for (const s of Object.values(stacks)) for (const k of s.keys) if (k !== s.anchor) out[k] = s.anchor;
  return out;
}

const placedOf = (h: Home): Placed[] => h.items.filter((i) => i.cell).map((i) => ({ key: i.key, page: i.page, cell: i.cell! }));

/** The wide page (1-based) host page [hp] is shown on. */
const widePage = (pairs: number[][], hp: number) => pairs.findIndex((p) => p.includes(hp)) + 1;

/**
 * The kept wide cells that still hold, as wide placements: the item is on the wide page its cell was kept for. Not the
 * exact host page: while a sync moves items between a pair's two pages (the cell's hp first, then the host), a home.get
 * in between must keep the cell, not lay the item out again over the user's placement.
 */
function keptWide(h: Home, cells: Record<string, WideCell>, pairs: number[][]): Placed[] {
  return h.items.flatMap((i) => {
    const c = cells[i.key];
    if (!c || !widePage(pairs, i.page) || widePage(pairs, c.hp) !== widePage(pairs, i.page)) return [];
    return [{ key: i.key, page: widePage(pairs, i.page), cell: { x: c.x, y: c.y, w: c.w, h: c.h } }];
  });
}

/**
 * Every item's wide placement: its kept cell, else laid out from the folded layout around the kept ones (an item added
 * folded, the first wide run). [missing] the keys that had none (wide.ts writes them).
 */
export async function wideView(n: Bridge, h: Home, cells: Record<string, WideCell>) {
  const pairs = pairsOf(h.pages);
  const kept = keptWide(h, cells, pairs);
  const have = new Set(kept.map((k) => k.key));
  const missing = h.items.filter((i) => i.cell && !have.has(i.key)).map((i) => i.key);
  if (!missing.length) return { pairs, items: kept, missing };
  const items = wideFromFolded({ folded: placedOf(h), pairs, cols: h.columns, wide: kept, pins: have, follow: await follow(n) });
  return { pairs, items, missing };
}

/** The folded rows to flow into: as measured folded, and never fewer than a page already uses. */
const foldedRows = (h: Home) => Math.max(flow?.rows.folded ?? seenRows.folded ?? FOLDED_ROWS, ...placedOf(h).map((p) => p.cell.y + p.cell.h));

const same = (a: Cell | null, b: Cell) => !!a && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;

/**
 * The folded layout laid out again from the wide one ([edited]: the keys just edited wide). Each item that lands
 * elsewhere is placed through the host; its wide cell keeps its new host page (or goes, when the item went on to a page
 * outside its wide page: laid out again there).
 */
async function syncFolded(ctx: Ctx, edited: Set<string>) {
  const { n } = ctx;
  const h = await n.home.get();
  const cells = await ctx.cells();
  const { pairs, items } = await wideView(n, h, cells);
  const fold = foldedFromWide({ wide: items, pairs, cols: h.columns, rows: foldedRows(h), folded: placedOf(h), pins: pinsOf("folded", edited), edited, follow: await follow(n) });
  const now = new Map(h.items.map((i) => [i.key, i]));
  for (const f of fold) {
    const it = now.get(f.key);
    if (!it || (it.page === f.page && same(it.cell, f.cell))) continue;
    // Its wide cell follows first: the host's home.changed re-reads the wide page before this loop goes on.
    const c = cells[f.key];
    if (c && widePage(pairs, f.page) === widePage(pairs, c.hp)) c.hp = f.page;
    else delete cells[f.key];
    await n.home.place(f.key, f.cell, f.page);
  }
  ctx.saveCells();
}

/** The wide layout laid out again from the folded one ([edited]: the keys just edited folded): the store only. */
async function syncWide(ctx: Ctx, edited: Set<string>) {
  const { n } = ctx;
  const h = await n.home.get();
  const cells = await ctx.cells();
  const pairs = pairsOf(h.pages);
  const items = wideFromFolded({ folded: placedOf(h), pairs, cols: h.columns, wide: keptWide(h, cells, pairs), pins: pinsOf("wide", edited), follow: await follow(n) });
  const page = new Map(h.items.map((i) => [i.key, i.page]));
  let moved = false;
  for (const w of items) {
    const c = cells[w.key], hp = page.get(w.key)!;
    if (c && c.hp === hp && same(c, w.cell)) continue;
    cells[w.key] = { ...w.cell, hp };
    moved = true;
  }
  // The folded screen is the one on: nothing to show now (the wide page reads the store when it's laid out next). No
  // home.changed either - home would re-read the host for nothing (and drop a tile only the page has, island-hold).
  if (moved) ctx.saveCells();
}

/** A screen's pins less the keys just edited. */
function pinsOf(s: Screen, edited: Set<string>) {
  return new Set((flow?.pins[s] ?? []).filter((k) => !edited.has(k)));
}

/** One sync at a time, edits made while one waits joined to it (a stack's members move one by one). */
let queue: Promise<unknown> = Promise.resolve();
let waiting: { to: Screen; keys: Set<string> } | null = null;

/**
 * An edit on screen [on] (the wide one or the folded one): [key] (null: a removal, a folder) is now placed by hand
 * there - pinned there, never on the other screen, which is laid out again from this one.
 */
export function edited(ctx: Ctx, on: Screen, key: string | null) {
  const other: Screen = on === "wide" ? "folded" : "wide";
  if (flow && key) {
    flow.pins[other] = flow.pins[other].filter((k) => k !== key);
    if (!flow.pins[on].includes(key)) flow.pins[on].push(key);
    flow.at = Date.now();
    saveFlow();
  }
  if (waiting?.to === other) {
    if (key) waiting.keys.add(key);
    return queue;
  }
  const job = { to: other, keys: new Set(key ? [key] : []) };
  waiting = job;
  queue = queue.then(async () => {
    if (waiting === job) waiting = null;
    await (job.to === "folded" ? syncFolded(ctx, job.keys) : syncWide(ctx, job.keys)).catch((e) => console.warn(`[flow] ${job.to}: ${e}`));
  });
  return queue;
}

/** Done laying out the other screen (the gate waits on it after an edit). */
export const flowSettled = () => queue;

/** An item gone from home leaves no pin behind. */
export function forget(key: string) {
  if (!flow) return;
  for (const s of ["wide", "folded"] as Screen[]) flow.pins[s] = flow.pins[s].filter((k) => k !== key);
  saveFlow();
}

/**
 * The migration (no "home.flow" yet): until now the screens were separate - the wide cells (store "home.wide") moved
 * only wide, the host's layout only folded. Every item is on both (the host holds them all), so the union is the
 * placement: per item, the screen it was edited on wins.
 *   - Edited wide: a kept wide cell off the spot the wide page first gave it (side by side: x + 7 on the right half).
 *     Any such cell makes the whole wide layout the user's own: every kept wide cell is pinned (the user's wide screen
 *     doesn't move), and the folded one is laid out from it.
 *   - Edited folded: its folded cell differs from the host layout's backup ("home.wide.backup", taken before the first
 *     wide cells): pinned folded, unless it was edited wide too - no times are kept, and the wide edit is the newer
 *     (the report: changed unfolded, not reflected folded).
 * Nothing is removed: every item stays on home, on both screens.
 */
let migrating: Promise<void> | null = null;
export function migrate(ctx: Ctx, h: Home) {
  return (migrating ??= migrateOnce(ctx, h));
}
async function migrateOnce(ctx: Ctx, h: Home) {
  if (await loadFlow(ctx.n)) return;
  const cells = await ctx.cells();
  const pairs = pairsOf(h.pages);
  const kept = keptWide(h, cells, pairs);
  const backup = (await ctx.n.store.get<{ home?: Home }>("home.wide.backup").catch(() => null))?.home;
  const wideEdited = kept.filter((k) => !same(sideBySide(h, k.key, pairs), k.cell)).map((k) => k.key);
  const was = new Map((backup?.items ?? []).map((i) => [i.key, i]));
  const foldedEdited = placedOf(h).filter((p) => was.has(p.key) && !(was.get(p.key)!.page === p.page && same(was.get(p.key)!.cell, p.cell)));
  flow = fresh();
  flow.rows = { ...seenRows };
  if (wideEdited.length) flow.pins.wide = kept.map((k) => k.key);
  flow.pins.folded = foldedEdited.map((p) => p.key).filter((k) => !wideEdited.includes(k));
  saveFlow();
  console.info(`[flow] migrated: ${wideEdited.length} edited wide, ${flow.pins.folded.length} edited folded`);
  if (wideEdited.length) await syncFolded(ctx, new Set());
}

/** Where the first wide run put [key]: its folded cell, on the right half when its page is the pair's second. */
function sideBySide(h: Home, key: string, pairs: number[][]): Cell | null {
  const it = h.items.find((i) => i.key === key);
  if (!it?.cell) return null;
  const half = pairs[widePage(pairs, it.page) - 1]?.indexOf(it.page) ?? 0;
  return { ...it.cell, x: it.cell.x + Math.max(0, half) * (h.columns + 1) };
}

/** The gate's reset between cases: the module's copy of the store dropped (read again from the store). */
export function resetFlow() {
  flow = null;
  migrating = null;
}
