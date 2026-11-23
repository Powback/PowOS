// The switcher's card gestures (shell/ui/carddock.ts): node --test shell/test/carddock.test.ts
// Every existing card gesture keeps its result; only a clear up-and-to-a-side drag docks into Open Canvas.
import { test } from "node:test";
import assert from "node:assert/strict";
import { cardRelease, dockPartner, dockPick, dockSide } from "../ui/carddock.ts";

// The unfolded inner screen (CSS px) and a card on it; the card starts in the middle.
const W = 900;
const H = 560;
const mid = W / 2;
const drag = (dx: number, dy: number, from = mid) => ({ dx, dy, x: from + dx, cardH: H, screenW: W });

test("straight up past REMOVE: removed, as before (with or without Open Canvas)", () => {
  for (const can of [true, false]) assert.deepEqual(cardRelease(drag(0, -0.5 * H), 0, can), { kind: "remove" });
});

test("flicked up: removed, as before", () => {
  assert.deepEqual(cardRelease(drag(10, -60), -0.9, true), { kind: "remove" });
});

test("a short push up: springs back, as before", () => {
  assert.deepEqual(cardRelease(drag(0, -0.2 * H), 0.1, true), { kind: "back" });
});

test("up with a little sideways drift (mostly vertical): still a removal, never a dock", () => {
  assert.equal(dockSide(drag(-80, -0.6 * H)), null);
  assert.deepEqual(cardRelease(drag(-80, -0.6 * H), -0.2, true), { kind: "remove" });
});

test("up and toward the left edge: docks left; toward the right edge: docks right", () => {
  assert.equal(dockSide(drag(-330, -0.3 * H)), "left");
  assert.equal(dockSide(drag(330, -0.3 * H)), "right");
  assert.deepEqual(cardRelease(drag(-330, -0.3 * H), 0, true), { kind: "dock", side: "left" });
  // Flicked while in the zone: the half was shown under the finger, so it docks.
  assert.deepEqual(cardRelease(drag(330, -0.3 * H), -1.2, true), { kind: "dock", side: "right" });
});

test("no Open Canvas (folded, unsupported, older APK): the same drag is the old rule", () => {
  assert.deepEqual(cardRelease(drag(-330, -0.5 * H), 0, false), { kind: "remove" });
  assert.deepEqual(cardRelease(drag(-330, -0.2 * H), 0, false), { kind: "back" });
});

test("sideways without going up: never a dock (the row's scroll owns sideways starts anyway)", () => {
  assert.equal(dockSide(drag(-400, -10)), null);
});

test("finger still in the middle of the screen: no dock zone yet", () => {
  // A card at the right edge dragged left 200 px ends up mid-screen: not the left half's zone.
  assert.equal(dockSide(drag(-200, -0.3 * H, 750)), null);
});

test("the zone needs the finger on that side, not just travel toward it", () => {
  // A card at the far left moved further left: left zone; the same move from the far right isn't the right zone.
  assert.equal(dockSide(drag(-140, -0.25 * H, 300)), "left");
  assert.equal(dockSide(drag(-140, -0.25 * H, 850)), null);
});

test("partner: the newest other single Android app, never a split card, a PowOS app, or home", () => {
  const list = [
    { id: 7, key: "a:com.android.settings" },
    { id: -2, key: "p:notes" },
    { id: 9, key: "com.powos.app/home" },
    { id: 4, key: "a:x", split: [{}, {}] },
    { id: 3, key: "a:com.coloros.filemanager" },
  ];
  assert.equal(dockPartner(list, 7), 3);
  assert.equal(dockPartner(list, 3), 7);
  assert.equal(dockPartner([{ id: 7, key: "a:s" }], 7), null);
});

// The phone's list as tasks.list gave it on 11-23 (the user's failed dock): PowOS's lock face (no key), Linux windows
// ("l:", PowOS tasks), Settings (on OxygenOS's split blocklist). The old rule (key starts with "com.powos.app") matched
// none of these keys, so the lock face was picked as the partner and the host refused it.
const phone = [
  { id: 3986, key: "a:com.android.chrome/com.google.android.apps.chrome.Main" },
  { id: 3987, key: null },
  { id: 3982, key: "l:systemsettings" },
  { id: 3974, key: "a:com.android.settings/.Settings" },
  { id: 3938, key: "a:com.powterm/.MainActivity" },
];

test("partner without the host's list: never the lock face (no key) or a Linux window (l:)", () => {
  assert.equal(dockPartner(phone, 3986), 3974);
});

test("partner with the host's list (tasks.canvasSides): only apps OxygenOS lets into split view", () => {
  assert.equal(dockPartner(phone, 3986, new Set([3986, 3938])), 3938);
});

test("dockPick: a blocked dragged app or no partner is a reason, never a silent no-op", () => {
  const sides = new Set([3986, 3938]);
  assert.deepEqual(dockPick(phone, 3986, sides), { other: 3938 });
  assert.deepEqual(dockPick(phone, 3974, sides), { why: "dragged" });
  assert.deepEqual(dockPick(phone, 3986, new Set([3986])), { why: "partner" });
  assert.deepEqual(dockPick(phone, 3982, null), { why: "dragged" });
});
