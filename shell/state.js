/**
 * The shell's state, as signals: what changes re-renders only what reads it. Loaded from the host at start and kept
 * current by its events; the user's own (dock pins) goes back through powos.store.
 */
import { signal, computed } from "@preact/signals";
import { powos } from "./bridge.js";

export const apps = signal(/** @type {import('./bridge').App[]} */ ([]));
export const byKey = computed(() => new Map(apps.value.map((a) => [a.key, a])));
export const recent = signal(/** @type {string[]} */ ([]));
/** Apps pinned to the drawer's dock, in pin order. */
export const dock = signal(/** @type {string[]} */ ([]));

/** The drawer: 0 closed, 1 open; between while a finger drags it. */
export const drawer = signal(0);
export const query = signal("");

export async function load() {
  const [list, keys, pins] = await Promise.all([powos.apps.list(), powos.usage.recent(5), powos.store.get("dock")]);
  apps.value = list;
  recent.value = keys;
  dock.value = Array.isArray(pins) ? pins : [];
}

powos.on("apps.changed", async () => (apps.value = await powos.apps.list()));

export async function launch(key) {
  await powos.apps.launch(key);
  drawer.value = 0;
  query.value = "";
  recent.value = await powos.usage.recent(5);
}

export function setDocked(key, on) {
  const next = on ? [...dock.value.filter((k) => k !== key), key] : dock.value.filter((k) => k !== key);
  dock.value = next;
  powos.store.set("dock", next);
}
