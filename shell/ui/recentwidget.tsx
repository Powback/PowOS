/**
 * The recent apps: a row of the apps opened lately, last first (not those pinned to the dock, at hand already).
 *
 * A home widget of its own (a "panel" home item, "recents": moved and resized as any other), added from the edit
 * bar's picker; by default the recent apps are the dock's second page (home.tsx Dock).
 */
import { useEffect, useRef } from "preact/hooks";
import { powos } from "../bridge.ts";
import { AppCell } from "./apps.tsx";
import { byKey, dock, home, recent } from "../state.ts";
import type { Cell, HomeItem } from "../types.ts";

/** Six to a row's width, the rest a sideways scroll away; back at the newest whenever the list changes. */
export function RecentRow() {
  const row = useRef<HTMLDivElement>(null);
  const pinned = new Set(dock.value);
  const shown = recent.value
    .filter((k) => !pinned.has(k))
    .map((k) => byKey.value.get(k))
    .filter((a) => a != null);
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

/** The widget's face: as many apps to a row as its width holds (6 on a full-width one), as many rows as it's tall. */
export function RecentsPanel({ item }: { item: HomeItem }) {
  const w = item.cell?.w ?? home.value.columns;
  const h = item.cell?.h ?? 1;
  const n = Math.max(2, Math.min(8, Math.round((w * 6) / home.value.columns)));
  return (
    <div class={`tile recents-face ${h > 1 ? "rows" : ""}`} style={{ "--recent-n": n, "--recent-rows": h }}>
      <RecentRow />
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
