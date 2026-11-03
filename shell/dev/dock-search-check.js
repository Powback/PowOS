/**
 * Home's search as a dock button (ui/docksearch.tsx; the user, 2026-10-31 01:24-01:26). Runs in home's page
 * (index.html): gate.mjs's dock-search-* cases. [position]: the dock's placement. The failures, empty when it holds:
 * in "dock button" no .bar on home; the button in the dock's centre slot (and centred on the bottom row); a tap, a hold,
 * push-to-talk and a swipe up open the launcher as DS2 says (pressOpens); "bar" brings the pill back.
 * dockSearchLaunch runs in the launcher overlay's page (index.html?mode=pull): its side of those opens (launchmorph.ts).
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function centred(position) {
  const btn = document.querySelector(".home > .dock .dock-search");
  if (!btn) return "no search button in the dock";
  const row = btn.parentElement;
  const cells = [...row.children].filter((c) => c.matches(".app"));
  const i = cells.indexOf(btn);
  // A side column: the button is the separator, after the pinned apps (separated checks the recent ones after it).
  if (position !== "bottom") return i === cells.length - 1 ? "" : `button at cell ${i} of ${cells.length}, not after the pinned apps`;
  if (i !== Math.floor(cells.length / 2)) return `button at cell ${i} of ${cells.length}, not the centre`;
  const b = btn.getBoundingClientRect();
  const first = cells[0].getBoundingClientRect();
  const last = cells[cells.length - 1].getBoundingClientRect();
  const off = b.left + b.width / 2 - (first.left + last.right) / 2;
  return Math.abs(off) > 2 ? `button ${Math.round(off)} px off the dock's centre` : "";
}

function fire(el, type, dx = 0, dy = 0) {
  const r = el.getBoundingClientRect();
  const at = { bubbles: true, pointerId: 7, isPrimary: true, pointerType: "touch", clientX: r.left + r.width / 2 - 6 + dx, clientY: r.top + r.height / 2 - 6 + dy };
  el.dispatchEvent(new PointerEvent(type, at));
}

/**
 * Home's page: its launcher opens in place (state.ts homePage: it adopts home's dock and bar), never the host's overlay -
 * any pull.open / pull.drive is recorded as a failure; speech calls counted.
 */
async function record() {
  const { powos } = await importShim("./bridge.ts");
  const S = await importShim("./state.ts");
  const asked = [];
  const speech = { start: 0, hold: 0, stop: 0 };
  powos.pull.open = async (kind, how) => (asked.push({ kind, how }), true);
  powos.pull.drive = async (phase) => (asked.push({ drive: phase }), true);
  const { start, hold, stop } = powos.speech;
  powos.speech.start = async (...a) => (speech.start++, start(...a));
  powos.speech.hold = async () => (speech.hold++, hold());
  powos.speech.stop = async () => (speech.stop++, stop());
  return { asked, speech, S };
}

/** Shut again, settled, before the next press. */
async function shutHome(S) {
  S.closeDrawer();
  await sleep(400);
}

/** What a press left: the launcher open in place, one bar and one dock on home, the overlay never asked. */
function inPlace(what, S, asked) {
  const fails = [];
  if (S.drawer.value !== 1) fails.push(`${what}: the launcher didn't open in place`);
  if (asked.length) fails.push(`${what}: asked the host's overlay (${JSON.stringify(asked.splice(0))})`);
  const bars = document.querySelectorAll(".home > .bar").length;
  const docks = document.querySelectorAll(".home > .dock:not(.dock-tray)").length;
  if (bars !== 1 || docks !== 1) fails.push(`${what}: ${bars} bars, ${docks} docks (one each)`);
  return fails;
}

/** A tap: the launcher open in place with home's own bar focused. */
async function tapOpens(btn, asked, speech, S) {
  fire(btn, "pointerdown");
  fire(btn, "pointerup");
  const field = () => document.querySelector(".home > .bar textarea");
  for (let t = 0; t < 40 && !(field() && document.activeElement === field()); t++) await sleep(50);
  const fails = inPlace("a tap", S, asked);
  if (document.activeElement !== field()) fails.push("a tap: home's bar not focused");
  await shutHome(S);
  return fails;
}

/** Held 300 ms: the launcher open in place, dictating; let go soon after, the dictation goes on (no stop). */
async function holdDictates(btn, asked, speech, S) {
  fire(btn, "pointerdown");
  await sleep(400);
  fire(btn, "pointerup");
  await sleep(100);
  const fails = inPlace("held 300 ms", S, asked);
  if (!speech.start) fails.push("held 300 ms: not dictating");
  if (speech.stop) fails.push("a short hold let go stopped the dictation (it goes on as a tap's)");
  await shutHome(S);
  return fails;
}

/** Still held: push-to-talk (speech.hold); let go at 1.5 s, the dictation stops (speech.stop, never a send). */
async function pushToTalk(btn, asked, speech, S) {
  speech.stop = 0;
  fire(btn, "pointerdown");
  await sleep(1500);
  const fails = speech.hold ? [] : ["held 1.5 s: not push-to-talk (no speech.hold)"];
  fire(btn, "pointerup");
  await sleep(50);
  if (speech.stop !== 1) fails.push(`push-to-talk let go: ${speech.stop} stops`);
  asked.length = 0;
  await shutHome(S);
  return fails;
}

/** A swipe up from it: home's own launcher follows the finger (drawerDrag) and opens, in place. */
async function swipeUp(btn, asked, speech, S) {
  const { drawerDrag } = await importShim("./ui/gesture.ts");
  const seen = [];
  fire(btn, "pointerdown");
  for (let i = 1; i <= 6; i++) (fire(btn, "pointermove", 0, -i * 20), seen.push(drawerDrag.value));
  fire(btn, "pointerup", 0, -120);
  await sleep(50);
  const fails = seen.some((p) => p > 0) ? [] : ["swipe up: the launcher didn't follow the finger"];
  fails.push(...inPlace("swipe up 120 px", S, asked));
  await shutHome(S);
  return fails;
}

/** DS2 (the user, 01:53): tap, hold, push-to-talk and a swipe up from the button. */
async function pressOpens(position) {
  const btn = document.querySelector(".home > .dock .dock-search");
  if (!btn) return [];
  const { asked, speech, S } = await record();
  const fails = [];
  for (const press of [tapOpens, holdDictates, pushToTalk, swipeUp]) fails.push(...(await press(btn, asked, speech, S)));
  if (document.querySelector(".dock-search-bar")) fails.push("a bar expanded in place");
  return fails.map((f) => `${position}: ${f}`);
}

