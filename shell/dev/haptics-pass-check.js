/**
 * haptics-everywhere (board task haptics-everywhere-in-the-shell): the shell's commit points tick as stock's / iOS's do
 * (ui/haptics.ts; docs/DESIGN-LANGUAGE.md §7). In the page, for gate.mjs's haptics-pass scenes: each export drives one
 * interaction through its real handler and returns its fails; the mock host counts the bridge calls
 * (bridge.ts window.__hapticsMock). Home's scene (haptics-pass) runs setup, liftAndZones, editEnter, edgeBounce,
 * lockShortcut; the shade's (haptics-pass-shade) controlCenter, shadePull. The switcher's split zones are asserted in
 * switcher-canvas-drag (gate.mjs), the launcher's pull in launcher-haptics, page changes staying silent in
 * page-swipe-no-haptic.
 */
const G = () => window.__gw;
const mod = (p) => G().mod(p);
const count = () => window.__hapticsMock.tick + window.__hapticsMock.confirm;
const center = (el) => {
  const r = el.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
};
const ptr = (type, at, id = 41) =>
  new PointerEvent(type, { pointerId: id, pointerType: "touch", isPrimary: true, bubbles: true, cancelable: true, button: 0, buttons: type === "pointerup" ? 0 : 1, clientX: at.x, clientY: at.y });
const tiles = () => [...document.querySelectorAll(".page:not(.away) .home-tile")];
/** [what] gave [n] haptics since [t0], want [want]: a fail or nothing. */
const want = (what, t0, n) => (count() - t0 === n ? [] : [`${what}: ${count() - t0} haptics, want ${n}`]);
const atLeastOne = (what, t0) => (count() > t0 ? [] : [`${what}: no haptic`]);

/** Two apps on home's first page, nothing else; home shown, not editing, no panel. */
export async function setup() {
  if (!window.__hapticsMock) return ["no mock haptics (bridge.ts window.__hapticsMock)"];
  const S = await mod("./state.ts");
  const { powos } = await mod("./bridge.ts");
  const h = await powos.home.get();
  for (const i of h.items) await powos.home.remove(i.key);
  const pg = h.pages[0] ?? 1;
  await powos.home.add("a:signal", pg, { x: 0, y: 0, w: 1, h: 1 });
  await powos.home.add("a:spotify", pg, { x: 2, y: 0, w: 1, h: 1 });
  S.editing.value = false;
  S.notif.value = false;
  S.page.value = 0;
  await G().until(() => tiles().length === 2 && G().still());
  await G().frames(2);
  return tiles().length === 2 ? [] : [`setup: ${tiles().length} home tiles, want 2`];
}

const move = async (p) => (window.dispatchEvent(ptr("pointermove", p)), await G().frames(2));

/** Carried onto [el]: one tick as its zone snaps in, none moving a little inside it. */
async function snapInto(what, p) {
  const t0 = count();
  await move(p);
  const fails = atLeastOne(`${what} snapping in under the finger`, t0);
  const t1 = count();
  await move({ x: p.x + 2, y: p.y + 1 });
  return [...fails, ...want(`${what}, held inside it`, t1, 0)];
}

/**
 * Long-press lift (grid.tsx liftTile) ticks and enters edit mode; carried over the other app the folder zone snaps in
 * (grid.tsx joinSnap: a tick), over the dock the dock's zone (dockdrop.ts hoverDock: a tick).
 */
