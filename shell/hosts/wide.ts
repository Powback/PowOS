/**
 * Home on a wide screen (the phone unfolded: 821 CSS px, against the cover's 404): ONE wide page of 13 columns, each
 * tile at the size it has folded - not the folded grid stretched to twice its cell size (huge tiles, huge type, an
 * empty middle) and not two pages side by side (the user, 2026-10-22: tiles anywhere across it, one bottom bar).
 *
 * The host keeps one layout, the folded one (ShellHome.kt, GRID_COLUMNS: 6). The wide page has its own cells over it,
 * kept in the store ("home.wide": item key -> cell + the host page it was on), so folding never changes and moving a
 * tile wide never moves it folded. Wide page n covers the host's pages 2n-1 and 2n (pages [1, 3]: one wide page); an
 * item with no wide cell yet - the first time (the migration), or added folded - gets the place it had when the two
 * pages showed side by side: x + columns + 1 for the right one, or the first free spot when that is taken. The host's
 * layout is backed up once in the store ("home.wide.backup") before the first wide cells are written.
 */
import { signal } from "@preact/signals";
import type { Bridge, Cell, Home, HomeItem } from "../types.ts";

/** Wider than this (CSS px) is the wide page: the inner display, never the cover screen. */
const WIDE = 700;
/** Home's page only (index.html without ?mode=): the desktop's home has its own grid, the other pages have no pages. */
const isHome = !new URLSearchParams(location.search).get("mode");
const isWide = () => isHome && innerWidth >= WIDE;
/** Home laid out wide now (home.tsx: one bottom bar - dock left, search, recent apps right). */
export const wideHome = signal(isWide());

const STORE = "home.wide";
const BACKUP = "home.wide.backup";
/** A tile's cell on the wide page and the host page it was on then (moved to another page folded: placed again). */
type WideCell = Cell & { hp: number };

/** Cells [c] covers, as "x,y". */
const covers = (c: Cell) => {
  const out: string[] = [];
  for (let y = c.y; y < c.y + c.h; y++) for (let x = c.x; x < c.x + c.w; x++) out.push(`${x},${y}`);
  return out;
};

/** The first free spot for [c]'s size on a page whose taken cells are [used], row by row; [c] itself when it's free. */
function freeSpot(c: Cell, used: Set<string>, columns: number): Cell {
  if (!covers(c).some((k) => used.has(k))) return c;
  const w = Math.min(c.w, columns);
  for (let y = 0; y < 256; y++)
    for (let x = 0; x + w <= columns; x++) {
      const at = { x, y, w, h: c.h };
      if (!covers(at).some((k) => used.has(k))) return at;
    }
  return c;
}