/** Switched back to "bar": the pill on home again, the button gone. */
async function backToBar(S) {
  S.searchTry.value = "bar";
  await sleep(200);
  const fails = [];
  if (!document.querySelector(".home > .bar")) fails.push("back to bar: no .bar on home");
  if (document.querySelector(".home > .dock .dock-search")) fails.push("back to bar: the button stayed in the dock");
  return fails;
}

export async function dockSearchCheck(position) {
  const S = await importShim("./state.ts");
  const was = S.dock.value;
  if (S.dock.value.length < 6) S.dock.value = S.recent.value.slice(0, 6);
  S.dockTry.value = position;
  S.searchTry.value = "dock";
  // The dock's icons glide to their new places (home.tsx useGlide, 160 ms) as the apps and the button join: measured
  // mid-glide under the ship gate's load the button sat -172 / -19 px off centre. Wait on the glide's end, not a clock.
  await window.__gw.settled(() => document.querySelector(".home > .dock .dock-search"), ".home > .dock");
  const fails = [];
  if (document.querySelector(".home > .bar")) fails.push("a .bar on home in dock-button mode");
  const c = centred(position);
  if (c) fails.push(c);
  fails.push(...(await followsFolded(S)), ...(await pressOpens(position)), ...(await backToBar(S)));
  S.searchTry.value = "";
  S.dockTry.value = "";
  S.dock.value = was;
  return fails.map((f) => `${position}: ${f}`);
}

/** The bar's glass pieces' union (launchmorph.ts), or the pill once it's done. */
function glassRect() {
  const pieces = [...document.querySelectorAll(".pull-screen > .bar .launch-glass")].map((e) => e.getBoundingClientRect());
  if (!pieces.length) return null;
  const left = Math.min(...pieces.map((r) => r.left));
  const right = Math.max(...pieces.map((r) => r.right));
  const top = Math.min(...pieces.map((r) => r.top));
  return { left, right, top, width: right - left };
}

const opened = (E, how) => {
  E.emit("pull.begin", { kind: "apps", search: true, ...how });
  E.emit("pull.drag", { p: 1 });
  E.emit("pull.end", { open: true });
};

/** Polls [fn] (every 16 ms) until it's truthy or [ms] pass: state, not wall-clock samples. Resolves its last value. */
async function until(fn, ms = 4000) {
  const t0 = performance.now();
  let v = fn();
  while (!v && performance.now() - t0 < ms) {
    await new Promise((r) => setTimeout(r, 16));
    v = fn();
  }
  return v;
}

