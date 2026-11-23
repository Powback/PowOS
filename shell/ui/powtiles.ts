/**
 * The Pow folder and the .pow web apps on home (the user, 11-23: "the pow apps should be in a pow folder"). Home's grid
 * is the host's: ShellHome.kt pins Android and Linux shortcuts only, so the Pow folder and a single .pow app pinned out
 * of it are shell tiles - panels the host keeps by name (ShellPanels.kt "pow", "w:<host>"; key "panel:<name>") - that
 * the page draws and handles as app cells: [asAppTile] turns them into app items (stacks.tsx homeView), so a tap opens
 * them, a hold carries them to the dock and back, the edit menu removes them, as any app tile.
 *
 * A .pow app's tile shows while the app is in the folder (the catalog sync can remove it): one the sync dropped is
 * hidden, never deleted, so it's back in its place if it returns. The Pow folder's: while there are .pow apps.
 */
import { powos } from "../bridge.ts";
import type { Cell, HomeItem } from "../types.ts";
import { isPowApp, POW_FOLDER } from "./launcherview.ts";

/** The Pow folder's panel name on home (ShellPanels.kt). */
export const POW_PANEL = "pow";

/** The launcher key a home panel stands for: the Pow folder's, a .pow app's; null for every other item. */
export function appOfPanel(i: HomeItem): string | null {
  if (i.kind !== "panel" || !i.name) return null;
  if (i.name === POW_PANEL) return POW_FOLDER;
  return isPowApp({ key: i.name }) ? i.name : null;
}

/** A launcher key that goes on home as a shell tile (the Pow folder, a .pow app): its panel name, else null. */
export const panelOfApp = (app: string) => (app === POW_FOLDER ? POW_PANEL : isPowApp({ key: app }) ? app : null);

/** A home item that is a shell tile (its key "panel:..."): never grouped into a host folder. */
export const isShellTile = (i: HomeItem) => i.key.startsWith("panel:");

// One app item per panel item: the grid's page cache compares items by identity.
const tiles = new WeakMap<HomeItem, HomeItem>();

/** [i] as the app tile it is (an app cell, 1x1), or [i] itself when it isn't one of these. */
export function asAppTile(i: HomeItem): HomeItem {
  const app = appOfPanel(i);
  if (!app) return i;
  let t = tiles.get(i);
  if (!t) {
    t = { ...i, kind: "app", app, resizable: false, minSize: [1, 1], size: [1, 1], cell: i.cell && { ...i.cell, w: 1, h: 1 } };
    tiles.set(i, t);
  }
  return t;
}

/**
 * Home's items with the shell tiles as app tiles, those whose app isn't there now ([known]) left out. The same array
 * when there are none (nothing re-renders).
 */
export function withAppTiles(items: HomeItem[], known: (app: string) => boolean): HomeItem[] {
  if (!items.some(appOfPanel)) return items;
  return items.map(asAppTile).filter((i) => i.kind !== "app" || !isShellTile(i) || known(i.app!));
}

/**
 * Pins [app] on home at [cell] of [page]: an Android or Linux app as the host's shortcut, the Pow folder or a .pow app
 * as its shell tile - at [cell], else the first free spot on the page in view (placeNewCells).
 */
export async function addToHome(app: string, page: number, cell?: Cell | null): Promise<string> {
  const panel = panelOfApp(app);
  if (!panel) return powos.home.add(app, page, cell ?? undefined);
  if (cell) return powos.home.addPanel(panel, page, { ...cell, w: 1, h: 1 });
  const { placeNewCells } = await import("./grid.tsx");
  const spot = placeNewCells(1, 1);
  return powos.home.addPanel(panel, spot.page, spot.cell);
}
