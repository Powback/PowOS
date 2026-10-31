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
  if (i !== Math.floor(cells.length / 2)) return `button at cell ${i} of ${cells.length}, not the centre`;
  if (position !== "bottom") return "";
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

/** Home's page: the host's launcher overlay recorded, not opened (the browser has no host); speech calls counted. */
async function record() {
  const { powos } = await importShim("./bridge.ts");
  const asked = [];
  const speech = { hold: 0, stop: 0 };
  powos.pull.open = async (kind, how) => (asked.push({ kind, how }), true);
  const { hold, stop } = powos.speech;
  powos.speech.hold = async () => (speech.hold++, hold());
  powos.speech.stop = async () => (speech.stop++, stop());
  return { asked, speech };
}

/** A tap: the launcher opened with its field focused (pull.open { search, from }), no bar expanded in place. */
async function tapOpens(btn, asked) {
  fire(btn, "pointerdown");
  fire(btn, "pointerup");
  await sleep(100);
  const tap = asked.shift();
  if (!tap) return ["a tap didn't open the launcher"];
  const ok = tap.how?.search && !tap.how.listen && tap.how.from?.width;
  return ok ? [] : [`a tap opened it as ${JSON.stringify(tap.how)}`];
}

/** Held 300 ms: the launcher dictating ({ listen }); let go soon after, the dictation goes on (no stop). */
async function holdDictates(btn, asked, speech) {
  fire(btn, "pointerdown");
  await sleep(400);
  const hold = asked.shift();
  fire(btn, "pointerup");
  await sleep(100);
  const fails = hold?.how?.listen ? [] : [`held 300 ms: ${hold ? JSON.stringify(hold.how) : "no launcher"}, not dictating`];
  if (speech.stop) fails.push("a short hold let go stopped the dictation (it goes on as a tap's)");
  return fails;
}

/** Still held: push-to-talk (speech.hold); let go at 1.5 s, the dictation stops (speech.stop, never a send). */
async function pushToTalk(btn, asked, speech) {
  fire(btn, "pointerdown");
  await sleep(1500);
  asked.length = 0;
  const fails = speech.hold ? [] : ["held 1.5 s: not push-to-talk (no speech.hold)"];
  fire(btn, "pointerup");
  await sleep(50);
  if (speech.stop !== 1) fails.push(`push-to-talk let go: ${speech.stop} stops`);
  return fails;
}

/** A swipe up from it: the host's pull, following the finger (pull.drive), never a tap's open. */
async function swipeUp(btn, asked) {
  const { powos } = await importShim("./bridge.ts");
  const drives = [];
  powos.pull.drive = async (phase, arg) => (drives.push([phase, arg]), true);
  fire(btn, "pointerdown");
  for (let i = 1; i <= 6; i++) fire(btn, "pointermove", 0, -i * 20);
  fire(btn, "pointerup", 0, -120);
  await sleep(50);
  const phases = drives.map((d) => d[0]).join(",");
  const fails = [];
  if (!/^begin,(drag,)+end$/.test(phases)) fails.push(`swipe up: drove ${phases || "nothing"}`);
  else if (drives.at(-1)[1] !== true) fails.push("swipe up 120 px: let go, it didn't open");
  if (asked.length) fails.push("swipe up: also a tap's open");
  return fails;
}

/** DS2 (the user, 01:53): tap, hold, push-to-talk and a swipe up from the button. */
async function pressOpens(position) {
  const btn = document.querySelector(".home > .dock .dock-search");
  if (!btn) return [];
  const { asked, speech } = await record();
  const fails = [...(await tapOpens(btn, asked)), ...(await holdDictates(btn, asked, speech)), ...(await pushToTalk(btn, asked, speech)), ...(await swipeUp(btn, asked))];
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
  fails.push(...(await pressOpens(position)), ...(await backToBar(S)));
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

/** DK2: a side column's pinned page, then .dock-sep, then the recent section. */
function separated(row) {
  const sep = document.querySelector(".home > .dock .dock-sep");
  if (!sep) return ["no separator between the pinned group and the recent apps"];
  const fails = [];
  if (sep.previousElementSibling !== row) fails.push("the separator isn't right after the pinned group");
  if (!sep.nextElementSibling?.matches(".dock-recent")) fails.push("the recent section isn't right after the separator");
  const r = sep.getBoundingClientRect();
  if (!(r.width > 0 && r.height > 0 && r.height <= 3)) fails.push(`the separator is ${Math.round(r.width)}x${Math.round(r.height)}, not a short thin line`);
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
 * as they were and show in the recent section; a side column has the separator between the groups.
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