const pill = () => document.querySelector(".pull-screen > .bar .bar-pill");
const morphAnims = () => [...document.querySelectorAll(".pull-screen > .bar .launch-glass")].flatMap((e) => e.getAnimations());
const settled = () => morphAnims().every((a) => a.playState === "finished");
const scaleX = (t) => +(/scale\(([-\d.e]+)/.exec(t ?? "")?.[1] ?? NaN);

/** Right after the open: the glass's middle piece runs a transform animation from narrow to wide, its pieces never fading. */
function animates() {
  const mid = [...document.querySelectorAll(".pull-screen > .bar .launch-glass")][1];
  if (!mid) return ["the open has no morph pieces"];
  const a = mid.getAnimations().find((x) => x.playState === "running" && x.effect?.getKeyframes().some((k) => k.transform));
  if (!a) return ["the open didn't animate: no running transform animation on the glass"];
  const frames = a.effect.getKeyframes();
  const fails = [];
  if (!(scaleX(frames.at(-1).transform) > scaleX(frames[0].transform) * 2)) fails.push(`the glass didn't widen in its keyframes: ${frames[0].transform} -> ${frames.at(-1).transform}`);
  const op = morphAnims().flatMap((x) => x.effect.getKeyframes()).filter((k) => k.opacity != null && +k.opacity < 0.99);
  if (op.length) fails.push("the glass faded (opacity < 1)");
  return fails;
}

/** The open from the button: animates, then (settled) the bar's rect is wider and higher than the button's, the pieces gone. */
async function morphOpen(E, from, rises) {
  opened(E, { from });
  const fails = animates();
  const done = await until(() => !document.querySelector(".launch-glass") && pill());
  if (!done) return [...fails, "the morph's pieces stayed after the open"];
  const end = pill().getBoundingClientRect();
  if (!(end.width > from.width * 2)) fails.push(`the glass didn't widen: ${Math.round(from.width)} -> ${Math.round(end.width)}`);
  if (rises && !(end.top < from.top - 4)) fails.push(`the glass didn't rise: top ${Math.round(from.top)} -> ${Math.round(end.top)}`);
  const field = () => document.querySelector(".pull-screen > .bar textarea");
  if (!(await until(() => field() && document.activeElement === field(), 1000))) fails.push(`tap's open: the field isn't focused (${document.activeElement?.tagName})`);
  return fails;
}

/** Shut: the glass settles back on the button. */
async function shut(S, E, from) {
  S.drawer.value = 0;
  await until(() => document.querySelector(".launch-glass") && morphAnims().length && settled());
  const back = glassRect();
  const fails = !back || Math.abs(back.width - from.width) > from.width * 0.5 ? [`shut: the glass isn't back on the button (${back ? Math.round(back.width) : "none"})`] : [];
  E.emit("pull.hide", {});
  await until(() => !document.querySelector(".launch-glass"), 1000);
  return fails;
}

/** A hold's open: the bar dictating at once; home's release (push-to-talk) stops it, the words stay, nothing sent. */
async function holdOpen(S, E, from) {
  const { powos } = await importShim("./bridge.ts");
  const D = await importShim("./ui/dictation.ts");
  S.query.value = "";
  opened(E, { listen: true, from });
  await sleep(100);
  const fails = [];
  if (!D.speech.value.listening || !document.querySelector(".pull-screen > .bar .mic.on")) fails.push("hold's open: the bar isn't dictating");
  await sleep(1400);
  await powos.speech.stop();
  await sleep(100);
  if (D.speech.value.listening) fails.push("push-to-talk released: still listening");
  if (!S.query.value.trim()) fails.push("push-to-talk released: the words didn't stay in the field");
  if (S.chatting.value) fails.push("push-to-talk released: it was sent");
  E.emit("pull.hide", {});
  return fails;
}

/** The button's rect on the overlay's dock (its bottom dock folded), else a stand-in for home's. */
function buttonRect() {
  const face = document.querySelector(".pull-screen .dock .dock-search-face")?.getBoundingClientRect();
  return face ? { left: face.left, top: face.top, width: face.width, height: face.height } : { left: innerWidth / 2 - 24, top: innerHeight - 70, width: 48, height: 48 };
}

/**
 * The launcher overlay's side (DS2): opened from home's button ({ from }), the bar's glass grows out of the button -
 * a running transform animation, never fading, settling wider and higher than the button - then the pill is the bar,
 * focused; a hold's ({ listen }) dictates into the bar, and home's push-to-talk release (speech.stop) leaves the words
 * in the field, nothing sent. Closed, the glass goes back into the button. Unfolded, the overlay's dock keeps its own
 * layout and its bar sits beside it. Waits on state (the morph's animations), never on sampled frame times.
 */
export async function dockSearchLaunch(position) {
  const S = await importShim("./state.ts");
  const E = window.__mockEvents;
  if (S.dock.value.length < 6) S.dock.value = S.recent.value.slice(0, 6);
  S.dockTry.value = position;
  S.searchTry.value = "dock";
  await sleep(300);
  const folded = position === "bottom" && !document.querySelector(".pull-screen.wide");
  // LN1: folded, the overlay has no dock until it opens from the button (pull.tsx dockShown): no slot at rest to check.
  const fails = [];
  const from = buttonRect();
  fails.push(...(await morphOpen(E, from, folded)), ...(await shut(S, E, from)), ...(await holdOpen(S, E, from)));
  S.searchTry.value = "";
  S.dockTry.value = "";
  return { fails: fails.map((f) => `launch ${position}: ${f}`) };
}

/** The pinned row (the button's): its cell count and first app icon's size. */
function pinnedRow() {
  const btn = document.querySelector(".home > .dock:not(.dock-tray) .dock-search");
  const row = btn?.parentElement;
  if (!row) return null;
  const icon = row.querySelector(".app:not(.dock-search) .app-icon")?.getBoundingClientRect();
  return { row, cells: [...row.children].filter((c) => c.matches(".app")).length, w: Math.round(icon?.width ?? 0), h: Math.round(icon?.height ?? 0) };
}

/** Where the [keys] show: in the pinned row, or anywhere else in the dock / tray (the recent section). */
function placed(row, keys) {
  const inRow = keys.filter((k) => row.querySelector(`.app[data-key="${CSS.escape(k)}"]`));
  const recent = [...document.querySelectorAll(".home .dock .dock-recent")];
  const inRecent = keys.filter((k) => recent.some((r) => r.querySelector(`.app[data-key="${CSS.escape(k)}"]`)));
  return { inRow, inRecent };
}

/**
 * DK2 (the user, 13:31): in a side column the search button is the separator - exactly one in the dock, after the last
 * pinned app and before the first recent one (above / below on screen too), no .dock-sep line.
 */
function separated(row) {
  const fails = [];
  const buttons = document.querySelectorAll(".home > .dock:not(.dock-tray) .dock-search");
  if (buttons.length !== 1) fails.push(`${buttons.length} search buttons in the dock, not 1`);
  if (document.querySelector(".home > .dock .dock-sep")) fails.push("a .dock-sep line beside the button");
  const btn = buttons[0];
  const cells = [...row.children].filter((c) => c.matches(".app"));
  if (!btn || cells.at(-1) !== btn) return [...fails, "the button isn't after the last pinned app"];
  return [...fails, ...between(btn, cells.at(-2), row.nextElementSibling)];
}

/** On screen: the button below the last pinned app [above] and above the first app of the recent section [recent]. */
function between(btn, above, recent) {
  const first = recent?.matches(".dock-recent") && recent.querySelector(".app");
  if (!first) return ["no recent app right after the pinned group"];
  const b = btn.getBoundingClientRect();
  const fails = [];
  if (above && above.getBoundingClientRect().bottom > b.top + 1) fails.push("the button isn't below the last pinned app");
  if (b.bottom > first.getBoundingClientRect().top + 1) fails.push("the button isn't above the first recent app");
  return fails;
}

/** Folded and unfolded each keep their own spot (state.ts searchSpot): the other mode's "dock" never docks this one. */
async function followsFolded(S) {
  if (S.dockMode.value !== "unfolded") return [];
  const was = { mobile: S.searchSpot.mobile.value, unfolded: S.searchSpot.unfolded.value };
  S.searchTry.value = "";
  S.searchSpot.mobile.value = "dock";
  S.searchSpot.unfolded.value = "bar";
  await sleep(100);
  const fails = S.searchInDock.value ? ["folded docked, unfolded the bar: docked unfolded"] : [];
  S.searchSpot.unfolded.value = "dock";
  if (!S.searchInDock.value) fails.push("unfolded's own \"dock\" didn't give the button");
  S.searchSpot.mobile.value = was.mobile;
  S.searchSpot.unfolded.value = was.unfolded;
  S.searchTry.value = "dock";
  await sleep(100);
  return fails;
}

/** The pinned row [before] and [after] the running [extra] apps: the same cells and icons, the apps elsewhere. */
function unchanged(before, after, extra) {
  const fails = [];
  if (after.cells !== before.cells) fails.push(`3 running apps: the pinned row went ${before.cells} -> ${after.cells} cells`);
  if (after.w !== before.w || after.h !== before.h) fails.push(`3 running apps: icons ${before.w}x${before.h} -> ${after.w}x${after.h}`);
  const { inRow, inRecent } = placed(after.row, extra);
  if (inRow.length) fails.push(`running apps in the pinned row: ${inRow.join(", ")}`);
  if (inRecent.length !== extra.length) fails.push(`running apps in the recent section: ${inRecent.length} of ${extra.length}`);
  return fails;
}

/**
 * DK1 + DK2 (the user, 2026-10-31: "The dock is the same size always" / "a separator between the docking and the recent
 * items"): in dock-button mode three running apps that aren't pinned leave the pinned row's cell count and icon size
 * as they were and show in the recent section; a side column has the button as the separator between the groups.
 */
export async function dk1Check(position) {
  const S = await importShim("./state.ts");
  const was = { dock: S.dock.value, windows: S.windows.value };
  S.dock.value = S.recent.value.slice(0, 6);
  S.dockTry.value = position;
  S.searchTry.value = "dock";
  await sleep(300);
  const before = pinnedRow();
  const fails = [];
  if (!before) fails.push("no pinned row with the search button");
  else if (before.cells !== 7) fails.push(`pinned row has ${before.cells} cells, not 6 + the button`);
  const extra = [...S.byKey.value.keys()].filter((k) => !S.dock.value.includes(k) && !S.recent.value.includes(k)).slice(0, 3);
  S.windows.value = extra.map((k, i) => ({ id: 900 + i, pkg: k, label: k, minimised: false, app: k }));
  await sleep(300);
  const after = pinnedRow();
  if (before && after) fails.push(...unchanged(before, after, extra), ...(position !== "bottom" ? separated(after.row) : []));
  S.windows.value = was.windows;
  S.searchTry.value = "";
  S.dockTry.value = "";
  S.dock.value = was.dock;
  return fails.map((f) => `dk1 ${position}: ${f}`);
}

/*
 * SW1 (the user, 2026-10-31 15:34: "grab the search as a widget and put it into the sidebar"): edit mode's drag docks
 * and undocks home's search (ui/searchwidget.tsx). gate.mjs's search-widget-* cases call these in order, with reloads
 * between: searchSpotMigrates / searchSpotDefaults (the old hidden setting, the defaults), searchDragDocks (the bar onto
 * the dock: a gap at the separator while over it, then the button there and no bar), searchDragOut (the button onto
 * home: the bar widget at the drop cell), searchSpotKept (after a reload).
 */

/** Before a reload: the old setting as it was stored, the new spot unset, not migrated yet. */
export function searchSpotOld(mobile, unfolded) {
  for (const k of ["mobile", "unfolded"]) localStorage.removeItem(`powos.search.spot.${k}`);
  localStorage.removeItem("powos.search.spot.migrated");
  localStorage.setItem("powos.search.place.mobile", mobile);
  localStorage.setItem("powos.search.place.unfolded", unfolded);
  localStorage.setItem("powos.search.place.migrated", "2");
}

/** After it: the old values became the spots, the old keys are gone. */
export async function searchSpotMigrates(mobile, unfolded) {
  const S = await importShim("./state.ts");
  const fails = [];
  if (S.searchSpot.mobile.value !== mobile) fails.push(`folded migrated to "${S.searchSpot.mobile.value}", not "${mobile}"`);
  if (S.searchSpot.unfolded.value !== unfolded) fails.push(`unfolded migrated to "${S.searchSpot.unfolded.value}", not "${unfolded}"`);
  for (const k of ["mobile", "unfolded", "migrated"]) if (localStorage.getItem(`powos.search.place.${k}`) != null) fails.push(`powos.search.place.${k} still stored`);
  // Unset after the migration (a fresh device): the defaults next.
  for (const k of ["mobile", "unfolded"]) localStorage.removeItem(`powos.search.spot.${k}`);
  return fails.map((f) => `migrate: ${f}`);
}

/** A fresh device: the bar, folded and unfolded (the user, 11-03: the search bar back) - on screen too. */
export async function searchSpotDefaults() {
  const S = await importShim("./state.ts");
  const fails = [];
  if (S.searchSpot.mobile.value !== "bar") fails.push(`folded default "${S.searchSpot.mobile.value}", not "bar"`);
  if (S.searchSpot.unfolded.value !== "bar") fails.push(`unfolded default "${S.searchSpot.unfolded.value}", not "bar"`);
  await sleep(200);
  if (document.querySelector(".home > .dock .dock-search")) fails.push(`${S.dockMode.value} default: dock button shown`);
  if (!document.querySelector(".home > .bar")) fails.push(`${S.dockMode.value} default: bar missing`);
  return fails.map((f) => `defaults: ${f}`);
}

const at = (x, y) => ({ bubbles: true, pointerId: 11, isPrimary: true, pointerType: "touch", clientX: x, clientY: y });
const centre = (el) => {
  const r = el.getBoundingClientRect();
  return [r.left + r.width / 2, r.top + r.height / 2];
};

/** A finger from [el]'s middle to [x], [y]: down on it, moves on the window, [mid] looked at over the target, up. */
async function drag(el, x, y, mid) {
  const [x0, y0] = centre(el);
  el.dispatchEvent(new PointerEvent("pointerdown", at(x0, y0)));
  for (const f of [0.1, 0.4, 0.8, 1]) {
    dispatchEvent(new PointerEvent("pointermove", at(x0 + (x - x0) * f, y0 + (y - y0) * f)));
    await sleep(60);
  }
  const seen = mid?.();
  dispatchEvent(new PointerEvent("pointerup", at(x, y)));
  await sleep(300);
  return seen;
}

/** The dock's pinned row's cells, and where the search's would be (dockdrop.ts buttonSlot of [cells]). */
function pinnedCells() {
  const row = document.querySelector(".home > .dock:not(.dock-tray) .dock-page");
  return row ? [...row.children].filter((c) => c.matches(".app")) : [];
}

/** Cell [i] of [n] is the dock's separator (dockdrop.ts buttonSlot): a side column's end, a bottom row's middle. */
function atSeparator(what, { i, n }, vertical) {
  const want = vertical ? n - 1 : Math.floor((n - 1) / 2);
  if (i < 0) return [`no ${what}`];
  return i === want ? [] : [`${what} at cell ${i} of ${n}, not the separator ${want}`];
}

/** Edit mode, this mode's search the bar (in the foot), 6 pinned apps, a side [position]. */
export async function searchDragSetup(position) {
  const S = await importShim("./state.ts");
  if (S.dock.value.length < 6) S.dock.value = S.recent.value.slice(0, 6);
  S.dockTry.value = position;
  S.searchPlacement.value.value = "bar";
  S.editing.value = true;
  await sleep(400);
}

/** The foot's pill dragged onto the dock: a gap at the separator while over it; let go, the button there, no bar. */
export async function searchDragDocks() {
  const S = await importShim("./state.ts");
  const fails = [];
  const bar = document.querySelector(".home > .bar");
  const dock = document.querySelector(".home > .dock:not(.dock-tray)");
  if (!bar || !dock) return [`no ${bar ? "dock" : "bar"} on home to drag`];
  const [x, y] = centre(dock);
  const vertical = S.dockPosition.value !== "bottom";
  const gapAt = await drag(bar, x, y, () => {
    const cells = pinnedCells();
    return { i: cells.findIndex((c) => c.matches(".dock-gap")), n: cells.length };
  });
  fails.push(...atSeparator("drop gap (over the dock)", gapAt, vertical));
  if (!S.searchInDock.value) fails.push("let go on the dock: not docked");
  const cells = pinnedCells();
  fails.push(...atSeparator("dock button (dropped)", { i: cells.findIndex((c) => c.matches(".dock-search")), n: cells.length }, vertical));
  if (document.querySelector(".home > .bar")) fails.push("the bar is still on home");
  if (document.querySelector(".home .search-face")) fails.push("a search widget left on the grid");
  return fails.map((f) => `dock: ${f}`);
}

/** The dock's button dragged onto home's first free row: the bar widget at that cell, the button gone. */
export async function searchDragOut() {
  const S = await importShim("./state.ts");
  const G = await importShim("./ui/grid.tsx");
  const btn = document.querySelector(".home > .dock .dock-search");
  if (!btn) return ["out: no dock button to drag"];
  // The drop cell from the grid as it rests: the dock's drop just took the bar out of the foot, and on a starved gate
  // (11-03, the full gate at load 7-10) the grid was still re-laid out from it - a cell taken from the old geometry
  // was a row off ("at y 8, not the drop cell y 7"). Its geometry and the button the same over frames, nothing moving.
  await window.__gw.settled(() => true, ".home");
  await window.__gw.steady(() => [G.geometry.value, btn.getBoundingClientRect().toJSON()]);
  const spot = G.placeNewCells(S.home.value.columns, 1);
  const g = G.geometry.value;
  const x = g.left + g.pad + (spot.cell.w * g.cellW) / 2 + spot.cell.x * g.cellW;
  const y = g.top + g.pad + (spot.cell.h * g.cellH) / 2 + spot.cell.y * g.cellH;
  await drag(btn, x, y);
  await window.__gw.until(() => S.home.value.items.some((i) => i.key === "panel:search"));
  const fails = [];
  const item = S.home.value.items.find((i) => i.key === "panel:search");
  if (!item) fails.push("no bar widget on home after the drop");
  else if (item.page !== spot.page || item.cell?.x !== spot.cell.x || item.cell?.y !== spot.cell.y) fails.push(`bar widget at ${JSON.stringify([item.page, item.cell])}, not the drop cell ${JSON.stringify([spot.page, spot.cell])}`);
  if (S.searchInDock.value) fails.push("still docked");
  if (document.querySelector(".home > .dock .dock-search")) fails.push("the dock button is still there");
  return fails.map((f) => `out: ${f}`);
}

/**
 * The widget per screen: this screen docked (a check's, searchTry) and the other's the bar, the one home item stays (the
 * other screen's) but isn't on this grid; undocked again it is.
 */
export async function searchWidgetPerScreen() {
  const S = await importShim("./state.ts");
  const other = S.dockMode.value === "unfolded" ? S.searchSpot.mobile : S.searchSpot.unfolded;
  const was = other.value;
  other.value = "bar";
  S.searchTry.value = "dock";
  await sleep(300);
  const fails = [];
  if (document.querySelector(".home .search-face")) fails.push("docked here, the other screen's search widget is on this grid");
  if (!S.home.value.items.some((i) => i.key === "panel:search")) fails.push("the other screen's search widget is gone");
  S.searchTry.value = "";
  await sleep(300);
  if (!document.querySelector(".home .search-face")) fails.push("undocked, the search widget isn't back on the grid");
  other.value = was;
  return fails.map((f) => `per screen: ${f}`);
}

/** After a reload: the spot the drag left (undocked), then docked again and reloaded: docked. [want]: "bar" | "dock". */
export async function searchSpotKept(want, position) {
  const S = await importShim("./state.ts");
  S.dockTry.value = position;
  await sleep(300);
  const fails = [];
  if (S.searchPlacement.value.value !== want) fails.push(`reloaded: spot "${S.searchPlacement.value.value}", not "${want}"`);
  if (!!document.querySelector(".home > .dock .dock-search") !== (want === "dock")) fails.push(`reloaded: dock button ${want === "dock" ? "missing" : "shown"}`);
  return fails;
}

/** The end: the widget off the grid, docked again (the next reload checks it stayed). */
export async function searchDragDone() {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/searchwidget.tsx");
  S.editing.value = false;
  await W.dockSearch();
  S.dockTry.value = "";
  await sleep(200);
}

/**
 * PT1 (the user, 2026-11-01 17:02: "When I hold the launcher mic / push-to-talk, it switches itself off: the launcher
 * shows up, my finger is now over the input field, the input activates, and that stops the voice"). gate.mjs's
 * ptt-hold-* cases hold the dock button with a real (CDP) finger for 3 s: pttHoldSetup puts the button in the dock and
 * counts the recognizer's calls, pttHoldSample is read every 100 ms while held, pttHoldResult after the finger lifts.
 */
export async function pttHoldSetup(position) {
  const S = await importShim("./state.ts");
  const { powos } = await importShim("./bridge.ts");
  if (S.dock.value.length < 6) S.dock.value = S.recent.value.slice(0, 6);
  S.dockTry.value = position;
  S.searchTry.value = "dock";
  await window.__gw.settled(() => document.querySelector(".home > .dock .dock-search"), ".home > .dock");
  const calls = { start: 0, hold: 0, stop: 0, cancel: 0, focus: [] };
  for (const k of ["start", "hold", "stop", "cancel"]) {
    const was = powos.speech[k];
    powos.speech[k] = async (...a) => (calls[k]++, was(...a));
  }
  document.addEventListener("focusin", (e) => calls.focus.push(`${Math.round(performance.now())} ${e.target.tagName}`), true);
  const r = document.querySelector(".home > .dock .dock-search").getBoundingClientRect();
  const at = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  window.__pt1 = { calls, samples: [], at };
  return at;
}

/** One sample while held: dictating, the field (if any) not focused, the launcher's state. */
export async function pttHoldSample() {
  const S = await importShim("./state.ts");
  const { speech } = await importShim("./ui/dictation.ts");
  const field = document.querySelector(".home > .bar textarea");
  const under = window.__pt1.at && document.elementFromPoint(window.__pt1.at.x, window.__pt1.at.y);
  window.__pt1.samples.push({ listening: speech.value.listening, focused: !!field && document.activeElement === field, open: S.drawer.value, stops: window.__pt1.calls.stop + window.__pt1.calls.cancel, under: under?.tagName });
}

/** While held (from the 6th sample, 500 ms in): the launcher up, the dictation on, its field never focused, no stop. */
function heldFails(calls, samples) {
  const fails = [];
  const held = samples.slice(5);
  if (!held.length) fails.push("no samples while held");
  if (!samples.some((s) => s.open === 1)) fails.push("the launcher never came up while held");
  const off = held.findIndex((s) => !s.listening);
  if (off >= 0) fails.push(`the dictation went off while still held (sample ${off + 5} of ${samples.length})`);
  const foc = samples.findIndex((s) => s.focused);
  if (foc >= 0) fails.push(`the launcher's field was focused while held (sample ${foc})`);
  if (held.some((s) => s.stops)) fails.push(`the recognizer was stopped while held: ${JSON.stringify(calls)}`);
  if (!calls.hold) fails.push("held 3 s: not push-to-talk (no speech.hold)");
  return fails;
}

/** After the finger lifted: what held through the 3 s and what the release did (one stop, no focus). */
export async function pttHoldResult() {
  const S = await importShim("./state.ts");
  const { speech } = await importShim("./ui/dictation.ts");
  const { calls, samples } = window.__pt1;
  const fails = heldFails(calls, samples);
  if (calls.stop + calls.cancel !== 1) fails.push(`the release: ${calls.stop} stops + ${calls.cancel} cancels (one stop)`);
  const field = document.querySelector(".home > .bar textarea");
  if (field && document.activeElement === field) fails.push("the release focused the launcher's field (read as a tap on it)");
  if (speech.value.listening) fails.push("still dictating after the release");
  if (calls.focus.length) fails.push(`focus moved during the press: ${calls.focus.join(", ")}`);
  S.closeDrawer();
  S.searchTry.value = "";
  S.dockTry.value = "";
  return fails;
}

/**
 * A dictation's words stream in (speech.state per partial result) while home shows the dock button: the dock redraws
 * at most for the button's on and off, never per word (02:23 trace perf-1793409701579: the dock's search 121 renders,
 * all signal-triggered - it read the whole speech state, text included, to show only whether the mic is on).
 * Returns {fails, counts: name -> renders} over 20 partials.
 */
export async function dockSpeechRenders(position) {
  const S = await importShim("./state.ts");
  const scan = await importShim("./ui/renderscan.ts");
  const was = S.dock.value;
  if (S.dock.value.length < 6) S.dock.value = S.recent.value.slice(0, 6);
  S.dockTry.value = position;
  S.searchTry.value = "dock";
  await window.__gw.settled(() => document.querySelector(".home > .dock .dock-search"), ".home > .dock");
  const raf = () => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => ok())));
  const host = (s) => window.__mockEvents.emit("speech.state", s);
  scan.startScan("gate-dock-speech");
  scan.reset();
  const words = "turn on the bluetooth and play some music from the kitchen speaker please now ok".split(" ");
  for (let i = 1; i <= 20; i++) (host({ listening: true, text: words.slice(0, i).join(" "), error: null }), await raf());
  host({ listening: false, text: "", error: null });
  await raf();
  const counts = {};
  for (const x of scan.scanStats()) counts[x.name] = (counts[x.name] ?? 0) + x.renders;
  scan.stopScan("gate-dock-speech");
  S.searchTry.value = "";
  S.dockTry.value = "";
  S.dock.value = was;
  const fails = [];
  const button = counts.DockSearchButton ?? 0;
  if (button > 2) fails.push(`${position}: the dock's search button rendered ${button}x over 20 words, expected <= 2 (on, off)`);
  for (const k of ["Dock", "AppCell", "memo(AppCell)"]) if (counts[k]) fails.push(`${position}: ${k} rendered ${counts[k]}x over 20 words, expected 0`);
  return { fails, counts };
}

