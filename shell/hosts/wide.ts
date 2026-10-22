/**
 * Home on a wide screen (the phone unfolded: 821 CSS px, against the cover's 404): two of home's pages side by side
 * as one page of twice the columns, each tile at the size it has folded - not the folded grid stretched to twice its
 * cell size (huge tiles, huge type, an empty middle).
 *
 * One layout for both screens: the host keeps its pages and cells as they are (ShellHome.kt, GRID_COLUMNS); this maps
 * them both ways at the bridge. Wide page n shows the host's pages 2n-1 and 2n in the order they come (pages [1, 3]:
 * 1 left, 3 right), x + columns on the right half. A tile moved or added on the wide page goes back to the half its
 * middle is over, inside it - so folding again finds every tile where the folded screen can show it.
 */
import type { Bridge, Cell, Home } from "../types.ts";

/** Wider than this (CSS px) is two pages side by side: the inner display, never the cover screen. */
const WIDE = 700;
const isWide = () => innerWidth >= WIDE;

export function wide(n: Bridge): Bridge {
  const listeners = new Map<string, Set<(d: any) => void>>();
  const emit = (event: string, data: unknown) => listeners.get(event)?.forEach((h) => h(data));
  /** Wide page (1-based) -> the host's pages on its left and right half; the host's columns. */
  let pairs: number[][] = [[1]];
  let cols = 6;

  function toWide(h: Home): Home {
    cols = h.columns;
    if (!isWide()) return h;
    const pages = [...h.pages].sort((a, b) => a - b);
    pairs = [];
    for (let i = 0; i < pages.length; i += 2) pairs.push(pages.slice(i, i + 2));
    if (!pairs.length) pairs = [[1]];
    const where = new Map<number, [number, number]>();
    pairs.forEach((p, i) => p.forEach((page, half) => where.set(page, [i + 1, half])));
    return {
      columns: cols * 2,
      pages: pairs.map((_, i) => i + 1),
      items: h.items.map((it) => {
        const [page, half] = where.get(it.page) ?? [1, 0];
        return { ...it, page, cell: it.cell && { ...it.cell, x: it.cell.x + half * cols } };
      }),
    };
  }

  /** A wide page and cell -> the host's: the half the cell's middle is over, kept inside that half. */
  function toHost(page: number, cell: Cell | null): [number, Cell | null] {
    if (!isWide()) return [page, cell];
    const pair = pairs[page - 1] ?? [];
    const half = cell && cell.x + cell.w / 2 > cols ? 1 : 0;
    let host = pair[half];
    // No page there yet (an odd count): a new one after all of them.
    if (host == null) host = Math.max(0, ...pairs.flat()) + 1;
    if (!cell) return [host, null];
    const w = Math.min(cell.w, cols);
    return [host, { ...cell, w, x: Math.max(0, Math.min(cols - w, cell.x - half * cols)) }];
  }

  // Folded or unfolded: home is laid out again from the host's own layout.
  let was = isWide();
  addEventListener("resize", () => {
    if (isWide() === was) return;
    was = isWide();
    emit("home.changed", null);
  });

  return {
    ...n,
    home: {
      ...n.home,
      get: async () => toWide(await n.home.get()),
      place: (key, cell, page) => {
        const [p, c] = toHost(page, cell);
        return n.home.place(key, c!, p);
      },
      add: (app, page, cell) => {
        const [p, c] = toHost(page, cell ?? null);
        return n.home.add(app, p, c ?? undefined);
      },
      addPanel: (name, page, cell) => {
        const [p, c] = toHost(page, cell);
        return n.home.addPanel(name, p, c!);
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