export async function liftAndZones() {
  const S = await mod("./state.ts");
  const [from, to] = tiles();
  const at = center(from);
  const t0 = count();
  from.dispatchEvent(ptr("pointerdown", at));
  await G().until(() => !!S.carry.value, 1500);
  if (!S.carry.value) return ["long-press lift: the home tile never lifted (no carry)"];
  const fails = atLeastOne("long-press lift", t0);
  if (!S.editing.value) fails.push("long-press lift: edit mode didn't start");
  await move({ x: at.x + 6, y: at.y + 60 });
  fails.push(...(await snapInto("folder zone", center(to))));
  const dock = document.querySelector(".dock .dock-page") ?? document.querySelector(".dock");
  fails.push(...(dock ? await snapInto("dock zone", center(dock)) : ["dock zone: no dock on home"]));
  // Back on home's empty space and let go (a drop: its own tick, not asserted here).
  const rest = { x: innerWidth / 2, y: innerHeight * 0.45 };
  await move(rest);
  window.dispatchEvent(ptr("pointerup", rest));
  await G().until(() => !S.carry.value, 1500);
  S.editing.value = false;
  S.selected.value = null;
  await G().frames(3);
  return fails;
}

/** A long press on home's empty space enters edit mode with a tick (grid.tsx useEmptyPress). */
export async function editEnter() {
  const S = await mod("./state.ts");
  S.editing.value = false;
  await G().frames(2);
  const p = { x: innerWidth / 2, y: innerHeight * 0.55 };
  const el = document.elementFromPoint(p.x, p.y);
  if (!el) return ["edit-mode enter: nothing at home's empty middle"];
  const t0 = count();
  el.dispatchEvent(ptr("pointerdown", p, 42));
  await G().until(() => S.editing.value, 1500);
  el.dispatchEvent(ptr("pointerup", p, 42));
  const fails = S.editing.value ? want("edit-mode enter", t0, 1) : [`edit-mode enter: a long press on home's empty space (${el.className}) didn't enter edit mode`];
  S.editing.value = false;
  await G().frames(2);
  return fails;
}

/** The slider [range] dragged through its values: ticks at each end it reaches, never between or resting there. */
async function sliderDetents(range) {
  const set = async (v) => {
    range.value = String(v);
    range.dispatchEvent(new Event("input", { bubbles: true }));
    await G().frames(1);
  };
  const t0 = count();
  for (const v of [500, 900]) await set(v);
  const fails = want("slider moving between its ends", t0, 0);
  await set(1000);
  fails.push(...want("slider reaching the top", t0, 1));
  for (const v of [1000, 995]) await set(v);
  fails.push(...want("slider resting at / just under the top", t0, 1));
  await set(0);
  fails.push(...want("slider on to the bottom (one more)", t0, 2));
  range.dispatchEvent(new Event("change", { bubbles: true }));
  return fails;
}

/** The control center (the shade's page): a switch flipped ticks (control.tsx tapOf / usePress); a slider at its ends. */
export async function controlCenter() {
  if (!window.__hapticsMock) return ["no mock haptics (bridge.ts window.__hapticsMock)"];
  const S = await mod("./state.ts");
  const C = await mod("./ui/control.tsx");
  S.ccV3.value = "v3";
  const tile = (id, label, on) => ({ id, label, on, detail: null });
  C.quick.value = { torch: false, dnd: false, brightness: { value: 0.5, auto: false }, volume: { value: 0.5, ringer: 2 },
    tiles: [tile("wifi", "Wi-Fi", true), tile("bt", "Bluetooth", false), tile("dnd", "Do not disturb", false), tile("torch", "Torch", false)] };
  S.notif.value = true;
  const range = () => document.querySelector(".cc-slider input[type=range]");
  await G().until(() => !!document.querySelector(".cc3-list [aria-pressed]") && !!range(), 5000);
  await G().settled();
  const toggle = document.querySelector('.cc3-list [data-key="bt"] [aria-pressed]') ?? document.querySelector(".cc3-list [aria-pressed]");
  const fails = [];
  if (toggle) {
    const t0 = count();
    toggle.click();
    await G().frames(2);
    fails.push(...want(`control center: flipping ${toggle.getAttribute("aria-label")}`, t0, 1));
  } else fails.push("control center: no toggle to flip");
  fails.push(...(range() ? await sliderDetents(range()) : ["control center: no slider"]));
  S.notif.value = false;
  await G().frames(3);
  return fails;
}

