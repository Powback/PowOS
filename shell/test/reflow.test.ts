// One home layout on two screens (shell/hosts/reflow.ts): node --test shell/test/reflow.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { byReading, foldedFromWide, halfOf, overlaps, pairsOf, wideFromFolded, type Placed } from "../hosts/reflow.ts";

const P = (key: string, page: number, [x, y, w = 1, h = 1]: number[]): Placed => ({ key, page, cell: { x, y, w, h } });
const at = (items: Placed[], key: string) => items.find((i) => i.key === key);
const keysOn = (items: Placed[], page: number) => items.filter((i) => i.page === page).sort(byReading).map((i) => i.key);

/** The shell's mock home (bridge.ts): page 1 clock 6x2, weather 3x2, three apps; page 2 monitor, glance, terminal. */
const folded: Placed[] = [
  P("clock", 1, [0, 0, 6, 2]), P("weather", 1, [0, 2, 3, 2]), P("chrome", 1, [3, 2]), P("signal", 1, [4, 2]), P("spotify", 1, [5, 2]),
  P("monitor", 2, [0, 0, 4, 3]), P("glance", 2, [4, 0, 2, 3]), P("terminal", 2, [0, 3, 6, 4]),
];
const pairs = [[1, 2]];
const fresh = () => wideFromFolded({ folded, pairs, cols: 6, wide: [], pins: new Set() });
const toFolded = (wide: Placed[], extra: Partial<Parameters<typeof foldedFromWide>[0]> = {}) =>
  foldedFromWide({ wide, pairs, cols: 6, rows: 10, folded, pins: new Set(), ...extra });
const move = (items: Placed[], key: string, cell: Partial<Placed["cell"]>) => items.map((i) => (i.key === key ? { ...i, cell: { ...i.cell, ...cell } } : i));

test("unfolded from folded: page 1 in the left half, page 2 in the right half, at their own spots", () => {
  const wide = fresh();
  assert.equal(wide.length, folded.length);
  assert.deepEqual(at(wide, "clock")!.cell, { x: 0, y: 0, w: 6, h: 2 });
  assert.deepEqual(at(wide, "terminal")!.cell, { x: 7, y: 3, w: 6, h: 4 });
  assert.ok(wide.every((w) => w.page === 1));
  assert.deepEqual(overlaps(wide), []);
});

test("round trip: folded -> unfolded -> folded changes nothing", () => {
  const back = toFolded(fresh());
  for (const f of folded) assert.deepEqual(at(back, f.key), f, f.key);
});

test("moved unfolded: the folded screen shows the same page and order (the user's 11-24 report)", () => {
  // Terminal (right half, page 2) dragged to the top of the left half: it is page 1's first tile now.
  const wide = move(fresh(), "terminal", { x: 0, y: 0 }).map((i) => (i.key === "clock" ? { ...i, cell: { ...i.cell, y: 4 } } : i));
  const wideNow = wide.map((i) => (["weather", "chrome", "signal", "spotify"].includes(i.key) ? { ...i, cell: { ...i.cell, y: i.cell.y + 4 } } : i));
  const f = toFolded(wideNow, { edited: new Set(["terminal"]) });
  assert.equal(at(f, "terminal")!.page, 1);
  assert.deepEqual(at(f, "terminal")!.cell, { x: 0, y: 0, w: 6, h: 4 });
  assert.deepEqual(keysOn(f, 1), ["terminal", "clock", "weather", "chrome", "signal", "spotify"]);
  assert.deepEqual(keysOn(f, 2), ["monitor", "glance"]);
  assert.deepEqual(overlaps(f), []);
});

test("resized unfolded: the folded tile has the new size, the tiles after it move on, in order", () => {
  const wide = move(fresh(), "weather", { w: 5, h: 3 });
  const f = toFolded(wide, { edited: new Set(["weather"]) });
  assert.deepEqual(at(f, "weather")!.cell, { x: 0, y: 2, w: 5, h: 3 });
  assert.deepEqual(keysOn(f, 1), ["clock", "weather", "chrome", "signal", "spotify"]);
  assert.deepEqual(overlaps(f), []);
  assert.equal(f.length, folded.length);
});

test("wider than the folded grid: as wide as it allows", () => {
  const wide = move(fresh(), "weather", { w: 10 });
  const f = toFolded(wide, { edited: new Set(["weather"]) });
  assert.equal(at(f, "weather")!.cell.w, 6);
  assert.deepEqual(overlaps(f), []);
});

