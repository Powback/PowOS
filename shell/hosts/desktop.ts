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
const RECENT = "desktop-recent";

/**
 * A first home: PowOS AI's work board, a PowOS app's island and the terminal and files, placed by the grid (no
 * cells: arrange puts each in the first free spot). Columns for a desktop's width: about 110 px each, 4 or more.
 */
function firstHome(apps: App[]): Home {
  const columns = Math.max(4, Math.round(innerWidth / 110));
  const panel = (name: string, w: number, h: number): HomeItem => ({
    key: `panel:${name}`,
    kind: "panel",
    name,
    page: 1,
    cell: null,
    resizable: true,
    minSize: [2, 1],
    size: [Math.min(w, columns), h],
  });
  const app = (key: string): HomeItem[] => {
    const a = apps.find((x) => x.key === key);
    return a ? [{ key: `linux:${key.slice(2)}`, kind: "app", page: 1, cell: null, resizable: false, minSize: [1, 1], size: [1, 1], label: a.label, app: key }] : [];
  };
  return {
    columns,
    pages: [1],
    items: [panel("agents", 4, 2), panel("app:dev.powos.counter/count", 4, 2), ...app("l:org.kde.konsole"), ...app("l:org.kde.dolphin")],
  };
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
    Object.assign(home, saved && Array.isArray(saved.items) ? saved : firstHome(apps));
  })();
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
        await n.apps.launch(key);
        recent = [key, ...recent.filter((k) => k !== key)].slice(0, 30);
        n.store.set(RECENT, recent);
      },
    },
    usage: { recent: async (limit) => (await ready, recent.slice(0, limit)) },
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