/** Home's touch handlers at [x0], y: a fire(type, x) for a sideways swipe (as dev/page-swipe-check.js). */
function swipeAt(x0, y) {
  const tgt = document.elementFromPoint(x0, y);
  return (type, x) => {
    const t = new Touch({ identifier: 13, target: tgt, clientX: x, clientY: y });
    const init = { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true };
    // The gate's Chromium has no touch input: Preact bound home's onTouchStart as "TouchStart" there - both names.
    for (const name of [type, `Touch${type.slice(5, 6).toUpperCase()}${type.slice(6)}`]) tgt.dispatchEvent(new TouchEvent(name, init));
  };
}

/** Past the last page the rubber band ticks once (gesture.ts pageOffset); short of the band it's silent. */
export async function edgeBounce() {
  const S = await mod("./state.ts");
  S.page.value = S.pageCount.value - 1;
  await G().until(() => G().still(), 1500);
  await G().frames(2);
  const x0 = innerWidth * 0.6;
  const fire = swipeAt(x0, innerHeight * 0.45);
  const t0 = count();
  fire("touchstart", x0);
  for (let i = 1; i <= 3; i++) (fire("touchmove", x0 - i * 10), await G().frames(1));
  const fails = want("edge bounce, before the band stretched", t0, 0);
  for (let i = 4; i <= 20; i++) (fire("touchmove", x0 - i * 10), await G().frames(1));
  fails.push(...want("edge bounce, pulled past the last page", t0, 1));
  fire("touchend", x0 - 200);
  await G().until(() => G().still(), 1500);
  S.page.value = 0;
  return fails;
}

/** The shade's pull (the host's "shade.drag" {q} on the shade's page) ticks once as it crosses opening (gesture.ts panelTicks). */
export async function shadePull() {
  const S = await mod("./state.ts");
  S.notif.value = false;
  await G().frames(2);
  const t0 = count();
  const to = async (q) => (window.__mockEvents.emit("shade.drag", { q }), await G().frames(1));
  for (const q of [0.02, 0.06, 0.1]) await to(q);
  const fails = want("pull-to-shade, short of the threshold", t0, 0);
  for (const q of [0.3, 0.6, 0.9, 1]) await to(q);
  fails.push(...want("pull-to-shade, past the threshold and held", t0, 1));
  window.__mockEvents.emit("shade.settle", { open: true });
  await G().frames(2);
  return fails;
}

/** The torch button pressed for [ms] and let go. */
async function pressFor(btn, ms, id) {
  const p = center(btn);
  btn.dispatchEvent(ptr("pointerdown", p, id));
  await G().sleep(ms);
  btn.dispatchEvent(ptr("pointerup", p, id));
}

/** A lock shortcut held HOLD_MS acts with a confirm (lockshortcuts.tsx); a tap is silent. */
export async function lockShortcut() {
  const { h, render } = await mod("preact");
  const L = await mod("./ui/lockshortcuts.tsx");
  L.shortcuts.value = { torch: false, camera: true };
  const host = document.createElement("div");
  document.body.append(host);
  render(h(L.LockShortcuts, { hint: () => {} }), host);
  await G().frames(2);
  const btn = host.querySelector('[data-shortcut="torch"]');
  const fails = [];
  if (btn) {
    // A synthetic pointer has no capture to take (setPointerCapture throws NotFoundError for it).
    btn.setPointerCapture = () => {};
    const t0 = count();
    await pressFor(btn, 60, 43);
    await G().sleep(L.HOLD_MS + 100);
    fails.push(...want("lock shortcut tapped", t0, 0));
    await pressFor(btn, L.HOLD_MS + 150, 44);
    fails.push(...want("lock shortcut held", t0, 1));
  } else fails.push("lock shortcut: no torch button");
  render(null, host);
  host.remove();
  return fails;
}