/**
 * SS1 (the user, 11-02: "the option to have the search bar as an icon was supposed to be a setting"): Settings › style
 * has "folded search" and "unfolded search", each "dock button | bar" - a pick on this screen's own row makes home's
 * search that, at once (the dock's button and no bar, or the bar and no button), and is stored as the spot; the other
 * screen's spot is left alone. gate.mjs's search-setting-folded / -unfolded.
 */
/** The style screen's [name] choice's [option] button (Settings › style must be open). */
const searchSeg = (name, option) => [...document.querySelectorAll(`[data-setting="${name}"] .scr-seg button`)].find((b) => b.textContent.trim() === option);

/** One pick of [option] on [c].name: the choice, the spots ([c].was: before), then home with Settings shut. */
async function searchSettingPick(c, option, want) {
  const { S, Sc, mode, name, was } = c;
  const b = searchSeg(name, option);
  if (!b) return [`"${name}" has no "${option}"`];
  b.click();
  await sleep(300);
  const other = mode === "mobile" ? "unfolded" : "mobile";
  const at = `"${name}" → "${option}"`;
  const checks = [
    [searchSeg(name, option)?.classList.contains("on"), `${at}: not shown picked`],
    [S.searchSpot[mode].value === want, `${at}: the spot is "${S.searchSpot[mode].value}", not "${want}"`],
    [S.searchSpot[other].value === was[other], `${at}: the other screen's spot changed to "${S.searchSpot[other].value}"`],
  ];
  Sc.screens.value = [];
  await sleep(400);
  const docked = !!document.querySelector(".home > .dock .dock-search");
  const bar = !!document.querySelector(".home > .bar");
  checks.push([docked === (want === "dock"), `${at}: home's dock button ${docked ? "shown" : "missing"}`], [bar === (want === "bar"), `${at}: home's bar ${bar ? "shown" : "missing"}`]);
  Sc.screens.value = ["settings", "style"];
  await sleep(400);
  return checks.filter(([ok]) => !ok).map(([, why]) => why);
}

