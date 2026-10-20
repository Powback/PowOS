/**
 * The recent apps: a row of the apps opened lately, last first (not those pinned to the dock, at hand already).
 *
 * A home widget of its own (a "panel" home item, "recents": moved and resized as any other), placed once by default
 * where the hard-wired row used to be - the bottom row of home's first page, full width, over the search bar. While
 * it's on home the launcher has no head of its own (shell.css .home.recents-widget); a host that can't keep it
 * (before ShellPanels knew "recents") keeps the old row heading the launcher.
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
/**
 * Just placed: its row was the grid's last with the launcher's head still there; without it the grid can gain a row,
 * and the widget is moved down onto the new last one once the grid has measured again.
 */
let settle = false;

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
 * Once per phone: the old row becomes the widget, at its default spot (a layout from before it, so it shows where the
 * row was). Not again after that - removed from home, it stays removed (the edit sheet brings it back).
 */
export async function migrateRecents(rows: number) {
  if (settle && rows > 0) {
    const it = home.value.items.find((i) => i.kind === "panel" && i.name === "recents");
    if (it?.cell) {
      settle = false;
      const c = it.cell;
      const below = home.value.items.some((i) => i !== it && i.page === it.page && i.cell && i.cell.y + i.cell.h > c.y + c.h);
      if (c.y + c.h < rows && !below) await powos.home.place(it.key, { ...c, y: rows - c.h }, it.page).catch(() => {});
    }
    return;
  }
  if (migrating || rows <= 0 || hasRecentsWidget()) return;
  migrating = true;
  try {
    if (await powos.store.get(STORE)) return;
    const first = home.value.pages.length ? Math.min(...home.value.pages) : 1;
    const spot = recentsSpot(first, rows) ?? recentsSpot(Math.max(first, ...home.value.pages) + 1, rows);
    if (!spot) return;
    await powos.home.addPanel("recents", spot.page, spot.cell);
    await powos.store.set(STORE, { placed: Date.now() });
    settle = true;
    // Only right after placing it: a later re-measure (a fold) leaves it where it is.
    setTimeout(() => (settle = false), 5000);
  } catch (e) {
    // A host without the "recents" panel (an older APK): the launcher keeps its row.
    console.warn("recents widget: not placed", e);
  } finally {
    migrating = false;
  }
}
