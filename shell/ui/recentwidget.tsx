/**
 * The recent apps: a row of the apps opened lately, last first (not those pinned to the dock, at hand already).
 *
 * A home widget of its own (a "panel" home item, "recents": moved and resized as any other), added from the edit
 * bar's picker; by default the recent apps are the dock's second page (home.tsx Dock).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { AppCell } from "./apps.tsx";
import { byKey, dock, home, recent } from "../state.ts";
import type { Cell, HomeItem } from "../types.ts";

/** The recent apps not pinned to the dock, newest first. */
function recents() {
  const pinned = new Set(dock.value);
  return recent.value
    .filter((k) => !pinned.has(k))
    .map((k) => byKey.value.get(k))
    .filter((a) => a != null);
}

/** Six to a row's width, the rest a sideways scroll away; back at the newest whenever the list changes. */
export function RecentRow() {
  const row = useRef<HTMLDivElement>(null);
  const shown = recents();
  const first = shown[0]?.key;
  useEffect(() => {
    row.current?.scrollTo({ left: 0 });
  }, [first]);
  return (
    <div class="strip" ref={row}>
      {shown.map((app) => (
        <AppCell key={app.key} app={app} labels={false} draggable />
      ))}
    </div>
  );
}

/**
 * The widget's face fills its tile at every size (shell/dev/preview.sh checks it): the face measured, and the apps
 * laid out in the grid that fills it evenest (up to 2 apps a grid cell, so a big tile shows more, never a scroll).
 */
export function RecentsPanel({ item }: { item: HomeItem }) {
  const face = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<[number, number]>([0, 0]);
  useLayoutEffect(() => {
    const el = face.current;
    if (!el) return;
    const measure = () => setSize((s) => (s[0] === el.clientWidth && s[1] === el.clientHeight ? s : [el.clientWidth, el.clientHeight]));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const [W, H] = size;
  const all = recents();
  const cap = Math.max(1, (item.cell?.w ?? home.value.columns) * 2 * Math.max(1, item.cell?.h ?? 1));
  // Every count of apps and column count: the icons 0.8 of their cell's shorter side, and the empty margin that
  // leaves on each side of the tile. Of those with at most 11% empty on any side, the one with the most apps and the
  // biggest icons (apps^1.2 x icon: two more apps beat a little more size, not a row of specks); else the evenest.
  const worth = (k: number, icon: number) => Math.pow(k, 1.2) * icon;
  let best = { n: 1, c: 1, r: 1, icon: 0, gap: Infinity, ok: false };
  for (let k = 1; k <= Math.max(1, Math.min(all.length, cap)); k++)
    for (let c = 1; c <= k; c++) {
      // Full rows only (a lone app under a row reads as a mistake), unless it's every app there is.
      if (k % c !== 0 && k !== all.length) continue;
      const r = Math.ceil(k / c);
      const cw = W / c;
      const ch = H / r;
      const icon = 0.8 * Math.min(cw, ch);
      const gap = Math.max((cw - icon) / 2 / W, (ch - icon) / 2 / H);
      // Never specks: an icon at least 44 px (or 0.8 of the tile's shorter side, where that's less).
      const ok = gap <= 0.11 && icon >= Math.min(44, 0.8 * Math.min(W, H)) - 0.5;
      const better = ok ? !best.ok || worth(k, icon) > worth(best.n, best.icon) : !best.ok && gap < best.gap;
      if (better) best = { n: k, c, r, icon, gap, ok };
    }
  const n = Math.min(all.length, best.n);
  const icon = Math.max(24, Math.floor(best.icon));
  return (
    <div ref={face} class="tile recents-face fit" style={{ "--recent-c": best.c, "--recent-r": best.r, "--recent-icon": `${icon}px` }}>
      {W > 0 && (
        <div class="recents-grid">
          {all.slice(0, n).map((app) => (
            <AppCell key={app.key} app={app} labels={false} draggable />
          ))}
        </div>
      )}
    </div>
  );
}

export const hasRecentsWidget = () => home.value.items.some((i) => i.kind === "panel" && i.name === "recents");

const STORE = "recents-widget";
let migrating = false;

/** Where the widget goes: the lowest free full-width row of page [page], else the first free one-row spot anywhere. */
export function recentsSpot(page: number, rows: number): { page: number; cell: Cell } | null {
  const cols = home.value.columns;
  const taken = home.value.items
    .filter((i) => i.page === page && i.cell)
    .map((i) => (i.resizable ? i.cell! : { ...i.cell!, w: 1, h: 1 }));
  for (let y = rows - 1; y >= 0; y--) {
    const free = !taken.some((t) => t.y <= y && y < t.y + t.h);
    if (free) return { page, cell: { x: 0, y, w: cols, h: 1 } };
  }
  return null;
}

/**
 * Once per phone: the recent apps moved into the dock (its second page, home.tsx Dock), so the widget this placed by
 * itself at the bottom of the first page goes again - moved or resized by the user or not (nothing records which).
 * Added from the picker afterwards, it stays.
 */
export async function migrateRecents(rows: number) {
  if (migrating || rows <= 0) return;
  migrating = true;
  try {
    const was = (await powos.store.get(STORE)) as { placed?: number; dock?: number } | null;
    if (was?.dock) return;
    const it = home.value.items.find((i) => i.kind === "panel" && i.name === "recents");
    if (it && was?.placed) await powos.home.remove(it.key);
    await powos.store.set(STORE, { ...(was ?? {}), dock: Date.now() });
  } catch (e) {
    console.warn("recents widget: not migrated", e);
  } finally {
    migrating = false;
  }
}