export async function searchSettingCheck() {
  const S = await importShim("./state.ts");
  const Sc = await importShim("./screens.ts");
  const mode = S.dockMode.value === "unfolded" ? "unfolded" : "mobile";
  const name = mode === "mobile" ? "folded search" : "unfolded search";
  const was = { mobile: S.searchSpot.mobile.value, unfolded: S.searchSpot.unfolded.value };
  const fails = [];
  try {
    Sc.screens.value = ["settings", "style"];
    await sleep(400);
    for (const label of ["folded search", "unfolded search"]) if (!document.querySelector(`[data-setting="${label}"]`)) fails.push(`Settings › style has no "${label}" choice`);
    for (const [option, want] of [["dock button", "dock"], ["bar", "bar"], ["dock button", "dock"]]) fails.push(...(await searchSettingPick({ S, Sc, mode, name, was }, option, want)));
  } finally {
    Sc.screens.value = [];
    S.searchSpot.mobile.value = was.mobile;
    S.searchSpot.unfolded.value = was.unfolded;
  }
  return fails.map((f) => `${mode}: ${f}`);
}

/*
 * SB2 (the user, 11-03, asked three times: "search bar" back on the folded screen; ask-1a19e12d892: "a toggle in the
 * settings, so that I can use the bar if I want to"). gate.mjs's search-bar-back-* cases, reloads between:
 * sbFresh (nothing stored) -> sbIs("bar"); sbOldDock (a folded "dock" stored, no powos.search.spot.v2) -> sbIs("bar");
 * sbPick(mode, "dock") -> sbIs("dock") after a reload (the migration ran once, the pick sticks); unfolded the same plus
 * belowDock "1" (the device's state) - the dock button and no bar.
 */
