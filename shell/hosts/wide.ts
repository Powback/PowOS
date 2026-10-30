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
/**
 * Home's page (index.html without ?mode=) and the launcher overlay's (?mode=pull, pull.tsx): the launcher is home's, so
 * it lays out unfolded by the same decision home makes - one rule, not a second one in the overlay. The desktop's home
 * has its own grid, the other pages have no pages.
 */
const pageMode = new URLSearchParams(location.search).get("mode");
const isHome = !pageMode || pageMode === "pull";
/**
 * The native host's display state (system.display: width/height in dp, display id, orientation, folded), pushed on every
 * display change and on resume. Only a HINT to look again (and logged beside the decision): the decision itself is a
 * pure function of the page's CURRENT innerWidth. A kept host value decided once and went stale - folded portrait home
 * laid out wide with the unfolded dock (3rd device FAIL, 2026-10-28 13:28).
 */
type Display = { widthDp: number; heightDp: number; displayId: number; rotation: number; folded: boolean };
let hint: Display | null = null;
/**
 * A tall portrait page is never wide, whatever its width in CSS px: during a swipe up to home (recents) the folded
 * home's page measured 804x1790 (dpr ~1.39, not 2.76) and was laid out wide - the dock on the side, the 13-column grid
 * squashed ("desktop on mobile" after the AI page, 2026-10-28 13:53 logcat). The inner screen is ~square (821x883).
 */
const TALL = 0.6;
/**
 * The page's size now, as the eye sees it: the narrower of the layout viewport (innerWidth) and the visual viewport.
 * Over the PowOS AI page with the keyboard up the layout viewport grew to 759x1690 on a 404x899 screen (recents.tsx
 * bounds); the visual viewport stayed the screen's. The height stays the layout one: a keyboard only shortens the
 * visual viewport, and a shorter height must never make a portrait page "wide".
 */
const measure = () => {
  const vv = window.visualViewport;
  const w = Math.round(Math.min(innerWidth, vv?.width || innerWidth));
  return { w, h: Math.round(innerHeight) };
};
/**
 * The cover screen's short side is ~404 CSS px, the inner display's ~821 (698 at the panel's own density): turned
 * sideways the cover is 899 px wide and passed the width test, so folded landscape laid out as desktop mode. The
 * screen's short side does not change with rotation or a keyboard, so it tells the two screens apart in any orientation.
 */
const SHORT = 600;
const shortSide = () => (typeof screen === "object" && screen.width > 0 ? Math.min(screen.width, screen.height) : Infinity);
/**
 * THE mode rule, for every page (home, the launcher, the shade's control center): the inner display is desktop mode in
 * any orientation, the cover screen is mobile in any orientation (the user, 2026-10-30: the launcher and the control
 * center in landscape). Pages read this, never innerWidth on their own.
 */
export const desktopScreen = ({ w, h }: { w: number; h: number } = measure()) => w >= WIDE && w >= h * TALL && shortSide() >= SHORT;
const decide = (m: { w: number; h: number }) => isHome && desktopScreen(m);
const isWide = () => decide(measure());
/** The width the last decision was made at (a keyboard changes only the height). */
let lastW = measure().w;
const typing = () => {
  const a = document.activeElement as HTMLElement | null;
  return !!a && (a.tagName === "TEXTAREA" || a.tagName === "INPUT" || a.isContentEditable);
};
/**
 * A keyboard only shortens the page: a height change at the same width while a text field types keeps the decision
 * ([was]). A shorter height can only turn a tall page wide (w >= h * TALL), and a flip re-lays home out under the field
 * the user is typing into (launcher search, keyboard dismissed while typing - 2026-10-28).
 */
function heldWhileTyping(now: boolean, was: boolean, m: { w: number; h: number }, why: string) {
  const held = now !== was && m.w === lastW && typing();
  lastW = m.w;
  if (!held) return now;
  console.info(`layout wide=${was} kept: height-only change to ${m.w}x${m.h} while typing (why=${why})`);
  return was;
}

/** Home laid out wide now (home.tsx: one bottom bar - dock left, search, recent apps right). */
export const wideHome = signal(isWide());
/**
 * Home (or its launcher) on the cover screen turned sideways: still mobile (desktopScreen), but 404 px tall - the bottom
 * dock and the pill under the tiles took a third of it (the user, 2026-10-30: "when I put the phone screen in horizontal
 * mode, we should probably put the docking on the right side"). state.ts dockPosition puts the dock on the right for it.
 * Measured with the wide decision (recheck): a rotation, a fold and a return to home update both.
 */