export function wide(n: Bridge): Bridge {
  const listeners = new Map<string, Set<(d: any) => void>>();
  const emit = (event: string, data: unknown) => listeners.get(event)?.forEach((h) => h(data));
  /** Wide page (1-based) -> the host's pages it covers; the host's columns; each item's host page. */
  let pairs: number[][] = [[1]];
  let cols = 6;
  let hostPage = new Map<string, number>();
  /** The wide cells (null: not read from the store yet). */
  let cells: Record<string, WideCell> | null = null;

  const save = () => n.store.set(STORE, cells).catch(() => {});

  /** Read once (two reads at once share it: a second read must not replace cells the first has laid out). */
  let loading: Promise<Record<string, WideCell>> | null = null;
  async function read(h: Home) {
    const kept = await n.store.get<Record<string, WideCell>>(STORE).catch(() => null);
    if (kept && typeof kept === "object") return (cells = kept);
    // The first wide layout: the host's own, as it is, kept before anything is written from it.
    if (!(await n.store.get(BACKUP).catch(() => null))) await n.store.set(BACKUP, { at: Date.now(), home: h }).catch(() => {});
    return (cells = {});
  }
  const load = (h: Home) => (loading ??= read(h));

  /** Where [it] shows when it has no wide cell: its half of the wide page, as the side-by-side pages had it. */
  function sideBySide(it: HomeItem, half: number): Cell | null {
    return it.cell && { ...it.cell, x: it.cell.x + half * (cols + 1) };
  }

  /** The items on the wide pages: kept cells first, then the others where the side-by-side pages had them. */
  function layOut(h: Home, where: Map<number, [number, number]>, kept: Record<string, WideCell>) {
    const columns = cols * 2 + 1;
    const used = new Map<number, Set<string>>();
    const take = (page: number, c: Cell) => {
      if (!used.has(page)) used.set(page, new Set());
      covers(c).forEach((k) => used.get(page)!.add(k));
    };
    const own = (it: HomeItem) => kept[it.key]?.hp === it.page;
    let changed = false;
    const out = new Map<string, HomeItem>();
    for (const it of h.items.filter(own)) {
      const { hp: _, ...cell } = kept[it.key];
      const page = where.get(it.page)?.[0] ?? 1;
      take(page, cell);
      out.set(it.key, { ...it, page, cell });
    }
    for (const it of h.items.filter((i) => !own(i))) {
      const [page, half] = where.get(it.page) ?? [1, 0];
      const side = sideBySide(it, half);
      const cell = side && freeSpot(side, used.get(page) ?? new Set(), columns);
      if (cell) {
        take(page, cell);
        kept[it.key] = { ...cell, hp: it.page };
        changed = true;
      }
      out.set(it.key, { ...it, page, cell });
    }
    return { items: h.items.map((i) => out.get(i.key)!), changed };
  }

  async function toWide(h: Home): Promise<Home> {
    cols = h.columns;
    if (!isWide()) return h;
    const pages = [...h.pages].sort((a, b) => a - b);
    pairs = [];
    for (let i = 0; i < pages.length; i += 2) pairs.push(pages.slice(i, i + 2));
    if (!pairs.length) pairs = [[1]];
    const where = new Map<number, [number, number]>();
    pairs.forEach((p, i) => p.forEach((page, half) => where.set(page, [i + 1, half])));
    hostPage = new Map(h.items.map((it) => [it.key, it.page]));
    const kept = await load(h);
    const { items, changed } = layOut(h, where, kept);
    // Items gone from home (removed, folded or wide) leave the store; a list read empty (starting up) clears nothing.
    let pruned = false;
    if (h.items.length)
      for (const key of Object.keys(kept))
        if (!hostPage.has(key)) {
          delete kept[key];
          pruned = true;
        }
    if (changed || pruned) save();
    return { columns: cols * 2 + 1, pages: pairs.map((_, i) => i + 1), items };
  }

  /** A wide page and cell -> the host's (a tile onto another wide page): the half the cell's middle is over, inside it. */
  function toHost(page: number, cell: Cell | null): [number, Cell | null] {
    if (!isWide()) return [page, cell];
    const pair = pairs[page - 1] ?? [];
    const half = cell && cell.x + cell.w / 2 > cols + 0.5 ? 1 : 0;
    let host = pair[half] ?? pair[0];
    // No page there yet: a new one after all of them.
    if (host == null) host = Math.max(0, ...pairs.flat()) + 1;
    if (!cell) return [host, null];
    const w = Math.min(cell.w, cols);
    return [host, { ...cell, w, x: Math.max(0, Math.min(cols - w, cell.x - half * (cols + 1))) }];
  }

  /** Keeps [cell] as [key]'s wide cell, on host page [hp]. */
  function keep(key: string, cell: Cell, hp: number) {
    if (!cells) return;
    cells[key] = { x: cell.x, y: cell.y, w: cell.w, h: cell.h, hp };
    save();
  }

  /**
   * Moved or resized on the wide page: only its wide cell changes - folded it stays where it was. Onto another wide
   * page, the host moves it to that page's half too (the folded screen must find it on a page that page covers).
   */
  async function place(key: string, cell: Cell, page: number) {
    if (!isWide()) return n.home.place(key, cell, page);
    const hp = hostPage.get(key);
    if (hp != null && pairs[page - 1]?.includes(hp)) {
      keep(key, cell, hp);
      return emit("home.changed", null);
    }
    const [p, c] = toHost(page, cell);
    keep(key, cell, p);
    return n.home.place(key, c!, p);
  }

  /** Added on the wide page (an app dropped there, a panel): the host's page and cell for it, then its wide cell. */
  async function added(key: string, page: number, cell: Cell | null | undefined) {
    if (isWide() && cell) {
      keep(key, cell, toHost(page, cell)[0]);
      emit("home.changed", null);
    }
    return key;
  }

  // Folded or unfolded: home is laid out again from the host's own layout.
  let was = isWide();
  const recheck = () => {
    if (document.hidden || isWide() === was) return;
    was = wideHome.value = isWide();
    emit("home.changed", null);
  };
  // Every way the size can change: a resize, a rotation, a fold, and coming back to home (an app that ran in landscape
  // - Broforce - left home hidden at its size: the resize while hidden was judged on that, and none came on return,
  // so home stayed laid out wide - tiny cells squashed at the top). Hidden, nothing is decided; shown again, at once
  // and once more after the window has its size.
  addEventListener("resize", recheck);
  addEventListener("orientationchange", recheck);
  addEventListener("pageshow", recheck);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    recheck();
    requestAnimationFrame(() => requestAnimationFrame(recheck));
    setTimeout(recheck, 400);
  });
  if (typeof ResizeObserver !== "undefined") new ResizeObserver(recheck).observe(document.documentElement);

  return {
    ...n,
    home: {
      ...n.home,
      get: async () => toWide(await n.home.get()),
      place,
      add: async (app, page, cell) => {
        const [p, c] = toHost(page, cell ?? null);
        return added(await n.home.add(app, p, c ?? undefined), page, cell && { ...cell, w: 1, h: 1 });
      },
      addPanel: async (name, page, cell) => {
        const [p, c] = toHost(page, cell);
        return added(await n.home.addPanel(name, p, c!), page, cell);
      },
      arrange: (columns, rows) => n.home.arrange(isWide() ? cols : columns, rows),
    },
    // The shown page's widgets stay live, and the next page's (the host's rule): its left half's page covers both.
    widgets: { ...n.widgets, page: (page) => n.widgets.page(isWide() ? (pairs[page - 1]?.[0] ?? page) : page) },
    on: (event, handler) => {
      const off = n.on(event, handler);
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event)!.add(handler);
      return () => (off(), listeners.get(event)?.delete(handler));
    },
  };
}