export function sbFresh() {
  for (const k of ["mobile", "unfolded", "migrated", "v2"]) localStorage.removeItem(`powos.search.spot.${k}`);
}
export function sbOldDock() {
  localStorage.setItem("powos.search.spot.mobile", "dock");
  localStorage.setItem("powos.search.spot.unfolded", "bar");
  localStorage.setItem("powos.search.spot.migrated", "1");
  localStorage.setItem("powos.search.belowDock", "1");
  localStorage.removeItem("powos.search.spot.v2");
}
export async function sbPick(v) {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/searchwidget.tsx");
  await W.pickSearchSpot(S.dockMode.value === "unfolded" ? "unfolded" : "mobile", v);
  await sleep(400);
}
/** Shown on screen: a box bigger than a speck, not hidden. */
const sbShown = (e) => {
  const b = e?.getBoundingClientRect();
  return !!b && b.width > 2 && b.height > 2 && getComputedStyle(e).visibility !== "hidden";
};
/** This screen's spot is [want], stored so (or unset for the bar), and home shows it: the dock's button and no bar, or the bar and no button. */
export async function sbIs(want, at) {
  const S = await importShim("./state.ts");
  const mode = S.dockMode.value === "unfolded" ? "unfolded" : "mobile";
  await sleep(400);
  const dock = sbShown(document.querySelector(".home > .dock .dock-search, .home .dock .app.dock-search"));
  const bar = sbShown(document.querySelector(".home > .bar"));
  const kept = localStorage.getItem(`powos.search.spot.${mode}`) ?? "bar";
  const checks = [
    [S.searchSpot[mode].value === want, `spot "${S.searchSpot[mode].value}", not "${want}"`],
    [kept === want, `stored "${kept}"`],
    [dock === (want === "dock"), `home's dock button ${dock ? "shown" : "missing"}`],
    [bar === (want === "bar"), `home's bar ${bar ? "shown" : "missing"}`],
  ];
  return checks.filter(([ok]) => !ok).map(([, why]) => `${mode} ${at}: ${why}`);
}

