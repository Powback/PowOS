// Widget stacks' model (shell/ui/stackmodel.ts): node --test shell/test/stackmodel.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  addToStack, parseStacks, pruneStacks, removeFromStack, reorderStack, serializeStacks, showIndex, stackable, stackOf,
  stackOnto, stackTakesSwipe, stackView, swipeTarget, unstack, STACK_MAX, type StackItem, type Stacks,
} from "../ui/stackmodel.ts";

const w = (key: string, x: number, y = 0, extra: Partial<StackItem> = {}): StackItem => ({
  key, kind: "widget", page: 1, cell: { x, y, w: 3, h: 2 }, resizable: true, ...extra,
});

test("only boxed widgets stack: never apps, folders, the search bar, a pending tile", () => {
  assert.equal(stackable(w("a", 0)), true);
  assert.equal(stackable({ ...w("p", 0), kind: "panel", name: "agents" }), true);
  assert.equal(stackable({ ...w("aw", 0), kind: "appwidget" }), true);
  assert.equal(stackable({ ...w("s", 0), kind: "panel", name: "search" }), false);
  assert.equal(stackable({ ...w("a", 0), kind: "app", resizable: false }), false);
  assert.equal(stackable({ ...w("f", 0), kind: "folder", resizable: false }), false);
  assert.equal(stackable({ ...w("x", 0), pending: "Adding..." }), false);
  assert.equal(stackable({ ...w("x", 0), cell: null }), false);
});

test("create: a widget dropped on another makes a stack anchored at the target, the dropped one on top", () => {
  const r = stackOnto({}, "a", "b", "s1")!;
  assert.deepEqual(r.stacks, { s1: { keys: ["a", "b"], shown: 1, anchor: "a" } });
  assert.equal(stackOnto({}, "a", "a", "s1"), null);
});

test("add: onto a stack's member joins that stack; a stack dropped on a widget brings all its members", () => {
  let s: Stacks = stackOnto({}, "a", "b", "s1")!.stacks;
  s = stackOnto(s, "b", "c", "s2")!.stacks;
  assert.deepEqual(s, { s1: { keys: ["a", "b", "c"], shown: 2, anchor: "a" } });
  const merged = stackOnto(s, "d", "a", "s3")!;
  assert.deepEqual(merged.stacks, { s3: { keys: ["d", "a", "b", "c"], shown: 1, anchor: "d" } });
  assert.equal(stackOnto(s, "a", "c", "x"), null, "onto its own stack");
  const s2 = addToStack(s, "s1", "e")!;
  assert.deepEqual(s2.s1, { keys: ["a", "b", "c", "e"], shown: 3, anchor: "a" });
  assert.equal(addToStack(s2, "s1", "e"), null);
});

test("the stack holds at most STACK_MAX widgets", () => {
  let s: Stacks = {};
  for (let i = 1; i < STACK_MAX; i++) s = stackOnto(s, "k0", `k${i}`, "s")!.stacks;
  assert.equal(s.s.keys.length, STACK_MAX);
  assert.equal(stackOnto(s, "k0", "extra", "s"), null);
});

test("remove: down to one widget the stack dissolves; the anchor passes on; shown stays on the same widget", () => {
  let s: Stacks = { s: { keys: ["a", "b", "c"], shown: 2, anchor: "a" } };
  s = removeFromStack(s, "a");
  assert.deepEqual(s.s, { keys: ["b", "c"], shown: 1, anchor: "b" });
  s = removeFromStack(s, "c");
  assert.deepEqual(s, {});
  assert.equal(stackOf({ s: { keys: ["a", "b"], shown: 0, anchor: "a" } }, "b"), "s");
});

test("reorder keeps the same widget on top; unstack drops the stack; showIndex clamps", () => {
  const s: Stacks = { s: { keys: ["a", "b", "c"], shown: 0, anchor: "a" } };
  assert.deepEqual(reorderStack(s, "s", 0, 2).s, { keys: ["b", "c", "a"], shown: 2, anchor: "a" });
  assert.equal(reorderStack(s, "s", 0, 9), s);
  assert.deepEqual(unstack(s, "s"), {});
  assert.equal(showIndex(s, "s", 9).s.shown, 2);
  assert.equal(showIndex(s, "s", -3).s.shown, 0);
});

test("persist: round trip; no store / garbage / old layouts = no stacks; a key in two stacks stays in the first", () => {
  const s: Stacks = { s: { keys: ["a", "b"], shown: 1, anchor: "b" } };
  assert.deepEqual(parseStacks(JSON.parse(JSON.stringify(serializeStacks(s)))), s);
  assert.deepEqual(parseStacks(null), {});
  assert.deepEqual(parseStacks({ stacks: s }), {}, "no version");
  assert.deepEqual(parseStacks({ v: 1, stacks: { x: { keys: ["a"] }, y: "no", z: { keys: [1, 2] } } }), {});
  assert.deepEqual(parseStacks({ v: 1, stacks: { x: { keys: ["a", "b"], shown: 7 }, y: { keys: ["b", "c"] } } }), {
    x: { keys: ["a", "b"], shown: 1, anchor: "a" },
  });
});

test("prune: members that left home go; a stack left with one widget dissolves", () => {
  const s: Stacks = { s: { keys: ["a", "b", "c"], shown: 0, anchor: "a" }, t: { keys: ["d", "e"], shown: 0, anchor: "d" } };
  assert.deepEqual(pruneStacks(s, new Set(["a", "c", "d"])), { s: { keys: ["a", "c"], shown: 0, anchor: "a" } });
});

test("view: one tile per stack, the top member in the anchor's slot; others hidden; no stacks = the same array", () => {
  const items = [w("a", 0), w("b", 3, 4), w("c", 0, 4), w("x", 3)];
  assert.equal(stackView(items, {}), items);
  const v = stackView(items, { s: { keys: ["a", "b", "c"], shown: 1, anchor: "a" } });
  assert.deepEqual(v.map((i) => i.key), ["b", "x"]);
  assert.deepEqual(v[0].cell, items[0].cell);
  assert.equal(v[0].stack, "s");
  // the top member gone: the next present one shows; the anchor gone: members as they are
  assert.deepEqual(stackView([w("a", 0), w("c", 0)], { s: { keys: ["a", "b", "c"], shown: 1, anchor: "a" } }).map((i) => i.key), ["a"]);
  assert.deepEqual(stackView([w("b", 3), w("c", 0)], { s: { keys: ["a", "b", "c"], shown: 0, anchor: "a" } }).map((i) => i.key), ["b", "c"]);
});

test("gesture: the stack takes a swipe while there's a widget that way; at its ends home's pages get it", () => {
  assert.equal(stackTakesSwipe(0, 3, -20), true);
  assert.equal(stackTakesSwipe(0, 3, 20), false, "first widget, swipe right = home's previous page");
  assert.equal(stackTakesSwipe(2, 3, -20), false, "last widget, swipe left = home's next page");
  assert.equal(stackTakesSwipe(1, 3, 20), true);
  assert.equal(swipeTarget(0, 3, { dx: -150, width: 300, vx: -0.1 }), 1);
  assert.equal(swipeTarget(0, 3, { dx: -40, width: 300, vx: -0.1 }), 0, "short and slow springs back");
  assert.equal(swipeTarget(0, 3, { dx: -40, width: 300, vx: -0.8 }), 1, "a flick");
  assert.equal(swipeTarget(1, 3, { dx: 40, width: 300, vx: -0.8 }), 1, "flicked back against the drag: stays");
  assert.equal(swipeTarget(2, 3, { dx: -200, width: 300, vx: -1 }), 2);
});
