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
  await sleep(300);
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
  const fails = folded && !document.querySelector(".pull-screen .dock .dock-search-face") ? ["the overlay's dock has no button slot"] : [];
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

/** A fresh device: folded docked, unfolded the bar - on screen too. */
export async function searchSpotDefaults() {
  const S = await importShim("./state.ts");
  const fails = [];
  if (S.searchSpot.mobile.value !== "dock") fails.push(`folded default "${S.searchSpot.mobile.value}", not "dock"`);
  if (S.searchSpot.unfolded.value !== "bar") fails.push(`unfolded default "${S.searchSpot.unfolded.value}", not "bar"`);
  const docked = S.dockMode.value === "mobile";
  await sleep(200);
  if (!!document.querySelector(".home > .dock .dock-search") !== docked) fails.push(`${S.dockMode.value} default: dock button ${docked ? "missing" : "shown"}`);
  if (!!document.querySelector(".home > .bar") === docked) fails.push(`${S.dockMode.value} default: bar ${docked ? "shown" : "missing"}`);
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
  const spot = G.placeNewCells(S.home.value.columns, 1);
  const g = G.geometry.value;
  const x = g.left + g.pad + (spot.cell.w * g.cellW) / 2 + spot.cell.x * g.cellW;
  const y = g.top + g.pad + (spot.cell.h * g.cellH) / 2 + spot.cell.y * g.cellH;
  await drag(btn, x, y);
  await sleep(200);
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
