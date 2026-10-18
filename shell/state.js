/**
 * The shell's state, as signals: what changes re-renders only what reads it. Loaded from the host at start and kept
 * current by its events; the user's own (dock pins) goes back through powos.store.
 */
import { signal, computed } from "@preact/signals";
import { powos } from "./bridge.js";

export const apps = signal(/** @type {import('./bridge').App[]} */ ([]));
export const byKey = computed(() => new Map(apps.value.map((a) => [a.key, a])));
/** How many recent apps the strip shows. */
export const RECENT = 6;
export const recent = signal(/** @type {string[]} */ ([]));
/** Apps pinned to the drawer's dock, in pin order. */
export const dock = signal(/** @type {string[]} */ ([]));

/** The home screen (bridge.d.ts Home): pages of widgets, pinned apps and folders on a grid. */
export const home = signal(/** @type {import('./bridge').Home} */ ({ columns: 6, pages: [1], items: [] }));
/** The page on screen, an index into home.pages (the last, empty one included: see pages). */
export const page = signal(0);
/** Pages to show: the ones with items, and one empty page after them to drop things on. */
export const pages = computed(() => {
  const used = home.value.pages.length ? home.value.pages : [1];
  return [...used, Math.max(...used) + 1];
});
/** The selected tile (edit mode): it shows resize handles and its actions. */
export const selected = signal(/** @type {string | null} */ (null));
/**
 * Something carried by a finger (bridge-agnostic): an item being moved, or an app dragged out of the drawer.
 * x/y is the finger in the grid's coordinates; grab is where on the tile it holds it.
 */
export const carry = signal(/** @type {null | { item?: import('./bridge').HomeItem, app?: string, x: number, y: number, grab: {x: number, y: number} }} */ (null));
/** The open folder's key. */
export const folder = signal(/** @type {string | null} */ (null));

/** The drawer: 0 closed, 1 open; between while a finger drags it. */
export const drawer = signal(0);
export const query = signal("");

export async function load() {
  const [list, keys, pins, h] = await Promise.all([powos.apps.list(), powos.usage.recent(RECENT), powos.store.get("dock"), powos.home.get()]);
  home.value = h;
  apps.value = list;
  recent.value = keys;
  dock.value = Array.isArray(pins) ? pins : [];
}

// The host's list arrives after the page (it loads apps in the background): the recent strip, filtered to installed
// apps, follows it. Back on screen, the strip shows what was opened meanwhile.
powos.on("apps.changed", async () => {
  apps.value = await powos.apps.list();
  recent.value = await powos.usage.recent(RECENT);
});
powos.on("home.changed", async () => (home.value = await powos.home.get()));

document.addEventListener("visibilitychange", async () => {
  if (!document.hidden) recent.value = await powos.usage.recent(RECENT);
});

export async function launch(key) {
  await powos.apps.launch(key);
  drawer.value = 0;
  query.value = "";
  recent.value = await powos.usage.recent(RECENT);
}

export function setDocked(key, on) {
  const next = on ? [...dock.value.filter((k) => k !== key), key] : dock.value.filter((k) => k !== key);
  dock.value = next;
  powos.store.set("dock", next);
}
