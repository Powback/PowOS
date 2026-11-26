// The switcher's card gestures (shell/ui/carddock.ts): node --test shell/test/carddock.test.ts
// A plain push up is still the removal; the finger at a screen edge (home's window-docking rule) docks into Open
// Canvas on that half; a dock drag let go anywhere else goes back. The second app is the user's pick, never chosen here.
import { test } from "node:test";
import assert from "node:assert/strict";
import { canSide, cardRelease, dockable, docking, dockSide, halfRect, otherSide, DOCK_EDGE_PX } from "../ui/carddock.ts";

// The unfolded inner screen (CSS px) and a card on it; the card starts in the middle.
const W = 821;
const H = 883;
const CARD = 520;
const at = (x: number, y: number, more: object = {}) => ({ dx: x - W / 2, dy: y - H / 2, x, y, cardH: CARD, screenW: W, screenH: H, ...more });

test("straight up past REMOVE: removed, as before (with or without Open Canvas)", () => {
  for (const can of [true, false]) assert.deepEqual(cardRelease(at(W / 2, H / 2 - 0.5 * CARD), 0, can), { kind: "remove" });
});

test("flicked up mid-screen: removed, as before", () => {
  assert.deepEqual(cardRelease(at(W / 2 + 10, H / 2 - 60), -0.9, true), { kind: "remove" });
});

test("a short push up: springs back, as before", () => {
  assert.deepEqual(cardRelease(at(W / 2, H / 2 - 0.2 * CARD), 0.1, true), { kind: "back" });
});

test("the finger at the left / right edge: that half (home's edge rule), wherever it is up or down", () => {
  assert.equal(dockSide(at(10, 400)), "left");
  assert.equal(dockSide(at(W - 10, 700)), "right");
  assert.deepEqual(cardRelease(at(10, 400), 0, true), { kind: "dock", side: "left" });
  // Flicked while at the edge: the half was shown under the finger, so it docks.
  assert.deepEqual(cardRelease(at(W - 5, 300), -1.2, true), { kind: "dock", side: "right" });
});

test("top / bottom only where the canvas stacks (the host's tasks.canvasVertical)", () => {
  assert.equal(dockSide(at(W / 2, 10)), null);
  assert.equal(dockSide(at(W / 2, 10, { vertical: true })), "top");
  assert.equal(dockSide(at(W / 2, H - 10, { vertical: true })), "bottom");
});

test("a corner: the nearer edge", () => {
  assert.equal(dockSide(at(30, 5, { vertical: true })), "top");
  assert.equal(dockSide(at(5, 30, { vertical: true })), "left");
});

test("the finger short of the edge band: no target", () => {
  assert.equal(dockSide(at(DOCK_EDGE_PX + 30, 400)), null);
});

test("a dock drag let go outside a target goes back - a clean cancel, never a removal", () => {
  // Carried well sideways (a dock drag), then let go mid-screen and high up: back, not removed.
  const d = at(W / 2 - 200, H / 2 - 0.6 * CARD);
  assert.equal(docking(d), true);
  assert.deepEqual(cardRelease(d, -0.2, true), { kind: "back" });
  // It lit a half before (docking), then came back to the middle: back.
  assert.deepEqual(cardRelease(at(W / 2, 200, { docking: true }), -1, true), { kind: "back" });
});

test("no Open Canvas (folded, unsupported, older APK): the same drag is the old rule", () => {
  assert.deepEqual(cardRelease(at(10, H / 2 - 0.5 * CARD), 0, false), { kind: "remove" });
  assert.deepEqual(cardRelease(at(10, H / 2 - 0.2 * CARD), 0.1, false), { kind: "back" });
});

test("halves: the canvas's two sides with its gap, the picker opposite", () => {
  assert.deepEqual(halfRect("left", 808, 600), { x: 0, y: 0, w: 400, h: 600 });
  assert.deepEqual(halfRect("right", 808, 600), { x: 408, y: 0, w: 400, h: 600 });
  assert.deepEqual(halfRect("bottom", 800, 608), { x: 0, y: 308, w: 800, h: 300 });
  assert.equal(otherSide("top"), "bottom");
  assert.equal(otherSide("left"), "right");
});

// The phone's list as tasks.list gave it on 11-23: PowOS's lock face (no key), Linux windows ("l:", PowOS tasks),
// Settings (on OxygenOS's split blocklist).
const phone = [
  { id: 3986, key: "a:com.android.chrome/com.google.android.apps.chrome.Main" },
  { id: 3987, key: null },
  { id: 3982, key: "l:systemsettings" },
  { id: 3974, key: "a:com.android.settings/.Settings" },
  { id: 3938, key: "a:com.powterm/.MainActivity" },
];

test("canSide without the host's list: never the lock face (no key), a Linux window (l:), a PowOS app or a split", () => {
  assert.equal(canSide(phone[1], null), false);
  assert.equal(canSide(phone[2], null), false);
  assert.equal(canSide(phone[0], null), true);
  assert.equal(canSide({ id: -2, key: "p:notes" }, null), false);
  assert.equal(canSide({ id: 4, key: "a:x", split: [{}, {}] }, null), false);
});

test("dockable: the host's list (tasks.canvasSides) is the truth for the dragged app", () => {
  const sides = new Set([3986, 3938]);
  assert.equal(dockable(phone, 3986, sides), true);
  assert.equal(dockable(phone, 3974, sides), false);
  assert.equal(dockable(phone, 3982, null), false);
  assert.equal(dockable(phone, 1, sides), false);
});
