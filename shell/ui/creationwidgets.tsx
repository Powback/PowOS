/**
 * A composed widget's placeholder on home (docs/COMPOSER.md; `powos compose widget` runs lib/apps/powos-compose,
 * which writes its progress into powos-registry's `creation` tables - apps/registry.ts watchCreations). The moment a
 * running "widget:" creation is seen, it gets a spot (placeNewCells, the registry's default widget size) and shows
 * a skeleton tile there (ui/pending.tsx SkeletonWidgetTile) client-side only - never through the host's layout, so
 * nothing is lost if the build never finishes. The moment it's done, the real widget is placed at THAT SAME spot
 * (ui/apppicker.tsx's addIsland does the general case; this pins the cell instead of picking a free one) and the
 * placeholder's entry disappears in the same tick - no jump. A failure keeps the tile (Discard clears it; there is
 * no page-side Retry yet for widgets - that needs a native "build this again" call, same as apps have via
 * `powos.ai.newApp`, which widgets don't have).
 */
import { computed, effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { creationRows, watchCreations, type RegistryCreation, type RegistryCreationLog, type RegistryCreationStep } from "../apps/registry.ts";
import type { Cell, HomeItem } from "../types.ts";
import type { PendingState, PendingStep } from "./pending.tsx";
import { placeNewCells } from "./grid.tsx";

export { watchCreations };

export const CREATION_PREFIX = "creation:";
const DEFAULT_SIZE: [number, number] = [4, 2];

/** This creation's id, from a home item's key ("creation:widget:foo-abcdef" -> "widget:foo-abcdef"). */
export const creationIdOf = (key: string) => (key.startsWith(CREATION_PREFIX) ? key.slice(CREATION_PREFIX.length) : null);

function toPendingState(c: RegistryCreation, steps: RegistryCreationStep[], logs: RegistryCreationLog[]): PendingState {
  const mine = steps.filter((s) => s.creationId === c.id).sort((a, b) => a.idx - b.idx);
  const ps: PendingStep[] = mine.map((s) => ({ label: s.label, state: s.state as PendingStep["state"] }));
  const log = logs
    .filter((l) => l.creationId === c.id)
    .sort((a, b) => Number(a.id - b.id))
    .map((l) => l.line);
  return { id: c.id, kind: c.kind, title: c.title, status: c.status as PendingState["status"], steps: ps, log, error: c.error || null, resultId: c.appId || null };
}

/** Where each running widget creation reserved its spot (persists for the session; lost if the shell reloads mid-build). */
const reserved = signal<Record<string, { page: number; cell: Cell }>>({});
/** Creations we've already placed the real widget for (so the effect, which can re-run, never calls addPanel twice). */
const placed = new Set<string>();

/** A newly-seen running widget creation gets a spot, once. */
function reserveIfNew(c: RegistryCreation) {
  if (c.status !== "running" || reserved.value[c.id]) return;
  const [w, h] = DEFAULT_SIZE;
  reserved.value = { ...reserved.value, [c.id]: placeNewCells(w, h) };
}

/** A finished widget creation's real widget goes to its reserved spot, once, then the reservation is dropped. */
function placeIfDone(c: RegistryCreation) {
  if (c.status !== "done" || !reserved.value[c.id] || placed.has(c.id)) return;
  placed.add(c.id);
  const spot = reserved.value[c.id];
  if (c.appId) powos.home.addPanel(`app:${c.appId}`, spot.page, spot.cell).catch(() => {});
  const next = { ...reserved.value };
  delete next[c.id];
  reserved.value = next;
}

/**
 * Reserves a spot for every newly-seen running widget creation, and places the real widget (then drops the
 * reservation) the moment one finishes. Side effects live here, once, reacting to the live rows - rendering below
 * stays a pure read of `reserved`.
 */
effect(() => {
  for (const c of creationRows.value.creations) {
    if (c.kind !== "widget") continue;
    reserveIfNew(c);
    placeIfDone(c);
  }
});

/** Where a running widget creation reserved its spot, if any (shell/dev/gate.mjs: proving the swap lands on it exactly). */
export const reservedSpotFor = (id: string) => reserved.value[id] ?? null;

/** Discards a failed widget's placeholder: the registry row is left for a human to clean up, the tile just stops showing. */
export function discardWidgetCreation(id: string) {
  if (!reserved.value[id]) return;
  const next = { ...reserved.value };
  delete next[id];
  reserved.value = next;
  placed.delete(id);
}

/** Every running/failed widget creation that has a spot, as home items plus its progress by creation id. */
export const creationWidgets = computed<{ byId: Map<string, PendingState>; items: HomeItem[] }>(() => {
  const { creations, steps, logs } = creationRows.value;
  const byId = new Map<string, PendingState>();
  const items: HomeItem[] = [];
  for (const c of creations) {
    if (c.kind !== "widget" || c.status === "done") continue;
    const spot = reserved.value[c.id];
    if (!spot) continue; // never seen running here (e.g. the shell reloaded mid-build): nothing to anchor a tile to
    byId.set(c.id, toPendingState(c, steps, logs));
    items.push({
      key: `${CREATION_PREFIX}${c.id}`,
      kind: "panel",
      name: "creation",
      page: spot.page,
      cell: spot.cell,
      resizable: false,
      minSize: DEFAULT_SIZE,
      size: DEFAULT_SIZE,
    });
  }
  return { byId, items };
});