const sidewaysNow = (m = measure()) => isHome && !desktopScreen(m) && m.w > m.h;
export const sidewaysHome = signal(sidewaysNow());
/** On <html> too (data-sideways): shell.css gives the side dock the screen's height and the pill the rest beside it. */
const mark = (on: boolean) => document.documentElement.toggleAttribute("data-sideways", on);
mark(sidewaysHome.value);
/** Sideways or not, measured again - a keyboard only shortens a page: never turned sideways by one (the pill typing). */
function turned(m: { w: number; h: number }) {
  if (m.w === lastW && typing()) return;
  mark((sidewaysHome.value = sidewaysNow(m)));
}

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
  /**
   * Wide or not as last decided (recheck) - only a copy of the last measurement, never a mode: every read measures
   * again (wideNow), so no stale value (an overlay's size, a resize dropped while hidden) outlives the next read.
   */
  let was = wideHome.value;
  const wideNow = () => (recheck("read"), was);

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
    if (!wideNow()) return h;
    const pages = [...h.pages].sort((a, b) => a - b);
    pairs = [];
    for (let i = 0; i < pages.length; i += 2) pairs.push(pages.slice(i, i + 2));
    if (!pairs.length) pairs = [[1]];
    const where = new Map<number, [number, number]>();
    pairs.forEach((p, i) => p.forEach((page, half) => where.set(page, [i + 1, half])));
    hostPage = new Map(h.items.map((it) => [it.key, it.page]));
    const kept = await load(h);
    const { items, changed } = layOut(h, where, kept);
    // Items gone from home keep their wide cell: one that comes back (re-added, a host list read mid-change) takes its
    // own place again instead of the first free cell - dropping it moved WireGuard to the middle column and Steam onto
    // its spot (2026-10-23). An absent item's cell holds nothing: layOut only places the host's items.
    if (changed) save();
    return { columns: cols * 2 + 1, pages: pairs.map((_, i) => i + 1), items };
  }

  /** A wide page and cell -> the host's (a tile onto another wide page): the half the cell's middle is over, inside it. */
  function toHost(page: number, cell: Cell | null): [number, Cell | null] {
    if (!wideNow()) return [page, cell];
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
    if (!wideNow()) return n.home.place(key, cell, page);
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
    if (wideNow() && cell) {
      keep(key, cell, toHost(page, cell)[0]);
      emit("home.changed", null);
    }
    return key;
  }

  /** The folder [app] is in now, unfolded (taken out of it, the folder may go away). */
  async function folderOf(app: string) {
    if (!wideNow() || !cells) return null;
    const h = await n.home.get().catch(() => null);
    return h?.items.find((i) => i.kind === "folder" && i.apps?.some((a) => a.app === app)) ?? null;
  }

  /** [app] taken out of [f]: the one app left in it, if that's all, takes the folder's wide cell (as folded). */
  function dissolved(f: HomeItem, app: string) {
    const at = cells?.[f.key];
    const rest = f.apps!.filter((a) => a.app !== app);
    if (!at || rest.length !== 1) return;
    keep(rest[0].key, at, at.hp);
    emit("home.changed", null);
  }

  // Folded or unfolded: home is laid out again from the host's own layout.
  // ONE decision (was) serves the bridge's layout (wideNow) and the UI (wideHome) alike. They used to read innerWidth
  // separately: a home.get landing between a fold and the recheck gave the wide layout to a folded page (or the
  // reverse), the "desktop layout on the cover screen, sometimes" bug (2026-10-28).
  const recheck = (why = "resize") => {
    // Hidden, the window may still have an app's size (landscape game): judged again the moment it's shown.
    if (document.hidden) return;
    const m = measure();
    turned(m);
    const now = heldWhileTyping(decide(m), was, m, why);
    const changed = now !== was;
    // Every decision that changes something, and every one asked by a show or a host push, is logged with its inputs
    // (console -> logcat PowosShell), so the next wrong layout explains itself. Plain resizes, viewport changes and reads
    // that change nothing stay quiet (a keyboard's resize stream, every home.get).
    if (changed || !["resize", "read", "visualViewport"].includes(why)) {
      const h = hint;
      const vv = window.visualViewport;
      console.info(`layout wide=${now} w=${m.w} h=${m.h} why=${why}${changed ? " (changed)" : ""} inner=${innerWidth}x${innerHeight} vv=${vv ? `${Math.round(vv.width)}x${Math.round(vv.height)}@${vv.scale.toFixed(2)}` : "-"} dpr=${devicePixelRatio.toFixed(2)}${h ? ` hint=${h.widthDp}x${h.heightDp}dp display=${h.displayId} rot=${h.rotation} folded=${h.folded}` : ""}`);
    }
    if (!changed) return;
    was = wideHome.value = now;
    emit("home.changed", null);
  };
  // Every way the size can change: a resize, a rotation, a fold, and coming back to home (an app that ran in landscape
  // - Broforce - left home hidden at its size: the resize while hidden was judged on that, and none came on return,
  // so home stayed laid out wide - tiny cells squashed at the top). Hidden, nothing is decided; shown again, at once
  // and once more after the window has its size. These serve the no-host case; with a host they only re-ask it.
  addEventListener("resize", () => recheck());
  // The visual viewport changes on its own (an overlay's keyboard, a zoom): the layout viewport may send no resize.
  window.visualViewport?.addEventListener("resize", () => recheck("visualViewport"));
  addEventListener("focus", () => recheck("focus"));
  addEventListener("orientationchange", () => recheck("orientation"));
  addEventListener("pageshow", () => recheck("pageshow"));
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    pull();
    recheck("shown");
    requestAnimationFrame(() => requestAnimationFrame(() => recheck()));
    setTimeout(() => recheck(), 400);
  });
  if (typeof ResizeObserver !== "undefined") new ResizeObserver(() => recheck()).observe(document.documentElement);
  // The host pushes its display state on every display/fold change and on resume ("system.display"); a fold while the
  // page is hidden delivers no resize, which is why a 1 s heartbeat used to stand here.
  const apply = (d: Display | null) => {
    if (!d || typeof d.widthDp !== "number") return;
    hint = d;
    recheck(`host display`);
    // The window gets its new size a moment after the host's push: look again once it has.
    requestAnimationFrame(() => requestAnimationFrame(() => recheck()));
    setTimeout(() => recheck(), 400);
  };
  const pull = () => void n.system.display?.().then(apply).catch(() => {});
  n.on("system.display", apply);
  pull();
  // HACK: a host without system.display (APK older than 44ab84fd) pushes nothing, so a fold while home is hidden is only
  // caught by this 1 s recheck (while shown). Remove once every host has system.display.
  if (!n.system.display) setInterval(() => recheck(), 1000);

  return {
    ...n,
    home: {
      ...n.home,
      get: async () => toWide(await n.home.get()),
      place,
      add: async (app, page, cell) => {
        const from = await folderOf(app);
        const [p, c] = toHost(page, cell ?? null);
        const key = await added(await n.home.add(app, p, c ?? undefined), page, cell && { ...cell, w: 1, h: 1 });
        if (from) dissolved(from, app);
        return key;
      },
      group: async (key, target) => {
        // Two apps make a new folder in the target's place: on the wide page too (not the side-by-side spot).
        const at = wideNow() && !target.startsWith("folder:") ? cells?.[target] : undefined;
        const made = await n.home.group(key, target);
        if (made && at && made !== target) {
          keep(made, at, at.hp);
          emit("home.changed", null);
        }
        return made;
      },
      addPanel: async (name, page, cell) => {
        const [p, c] = toHost(page, cell);
        return added(await n.home.addPanel(name, p, c!), page, cell);
      },
      arrange: (columns, rows) => n.home.arrange(wideNow() ? cols : columns, rows),
    },
    // The shown page's widgets stay live, and the next page's (the host's rule): its left half's page covers both.
    // A desktop page after them (state.ts pages: no tiles yet) is a host page past all of them: nothing of theirs runs.
    widgets: {
      ...n.widgets,
      page: (page) => n.widgets.page(wideNow() ? (pairs[page - 1]?.[0] ?? Math.max(0, ...pairs.flat()) + page - pairs.length) : page),
    },
    on: (event, handler) => {
      const off = n.on(event, handler);
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event)!.add(handler);
      return () => (off(), listeners.get(event)?.delete(handler));
    },
  };
}