test("an item that doesn't fit goes on to the next page, never dropped", () => {
  // Twelve 3x3 widgets in the left half of a 10-row folded page: 6 fit (2 a row, 3 rows), the rest go on.
  const many = Array.from({ length: 12 }, (_, i) => P(`w${i}`, 1, [(i % 2) * 3, Math.floor(i / 2) * 3, 3, 3]));
  const f = foldedFromWide({ wide: many, pairs: [[1, 2]], cols: 6, rows: 10, folded: [], pins: new Set() });
  assert.equal(f.length, 12);
  assert.deepEqual(keysOn(f, 1), ["w0", "w1", "w2", "w3", "w4", "w5"]);
  assert.deepEqual(keysOn(f, 2), ["w6", "w7", "w8", "w9", "w10", "w11"]);
  assert.deepEqual(overlaps(f), []);
});

test("past the pair's last page: a new page after all of them", () => {
  const many = Array.from({ length: 8 }, (_, i) => P(`w${i}`, 1, [0, i * 5, 6, 5]));
  const f = foldedFromWide({ wide: many, pairs: [[1]], cols: 6, rows: 10, folded: [], pins: new Set() });
  assert.equal(f.length, 8);
  assert.deepEqual([...new Set(f.map((i) => i.page))], [1, 2, 3, 4]);
});

test("a tile taller than a folded page still gets a page (no endless pages)", () => {
  const f = foldedFromWide({ wide: [P("tall", 1, [0, 0, 3, 14])], pairs: [[1]], cols: 6, rows: 10, folded: [], pins: new Set() });
  assert.deepEqual(f, [P("tall", 1, [0, 0, 3, 14])]);
});

test("right half of a wide page that shows one host page: a new host page", () => {
  const f = foldedFromWide({ wide: [P("a", 1, [0, 0, 2, 2]), P("b", 1, [8, 0, 2, 2])], pairs: [[3]], cols: 6, rows: 10, folded: [], pins: new Set() });
  assert.equal(at(f, "a")!.page, 3);
  assert.equal(at(f, "b")!.page, 4);
});

test("placed by hand folded (pinned): kept there when unfolded is edited; the edited item itself never is", () => {
  const pinnedFolded = folded.map((i) => (i.key === "spotify" ? { ...i, cell: { ...i.cell, y: 8 } } : i));
  const wide = move(fresh(), "weather", { w: 5, h: 3 });
  const f = foldedFromWide({ wide, pairs, cols: 6, rows: 10, folded: pinnedFolded, pins: new Set(["spotify", "weather"]), edited: new Set(["weather"]) });
  assert.deepEqual(at(f, "spotify")!.cell, { x: 5, y: 8, w: 1, h: 1 });
  assert.deepEqual(at(f, "weather")!.cell, { x: 0, y: 2, w: 5, h: 3 });
  assert.deepEqual(overlaps(f), []);
});

test("moved folded: the unfolded screen shows it there; pinned wide tiles stay where the user put them", () => {
  const wideNow = move(fresh(), "glance", { x: 11, y: 8 });
  // Folded, weather goes to the foot of page 2 (below terminal).
  const now = folded.map((i) => (i.key === "weather" ? { ...i, page: 2, cell: { ...i.cell, y: 7 } } : i));
  const w = wideFromFolded({ folded: now, pairs, cols: 6, wide: wideNow, pins: new Set(["glance"]) });
  assert.deepEqual(at(w, "weather")!.cell, { x: 7, y: 7, w: 3, h: 2 });
  assert.deepEqual(at(w, "glance")!.cell, { x: 11, y: 8, w: 2, h: 3 });
  assert.deepEqual(overlaps(w), []);
  assert.equal(halfOf(at(w, "weather")!.cell, 6), 1);
});

test("a widget stack is one tile: its members go where the anchor goes", () => {
  const withStack = [...fresh(), P("member", 1, [0, 0, 6, 2])];
  const f = foldedFromWide({ wide: move(withStack, "clock", { y: 9 }).map((i) => (i.key === "member" ? { ...i, cell: { ...i.cell, y: 9 } } : i)), pairs, cols: 6, rows: 12, folded, pins: new Set(), edited: new Set(["clock"]), follow: { member: "clock" } });
  assert.deepEqual(at(f, "member")!.cell, at(f, "clock")!.cell);
  assert.equal(at(f, "member")!.page, at(f, "clock")!.page);
});

test("pages pair up two by two", () => {
  assert.deepEqual(pairsOf([3, 1, 4]), [[1, 3], [4]]);
  assert.deepEqual(pairsOf([]), [[1]]);
});
