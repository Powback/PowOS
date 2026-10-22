/**
 * Home's layout kept in the page (Bridge.home over one Home object): for hosts that have no layout engine of their own
 * - the desktop host (hosts/desktop.ts, kept in its store) and the browser's mock (bridge.ts). The phone's is native
 * (ShellHome.kt); this does what it does: place, add, remove, group into folders, the first free spot for new items.
 */
import type { App, Bridge, Cell, Home } from "../types.ts";

/** [changed]: after every change to [home] (pages recounted here) - save it, tell the page ("home.changed"). */
export function homeLayout(home: Home, changed: () => void, apps: () => App[]): Bridge["home"] {
  const done = () => {
    home.pages = [...new Set(home.items.map((i) => i.page))].sort((a, b) => a - b);
    changed();
  };
  /** A folder of fewer than two apps goes away: the app left takes its place. */
  const tidy = () => {
    for (const f of home.items.filter((i) => i.kind === "folder" && i.apps!.length < 2)) {
      const rest = f.apps![0];
      home.items = home.items.filter((i) => i !== f);
      if (rest) home.items.push({ key: rest.key, kind: "app", page: f.page, cell: f.cell, resizable: false, minSize: [1, 1], size: [1, 1], label: rest.label, app: rest.app });
    }
  };
  return {
    get: async () => structuredClone(home),
    place: async (key: string, cell: Cell, page: number) => {
      const item = home.items.find((i) => i.key === key);
      if (!item) return;
      Object.assign(item, { cell, page });
      done();
    },
    add: async (app, page, cell) => {
      const a = apps().find((x) => x.key === app);
      if (!a) throw new Error(`no such app: ${app}`);
      const key = (a.kind === "linux" ? "linux:" : "app:") + a.key.slice(2);
      home.items = home.items.filter((i) => i.key !== key);
      // Out of its folder, if it was in one (a folder left with one app goes away, as ShellHome's tidy).
      for (const f of home.items.filter((i) => i.kind === "folder")) f.apps = f.apps!.filter((x) => x.key !== key);
      tidy();
      home.items.push({ key, kind: "app", page, cell: cell ?? null, resizable: false, minSize: [1, 1], size: [1, 1], label: a.label, app });
      done();
      return key;
    },
    remove: async (key) => {
      home.items = home.items.filter((i) => i.key !== key);
      done();
    },
    addPanel: async (name, page, cell) => {
      const key = `panel:${name}`;
      home.items = home.items.filter((i) => i.key !== key);
      home.items.push({ key, kind: "panel", name, page, cell, resizable: true, minSize: [2, 1], size: [4, 2] });
      done();
      return key;
    },
    // As WidgetLayout.place: the first free spot at the item's size, on its page.
    arrange: async (cols, rows) => {
      let moved = false;
      for (const item of home.items.filter((i) => !i.cell)) {
        const [w, h] = item.size ?? [Math.floor(cols / 2), 3];
        const taken = home.items.filter((o) => o !== item && o.page === item.page && o.cell).map((o) => o.cell!);
        for (let y = 0; y + h <= rows && !item.cell; y++)
          for (let x = 0; x + w <= cols && !item.cell; x++)
            if (taken.every((c) => x >= c.x + c.w || c.x >= x + w || y >= c.y + c.h || c.y >= y + h)) item.cell = { x, y, w, h };
        moved ||= !!item.cell;
      }
      if (moved) done();
    },
    group: async (key, target) => {
      const item = home.items.find((i) => i.key === key);
      const into = home.items.find((i) => i.key === target);
      if (!item || !into || item.kind !== "app") return null;
      home.items = home.items.filter((i) => i.key !== key);
      const entry = { key: item.key, label: item.label!, app: item.app! };
      let folder = into.key;
      if (into.kind === "folder") into.apps!.push(entry);
      else {
        folder = "folder:" + Date.now().toString(36) + Math.floor(Math.random() * 1e4);
        home.items = home.items.filter((i) => i.key !== target);
        home.items.push({ ...into, key: folder, kind: "folder", apps: [{ key: into.key, label: into.label!, app: into.app! }, entry] });
      }
      done();
      return folder;
    },
  };
}
