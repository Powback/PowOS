/**
 * The desktop's host (powos-shell, docs/DESKTOP-SHELL.md): the same Bridge as the phone's, over the same native
 * transport (bridge.ts native()). What powos-shell does natively: apps (.desktop files, KSycoca), windows, the store,
 * the theme (Omarchy's), PowOS AI's chat (`powos manager`), the glass (KWin's blur, over the native port). What it
 * keeps here, in the page, over its store: home's layout and the recent apps. What a desktop doesn't have: the soft
 * keyboard (the compositor's input method), Android's widget screens - those resolve as no-ops.
 */
import type { App, Bridge, Home, HomeItem } from "../types.ts";
import { homeLayout } from "./layout.ts";

const HOME = "desktop-home";
/** The dock's pins before the user pins any: the desktop's own core apps, those installed. */
const DOCK_DEFAULT = ["l:org.kde.konsole", "l:org.kde.dolphin", "l:firefox", "l:chromium", "l:org.kde.kate", "l:systemsettings"];
const RECENT = "desktop-recent";

/** About 100 px a column, 4 or more: the desktop's grid follows its surface (a screen, folded or not). */
const columnsFor = (width: number) => Math.max(4, Math.round(width / 100));

/**
 * A first home: PowOS AI's work board and PowOS apps' islands, side by side across a desktop-wide grid (about 110 px
 * a column, 4 or more), a free column and row between them - touching tiles merge into one surface on home, and these
 * are three. Apps stay in the drawer.
 */
function firstHome(): Home {
  const columns = columnsFor(innerWidth);
  const w = columns >= 8 ? 3 : Math.max(2, Math.floor((columns - 1) / 2));
  const across = Math.max(1, Math.floor((columns + 1) / (w + 1)));
  // As small as each shows its content (the preview tool's fill check: the board at one row is a 4-16% status strip).
  const starters: [string, number][] = [["agents", 2], ["app:local.lights/main", 2], ["app:local.shopping/main", 2]];
  let y = 0;
  let rowH = 0;
  const items = starters.map(([name, h], i): HomeItem => {
    const col = i % across;
    if (col === 0 && i > 0) (y += rowH + 1), (rowH = 0);
    rowH = Math.max(rowH, h);
    return { key: `panel:${name}`, kind: "panel", name, page: 1, cell: { x: col * (w + 1), y, w, h }, resizable: true, minSize: [2, 1], size: [w, h] };
  });
  return { columns, pages: [1], items };
}

export function desktop(n: Bridge): Bridge {
  const listeners = new Map<string, Set<(d: any) => void>>();
  const emit = (event: string, data: unknown) => listeners.get(event)?.forEach((h) => h(data));
  let apps: App[] = [];
  let recent: string[] = [];
  const home: Home = { columns: 6, pages: [1], items: [] };
  const layout = homeLayout(home, () => (n.store.set(HOME, home), emit("home.changed", null)), () => apps);
  // Home and the recent list from the store before the first answer (a fresh desktop: firstHome).
  const ready = (async () => {
    const [saved, list, last] = await Promise.all([n.store.get<Home>(HOME), n.apps.list().catch(() => []), n.store.get<string[]>(RECENT)]);
    apps = list;
    recent = Array.isArray(last) ? last : [];
    Object.assign(home, saved && Array.isArray(saved.items) ? saved : firstHome());
    fit();
  })();
  /** The columns for this width; a tile that no longer fits is placed again (the grid's arrange), never left over the edge. */
  function fit(): boolean {
    const cols = columnsFor(innerWidth);
    if (home.columns === cols) return false;
    home.columns = cols;
    for (const i of home.items) if (i.cell && i.cell.x + i.cell.w > cols) i.cell = null;
    return true;
  }
  addEventListener("resize", async () => {
    // Qt can resize its surface while the native store is still loading.
    await ready;
    if (fit()) (n.store.set(HOME, home), emit("home.changed", null));
  });
  const after =
    <A extends unknown[], R>(f: (...a: A) => Promise<R>) =>
    async (...a: A) => (await ready, f(...a));
  n.on("apps.changed", async () => (apps = await n.apps.list()));
  const none = async () => {};
  return {
    ...n,
    host: "powos",
    apps: {
      ...n.apps,
      list: async () => (apps = await n.apps.list()),
      launch: async (key) => {
        await ready;
        await n.apps.launch(key);
        recent = [key, ...recent.filter((k) => k !== key)].slice(0, 30);
        n.store.set(RECENT, recent);
      },
    },
    usage: { recent: async (limit) => (await ready, recent.slice(0, limit)) },
    store: {
      ...n.store,
      get: async <T>(name: string) => {
        const v = await n.store.get<T>(name);
        if (name !== "dock" || v != null) return v;
        await ready;
        return DOCK_DEFAULT.filter((k) => apps.some((a) => a.key === k)) as T;
      },
    },
    home: {
      get: after(layout.get),
      place: after(layout.place),
      add: after(layout.add),
      remove: after(layout.remove),
      group: after(layout.group),
      arrange: after(layout.arrange),
      addPanel: after(layout.addPanel),
    },
    // No Android widget screens or pages here (OWL widgets need the engine's JS port: docs/DESKTOP-SHELL.md).
    widgets: { ...n.widgets, screen: async () => ({ key: null }), closeScreen: none, page: none },
    keyboard: { show: none, hide: none },
    // Dictation on the desktop is round 2 (the GPU box's speech, as the phone's GpuSpeech): the pill shows no mic.
    speech: { start: async () => "unavailable" as const, stop: none, cancel: none, hold: none, warm: none, quiet: none },
    on: (event, handler) => {
      const off = n.on(event, handler);
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event)!.add(handler);
      return () => (off(), listeners.get(event)?.delete(handler));
    },
  };
}