/**
 * BF1 (the user, 11-03 11:49: "Move the search bar so that it's at the same height as the manager search bar"): the one
 * bar's pill on home (spot "bar", under the dock: belowDock), on the launcher and on PowOS AI's page - the same bottom
 * and height (±1 px; --bar-foot, shell.css), so swiping home <-> the AI page or opening the launcher it doesn't move.
 * [below]: the pill under the dock ("1") or over it (""). Failures, empty when it holds; with the rects measured.
 */
/** The one bar's pill at [page] with the launcher [drawer] open (1) or not: its bottom off the screen's foot and height. */
async function bfPill(S, page, drawer) {
  S.page.value = page;
  S.drawer.value = drawer;
  await sleep(900);
  const b = document.querySelector(".home > .bar .bar-pill")?.getBoundingClientRect();
  return b ? { left: Math.round(b.left), width: Math.round(b.width), bottom: Math.round(innerHeight - b.bottom), height: Math.round(b.height) } : null;
}

/** OE1: the pill on PowOS AI's page with its [tab] open (Chat, Agents, Progress, Devices). */
async function bfAiTab(S, tab) {
  S.aiScreen.value = tab;
  return bfPill(S, -1, 0);
}

export async function barFootSame(below = "1") {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/searchwidget.tsx");
  const mode = S.dockMode.value === "unfolded" ? "unfolded" : "mobile";
  window.__mockEvents?.emit("system.insets", { top: 45, bottom: 16, left: 0, right: 0, keyboard: 0 });
  await W.pickSearchSpot(mode, "bar");
  W.footBelow.value = below;
  const home = await bfPill(S, 0, 0);
  // OE1 (the user, 11-03 21:14: "Why is the search [bar] just under the chat here?"): on every tab of the AI page the
  // pill is home's own rect - x, width, foot and height - never fitted to the chat column.
  const tabs = {};
  for (const t of ["chat", "fleet", "progress", "devices"]) tabs[`ai-${t}`] = await bfAiTab(S, t);
  S.aiScreen.value = "chat";
  await bfPill(S, 0, 0);
  const launcher = await bfPill(S, 0, 1);
  await bfPill(S, 0, 0);
  const at = `${mode}, pill ${below ? "under" : "over"} the dock`;
  const gap = below ? await bfDockGap() : [];
  console.info(`[barFootSame] ${at}: dock gap ${JSON.stringify(gap)}`);
  console.info(`[barFootSame] ${at}: home ${JSON.stringify(home)} ${JSON.stringify(tabs)} launcher ${JSON.stringify(launcher)}`);
  // Over the dock, home's own pill sits above it (the launcher's comes down to the foot, the dock gone): there the
  // launcher keeps the bottom/height check against the AI page's foot only.
  return [...bfCompare(at, home, tabs), ...(below ? bfCompare(at, home, { launcher }) : []), ...bfGapFails(at, gap)];
}

/**
 * DG1 (the user, 11-03 21:30: "Now the icons are floating too far up over the search bar"): the pill under the dock, the
 * dock's foot to the pill's top is the design's gap - the same as with the bar not dropped to the foot (--bar-drop 0).
 */
async function bfDockGap() {
  const home = document.querySelector(".home");
  // Wide home's one-row foot sets dock and pill side by side (--bar-drop 0 there): no gap over the pill to keep.
  if (home.classList.contains("wide")) return [];
  const one = () => {
    const d = document.querySelector(".home > .dock:not(.dock-tray)")?.getBoundingClientRect();
    const p = document.querySelector(".home > .bar .bar-pill")?.getBoundingClientRect();
    return d && p ? Math.round(p.top - d.bottom) : null;
  };
  const now = one();
  home.style.setProperty("--bar-drop", "0px");
  await sleep(100);
  const design = one();
  home.style.removeProperty("--bar-drop");
  await sleep(100);
  return [now, design];
}

const bfGapFails = (at, g) => (g.length && (g[0] == null || Math.abs(g[0] - g[1]) > 1) ? [`${at}: dock-to-pill gap ${g[0]} px, the design's ${g[1]} px`] : []);

