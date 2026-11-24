// The two screens' layouts kept as one, against a fake host (shell/hosts/flowsync.ts): node --test shell/test/flowsync.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { edited, flowSettled, migrate, resetFlow, wideView, type Ctx, type WideCell } from "../hosts/flowsync.ts";
import { overlaps } from "../hosts/reflow.ts";
import type { Bridge, Cell, Home, HomeItem } from "../types.ts";

const item = (key: string, page: number, [x, y, w = 1, h = 1]: number[]): HomeItem => ({ key, kind: w > 1 ? "widget" : "app", page, cell: { x, y, w, h }, resizable: w > 1, minSize: [1, 1], size: [w, h] });
const mockHome = (): Home => ({
  columns: 6,
  pages: [1, 2],
  items: [
    item("clock", 1, [0, 0, 6, 2]), item("weather", 1, [0, 2, 3, 2]), item("chrome", 1, [3, 2]), item("signal", 1, [4, 2]), item("spotify", 1, [5, 2]),
    item("monitor", 2, [0, 0, 4, 3]), item("glance", 2, [4, 0, 2, 3]), item("terminal", 2, [0, 3, 6, 4]),
  ],
});
/** The cells the first wide run gave (side by side: page 2 at x + 7). */
const sideBySide = (h: Home): Record<string, WideCell> =>
  Object.fromEntries(h.items.map((i) => [i.key, { ...i.cell!, x: i.cell!.x + (i.page === 2 ? 7 : 0), hp: i.page }]));

/** A fake host: the folded layout, a store, home.place as ShellHome.kt (no overlap check, pages from the items). */
function fake(home: Home, store: Record<string, unknown>) {
  const places: string[] = [];
  const n = {
    store: { get: async (k: string) => structuredClone(store[k] ?? null), set: async (k: string, v: unknown) => void (store[k] = structuredClone(v)) },
    home: {
      get: async () => structuredClone(home),
      place: async (key: string, cell: Cell, page: number) => {
        const it = home.items.find((i) => i.key === key)!;
        Object.assign(it, { cell, page });
        home.pages = [...new Set(home.items.map((i) => i.page))].sort((a, b) => a - b);
        places.push(key);
      },
    },
  } as unknown as Bridge;
  let cells: Record<string, WideCell> | null = null;
  const ctx: Ctx = {
    n,
    cells: async () => (cells ??= ((store["home.wide"] as Record<string, WideCell>) ?? {})),
    saveCells: () => void (store["home.wide"] = structuredClone(cells)),
  };
  return { ctx, places };
}
const flat = (h: Home) => h.items.map((i) => ({ key: i.key, page: i.page, cell: i.cell! }));

test("migration, edited unfolded: the folded layout follows the wide one; nothing lost, the wide screen unchanged", async () => {
  resetFlow();
  const home = mockHome();
  const wide = sideBySide(home);
  // The user's unfolded edit (old code: the wide cell moved, the host's layout didn't): terminal under weather, left half.
  wide.terminal = { x: 0, y: 4, w: 6, h: 4, hp: 2 };
  const store: Record<string, unknown> = { "home.wide": wide, "home.wide.backup": { at: 1, home: mockHome() } };
  const { ctx } = fake(home, store);
  await migrate(ctx, structuredClone(home));
  const t = home.items.find((i) => i.key === "terminal")!;
  assert.equal(t.page, 1, "terminal is on the left half unfolded: folded page 1");
  assert.deepEqual(t.cell, { x: 0, y: 4, w: 6, h: 4 });
  assert.equal(home.items.length, 8);
  assert.deepEqual(overlaps(flat(home)), []);
  const flow = store["home.flow"] as { pins: { wide: string[] } };
  assert.equal(flow.pins.wide.length, 8, "the whole wide layout is the user's: pinned");
  const after = store["home.wide"] as Record<string, WideCell>;
  for (const [k, c] of Object.entries(wide)) assert.deepEqual({ ...after[k], hp: 0 }, { ...c, hp: 0 }, `${k}'s wide cell kept`);
  assert.equal(after.terminal.hp, 1);
});

test("migration, nothing edited unfolded: the folded layout isn't touched", async () => {
  resetFlow();
  const home = mockHome();
  const { ctx, places } = fake(home, { "home.wide": sideBySide(home), "home.wide.backup": { at: 1, home: mockHome() } });
  await migrate(ctx, structuredClone(home));
  assert.deepEqual(places, []);
  assert.deepEqual(home, mockHome());
});

test("migration, edited on both: each item where it was edited (the wide edit wins for one edited on both)", async () => {
  resetFlow();
  const home = mockHome();
  const wide = sideBySide(home);
  wide.terminal = { x: 0, y: 4, w: 6, h: 4, hp: 2 };
  // Folded, after the first wide run: spotify moved down on page 1 (a folded edit).
  home.items.find((i) => i.key === "spotify")!.cell = { x: 5, y: 9, w: 1, h: 1 };
  const store: Record<string, unknown> = { "home.wide": wide, "home.wide.backup": { at: 1, home: mockHome() } };
  const { ctx } = fake(home, store);
  await migrate(ctx, structuredClone(home));
  assert.deepEqual(home.items.find((i) => i.key === "spotify")!.cell, { x: 5, y: 9, w: 1, h: 1 }, "spotify keeps its folded spot");
  assert.equal(home.items.find((i) => i.key === "terminal")!.page, 1);
  assert.deepEqual(overlaps(flat(home)), []);
});

test("an edit unfolded shows up folded; an edit folded shows up unfolded", async () => {
  resetFlow();
  const home = mockHome();
  const store: Record<string, unknown> = {};
  const { ctx } = fake(home, store);
  await migrate(ctx, structuredClone(home));
  const cells = await ctx.cells();
  Object.assign(cells, (await wideView(ctx.n, structuredClone(home), cells)).items.reduce((o, p) => ({ ...o, [p.key]: { ...p.cell, hp: home.items.find((i) => i.key === p.key)!.page } }), {}));
  // Unfolded: weather made 5x3 (wide.ts keeps the cell, then calls edited).
  cells.weather = { x: 0, y: 2, w: 5, h: 3, hp: 1 };
  cells.chrome = { x: 0, y: 5, w: 1, h: 1, hp: 1 };
  await edited(ctx, "wide", "weather");
  await flowSettled();
  assert.deepEqual(home.items.find((i) => i.key === "weather")!.cell, { x: 0, y: 2, w: 5, h: 3 });
  assert.deepEqual(overlaps(flat(home)), []);
  // Folded: glance moved to the foot of page 2; unfolded it goes there in the right half.
  home.items.find((i) => i.key === "glance")!.cell = { x: 0, y: 7, w: 2, h: 3 };
  await edited(ctx, "folded", "glance");
  await flowSettled();
  const w = store["home.wide"] as Record<string, WideCell>;
  assert.deepEqual(w.glance, { x: 7, y: 7, w: 2, h: 3, hp: 2 });
  assert.deepEqual(w.weather, { x: 0, y: 2, w: 5, h: 3, hp: 1 }, "weather was placed by hand unfolded: kept");
});