/** Each of [pills] at the AI page's [ai] bottom and height (±1 px), else what's off. */
function bfCompare(at, ai, pills) {
  const all = { ai, ...pills };
  const none = Object.keys(all).filter((k) => !all[k]);
  if (none.length) return [`${at}: no pill on ${none.join(", ")}`];
  return Object.entries(pills)
    .filter(([, r]) => ["left", "width", "bottom", "height"].some((k) => Math.abs(r[k] - ai[k]) > 1))
    .map(([name, r]) => `${at}: ${name}'s pill ${JSON.stringify(r)}; home's ${JSON.stringify(ai)}`);
}

/** SF1 (the user, 11-03 11:49: "Where is that setting? I couldn't find it in a setting."): a typed [query] in search. */
async function sfFinds(query, label) {
  const Q = await importShim("./search.ts");
  const hit = Q.settingDestinations.find((d) => d.label === label && Q.searchRank(query, d.label, d.keywords) >= 0);
  return hit ? [] : [`search "${query}" doesn't list "${label}"`];
}

/** [target] opened on the style screen: its row there, highlighted, in the scroller's view. */
async function sfOpens(target) {
  const R = await importShim("./screens.ts");
  const Q = await importShim("./search.ts");
  const d = Q.settingDestinations.find((x) => x.target === target && x.screen === "style");
  R.openScreen(d.screen, d.target);
  await sleep(900);
  const row = [...document.querySelectorAll("[data-setting]")].find((e) => e.dataset.setting === target);
  const b = row?.getBoundingClientRect();
  const fails = [];
  if (!row) fails.push(`"${target}": no row on the style screen`);
  else if (row.dataset.searchHighlight !== "true") fails.push(`"${target}": row not highlighted`);
  else if (b.top < 0 || b.bottom > innerHeight) fails.push(`"${target}": row off screen (${Math.round(b.top)}..${Math.round(b.bottom)})`);
  R.closeScreens();
  await sleep(400);
  return fails;
}

/** The search's own menu flips its spot at once: [open] opens it, its one item picked; [want] the spot after. */
async function sfMenuFlips(open, want, at) {
  const S = await importShim("./state.ts");
  const mode = S.dockMode.value === "unfolded" ? "unfolded" : "mobile";
  open();
  await sleep(400);
  const item = document.querySelector(".search-spot-menu .menu-item");
  if (!item) return [`${at}: no menu`];
  const label = want === "dock" ? "Show as dock button" : "Show as bar";
  if (item.textContent.trim() !== label) return [`${at}: menu says "${item.textContent.trim()}", not "${label}"`];
  item.click();
  const now = S.searchSpot[mode].value;
  await sleep(500);
  return now === want ? [] : [`${at}: picked "${label}", spot "${now}" (not at once)`];
}

/** SF1: the search's spot is found where the user looks - Settings search, the settings list, the bar/button itself. */
export async function searchFindable() {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/searchwidget.tsx");
  const mode = S.dockMode.value === "unfolded" ? "unfolded" : "mobile";
  const prefix = mode === "unfolded" ? "Unfolded" : "Folded";
  const fails = [];
  for (const q of ["search", "search bar", "dock button", "bar"]) fails.push(...(await sfFinds(q, `${prefix} search: bar / dock button`)));
  fails.push(...(await sfFinds("dock", "folded dock position")));
  fails.push(...(await sfOpens(mode === "unfolded" ? "unfolded search" : "folded search")));
  fails.push(...(await sfOpens("home")));
  await W.pickSearchSpot(mode, "bar");
  await sleep(400);
  // A long press on home's bar (the WebView's contextmenu).
  const pill = () => document.querySelector(".home > .bar .bar-pill");
  fails.push(...(await sfMenuFlips(() => pill()?.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })), "dock", "long press on the bar")));
  // Edit mode's tap on the dock's button (its hold outside edit mode stays dictation).
  S.editing.value = true;
  await sleep(400);
  const btn = document.querySelector(".home .dock .dock-search");
  fails.push(...(await sfMenuFlips(() => btn && (fire(btn, "pointerdown"), fire(btn, "pointerup")), "bar", "edit mode tap on the dock button")));
  S.editing.value = false;
  await sleep(300);
  return fails;
}

/**
 * PD1 (the user, 2026-11-03: "the active windows should not show in the dock in mobile ... the dock should always just
 * show the pinned ones. The open ones should just show at the front of the recent ones"): with home's search as the
 * bar, two open apps that aren't pinned leave the folded dock's pinned row as it was (same cells, none of theirs) and
 * lead its recent section, top-most first; unfolded keeps them in the pinned row (that dock is unchanged).
 */
export async function pd1Check(label) {
  const S = await importShim("./state.ts");
  const was = { dock: S.dock.value, windows: S.windows.value };
  S.dock.value = S.recent.value.slice(0, 4);
  S.searchTry.value = "bar";
  await sleep(300);
  const row = () => document.querySelector(".home > .dock:not(.dock-tray) .dock-pages > .dock-page:not(.dock-recent)");
  const keys = (el) => [...(el?.querySelectorAll(".app[data-key]") ?? [])].map((c) => c.dataset.key);
  const before = keys(row());
  const fails = [];
  if (before.length !== 4) fails.push(`pinned row has ${before.length} apps, not the 4 pinned`);
  const extra = [...S.byKey.value.keys()].filter((k) => !S.dock.value.includes(k) && !S.recent.value.includes(k)).slice(0, 2);
  if (extra.length !== 2) fails.push("no 2 unpinned apps to open");
  // Top-most first: extra[1] is the one in front, used last.
  S.windows.value = [extra[1], extra[0]].map((k, i) => ({ id: 910 + i, pkg: k, label: k, minimised: false, app: k }));
  await sleep(300);
  const after = keys(row());
  const recent = keys(document.querySelector(".home .dock .dock-recent"));
  if (label === "folded") {
    if (after.join() !== before.join()) fails.push(`pinned row went [${before}] -> [${after}]`);
    if (recent.slice(0, 2).join() !== [extra[1], extra[0]].join()) fails.push(`recents start [${recent.slice(0, 2)}], not the open [${extra[1]},${extra[0]}]`);
    if (new Set(recent).size !== recent.length) fails.push(`an app twice in the recents: ${recent}`);
  } else if (!extra.every((k) => after.includes(k))) fails.push(`unfolded pinned row [${after}] lost the open apps [${extra}]`);
  S.windows.value = was.windows;
  S.searchTry.value = "";
  S.dock.value = was.dock;
  return fails.map((f) => `pd1 ${label}: ${f}`);
}
