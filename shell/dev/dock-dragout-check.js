/**
 * A dock app dragged out of the dock (ui/dockout.tsx; the user, 2026-10-31 03:00: "I should be able to tap and hold an
 * app and drag it out of the taskbar to open it in split view or in a floating window"). Runs in the page: gate.mjs's
 * dock-dragout-* cases. The carry is grid.tsx's own (startCarry, then window pointer events, as moveInDock hands over).
 *
 * - "split" (index.html?mode=pull, a screen wider than tall, the mock's top task Chrome in front): to the left half -
 *   the ghost on the left half, tasks.split(dragged, front); an app with no task is launched and its task split.
 * - "float" (?mode=pull folded, Chrome in front): to the middle - tasks.float(its task).
 * - "window" (home unfolded, a mock web-windows host, a window open on the page): to the middle - a new .webwindow.
 * - "place" (home unfolded, two widgets, a window open): let go at the top, bottom, left, right, in a free region and
 *   over a widget - a web window opens exactly on the last ghost (+-1 px): the free region there (touching no widget)
 *   or, over a widget, floating centred under the finger; no home drop spot meanwhile.
 * - "home" (home folded, no app in front): onto home's grid - unpinned and placed there as before, no ghost, no split
 *   or float; back onto the dock - neither split nor float.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frames = (n) => window.__gw.frames(n);

async function env() {
  const mod = window.__gw.mod;
  const [S, G, B, O, W, H] = await Promise.all([mod("./state.ts"), mod("./ui/grid.tsx"), mod("./bridge.ts"), mod("./ui/dockout.tsx"), mod("./ui/webwindows.tsx"), mod("./hosts/wide.ts")]);
  const powos = B.powos;
  const calls = { split: [], float: [], launch: [] };
  const extra = [];
  const list = powos.tasks.list;
  powos.tasks.split = async (a, b) => (calls.split.push([a, b]), true);
  powos.tasks.float = async (id) => (calls.float.push(id), true);
  powos.tasks.list = async () => [...(await list()), ...extra];
  // A launch of an app with no task makes one (as Android's recents update after a start).
  powos.apps.launch = async (key) => {
    calls.launch.push(key);
    if (!extra.some((t) => t.key === key)) setTimeout(() => extra.push({ id: 200 + extra.length, key, label: key, icon: null, snapshot: "" }), 300);
  };
  return { S, G, O, W, H, powos, calls };
}

let pid = 40;
/** A dock app [key] carried from [from] through [path] and let go at its end; the ghost's zone seen at the last move. */
async function drag(G, key, from, path) {
  const id = ++pid;
  const ev = (type, p) => new PointerEvent(type, { pointerId: id, clientX: p.x, clientY: p.y, bubbles: true });
  G.startCarry({ app: key, fromDock: true }, ev("pointerdown", from), { x: 30, y: 30 });
  for (const p of path) (window.dispatchEvent(ev("pointermove", p)), await frames(1));
  await sleep(250);
  // The ghost's spring between targets (shell.css .ww-drop) ended: a busy machine runs it late, so wait for it.
  const ghost = document.querySelector(".ww-drop.dock-out");
  await Promise.all((ghost?.getAnimations() ?? []).map((a) => a.finished.catch(() => {})));
  const seen = ghost ? { zone: ghost.dataset.zone, place: ghost.dataset.place, rect: ghost.getBoundingClientRect(), spot: !!document.querySelector(".drop-spot") } : null;
  window.dispatchEvent(ev("pointerup", path.at(-1)));
  return seen;
}

/** Waits up to [ms] for [ok]. */
async function until(ok, ms = 4000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(50)) if (ok()) return true;
  return ok();
}

/** Waits for the first call in [list], then judges it against [want] (as a string); [what]: the step, for its failure. */
async function firstCall(fails, list, want, what) {
  if (!(await until(() => list.length))) return void fails.push(`${what}: never called`);
  if (String(list[0]) !== want) fails.push(`${what}: called with (${list[0]}), want (${want})`);
}

/** The ghost [seen] shows [zone]: else a failure naming what it shows. */
function ghostIs(fails, seen, zone, what) {
  if (seen?.zone !== zone) fails.push(`${what}: the ghost shows ${seen?.zone ?? "nothing"}, not ${zone}`);
}

/** "split": the left half with the app in front (ghost, then tasks.split), and an app with no task on the right half. */
async function splitCase({ G, calls }, fails, dockAt) {
  const w = innerWidth, h = innerHeight;
  const seen = await drag(G, "a:signal", dockAt, [{ x: w / 2, y: h - 200 }, { x: 60, y: h / 2 }]);
  ghostIs(fails, seen, "first", "dragged to the left half");
  if (seen && (seen.rect.left > 1 || Math.abs(seen.rect.width - w / 2) > 2)) fails.push(`the left-half ghost is at ${Math.round(seen.rect.left)}+${Math.round(seen.rect.width)}, not 0+${w / 2}`);
  await firstCall(fails, calls.split, "101,100", "left half: tasks.split (101 Signal dragged, 100 Chrome in front)");
  if (document.querySelector(".ww-drop.dock-out")) fails.push("the ghost stays after the drop");
  // An app with no task yet: launched, then its task split (here on the right half: the front app first).
  calls.split.length = 0;
  await drag(G, "a:gate.new", dockAt, [{ x: w / 2, y: h - 200 }, { x: w - 60, y: h / 2 }]);
  await firstCall(fails, calls.split, "100,200", `right half, an app with no task (launches: ${calls.launch}): tasks.split (100 front, 200 its new task)`);
}

/** "float": folded, the middle floats the app's task; back onto the dock is the dock's (no split, no float). */
async function floatCase({ S, G, calls }, fails, dockAt) {
  const w = innerWidth, h = innerHeight;
  if (!S.dock.value.length) S.setDock([...S.byKey.value.keys()].filter((k) => k.startsWith("a:")).slice(0, 4));
  await window.__gw.settled();
  const seen = await drag(G, "a:spotify", dockAt, [{ x: w / 2, y: h - 200 }, { x: w / 2, y: h / 2 }]);
  ghostIs(fails, seen, "window", "dragged to the middle");
  await firstCall(fails, calls.float, "102", "folded, middle: tasks.float (102 Spotify's task)");
}

/** "home": no app in front - a dock app let go on home's grid is unpinned and put there (the old way), nothing opens. */
async function homeCase({ S, G, powos, calls }, fails, dockAt) {
  const keys = [...S.byKey.value.keys()].filter((k) => k.startsWith("a:"));
  S.setDock(keys.slice(0, 4));
  await window.__gw.settled();
  const key = S.dock.value[1];
  const added = [];
  const add = powos.home.add;
  powos.home.add = async (app, pg, cell) => (added.push([app, pg, cell]), add(app, pg, cell));
  const at = { x: innerWidth / 2, y: innerHeight * 0.45 };
  const seen = await drag(G, key, dockAt, [{ x: innerWidth / 2, y: innerHeight - 200 }, at]);
  if (seen) fails.push(`on home with no app in front, a ghost (${seen.zone}) shows`);
  await sleep(600);
  if (S.dock.value.includes(key)) fails.push(`let go on home's grid, ${key} is still pinned to the dock`);
  if (!added.some(([app]) => app === key)) fails.push(`let go on home's grid, ${key} wasn't put on home (home.add: ${JSON.stringify(added)})`);
  if (calls.split.length || calls.float.length || calls.launch.length) fails.push(`let go on home's grid: split ${calls.split} float ${calls.float} launch ${calls.launch}`);
  powos.home.add = add;
  await backOnDock({ S, G, calls }, fails);
}

/** Carried off the dock and back onto it: the dock's reorder / cancel, never a split or a window. */
async function backOnDock({ S, G, calls }, fails) {
  const dock = document.querySelector(".home .dock")?.getBoundingClientRect();
  if (!dock?.width) return void fails.push("no dock on home to drop back on");
  const on = { x: dock.left + dock.width / 2, y: dock.top + dock.height / 2 };
  await drag(G, S.dock.value[0], on, [{ x: innerWidth / 2, y: innerHeight / 2 }, on]);
  await sleep(600);
  if (calls.split.length || calls.float.length) fails.push(`dropped back on the dock: split ${calls.split} float ${calls.float}`);
}

/** "window": unfolded with web windows on, the middle opens a web window, never Android's floating one. */
async function windowCase({ S, G, W, H, powos, calls }, fails, dockAt) {
  H.wideHome.value = true;
  // A window open on this page: the dock is a taskbar over it (dockout.tsx overApps).
  W.webWins.value = [{ id: 951, key: "a:gate.open", label: "Open", page: S.pages.value[S.page.value], x: 80, y: 120, w: 300, h: 240, live: true }];
  powos.webwindows = { enabled: async () => true, open: async () => 77, close: async () => true, input: async () => true, minimise: async () => true, restore: async () => true };
  const before = document.querySelectorAll(".webwindow").length;
  await drag(G, "a:maps", dockAt, [{ x: innerWidth / 2, y: innerHeight - 200 }, { x: innerWidth / 2, y: innerHeight / 2 }]);
  if (!(await until(() => document.querySelectorAll(".webwindow").length > before))) fails.push(`unfolded, let go in the middle: no new .webwindow (${W.webWins.value.length} windows in the model)`);
  if (calls.float.length) fails.push(`unfolded, middle: tasks.float(${calls.float}) instead of a web window`);
}

/** "place": unfolded, every drop opens its web window exactly on the ghost (WG1, the user 10-31 20:19). */
async function placeCase(e, fails, dockAt) {
  const { W } = e;
  const widgets = await placeSetup(e);
  const a = W.tileArea();
  const w1 = widgets[0];
  const at = { top: [(a.left + a.right) / 2, a.top + 30], bottom: [(a.left + a.right) / 2, a.bottom - 40], left: [a.left + 4, (a.top + a.bottom) / 2], right: [a.right - 4, (a.top + a.bottom) / 2], free: [a.left + (a.right - a.left) * 0.4, a.top + (a.bottom - a.top) * 0.6], widget: [w1.x + w1.w / 2, w1.y + w1.h / 2] };
  for (const [name, [x, y]] of Object.entries(at)) fails.push(...(await placeDrop(e, widgets, dockAt, { name, x, y })));
}

/** Unfolded home with two widgets and a window open (the dock is a taskbar); the widgets' rects (viewport px). */
async function placeSetup({ S, G, W, H, powos }) {
  H.wideHome.value = true;
  const page = S.pages.value[S.page.value];
  const cols = S.home.value.columns;
  const wid = (k, cell) => ({ key: `widget:gate.dp${k}`, kind: "widget", name: `gate-dp${k}`, page, cell, resizable: true, minSize: [1, 1], size: [cell.w, cell.h] });
  S.home.value = { ...S.home.value, items: [wid(1, { x: 0, y: 0, w: 2, h: 2 }), wid(2, { x: cols - 2, y: 2, w: 2, h: 2 })] };
  W.tilings.value = {};
  W.webWins.value = [{ id: 951, key: "a:gate.open", label: "Open", page, x: 300, y: 500, w: 200, h: 160, live: true }];
  let next = 700;
  powos.webwindows = { enabled: async () => true, open: async () => ++next, close: async () => true, input: async () => true, minimise: async () => true, restore: async () => true };
  await window.__gw.settled();
  const g = G.geometry.value;
  return S.home.value.items.map(({ cell: c }) => ({ x: g.left + g.pad + c.x * g.cellW, y: g.top + g.pad + c.y * g.cellH, w: c.w * g.cellW, h: c.h * g.cellH }));
}

const hit = (a, b) => a.x < b.x + b.w - 0.5 && b.x < a.x + a.w - 0.5 && a.y < b.y + b.h - 0.5 && b.y < a.y + a.h - 0.5;

/** The ghost [seen] (at [ghost]) of drop [name]: floating over a widget, a free region on none, no home spot. */
function ghostFails(seen, ghost, widgets, name) {
  const fails = [];
  if (name === "widget" && seen.place !== "float") fails.push(`over a widget: the ghost is ${seen.place}, not floating`);
  if (seen.place === "region" && widgets.some((w) => hit(ghost, w))) fails.push(`${name}: the free region ghost ${JSON.stringify(ghost)} overlaps a widget`);
  if (seen.spot) fails.push(`${name}: home's drop spot shows beside the ghost`);
  return fails;
}

/** One dock drag-out let go at [d] (x, y): its ghost judged, then the web window it opens against the ghost. */
async function placeDrop({ G, W }, widgets, dockAt, d) {
  const key = `a:gate.place.${d.name}`;
  const seen = await drag(G, key, dockAt, [{ x: innerWidth / 2, y: innerHeight - 200 }, { x: d.x, y: d.y }]);
  if (!seen) return [`${d.name}: no ghost`];
  const ghost = { x: seen.rect.left, y: seen.rect.top, w: seen.rect.width, h: seen.rect.height };
  const fails = ghostFails(seen, ghost, widgets, d.name);
  if (!(await until(() => W.webWins.value.some((v) => v.key === key)))) return [...fails, `${d.name}: no web window opened`];
  await window.__gw.frames(2);
  const o = document.querySelector(".page:not(.away)").getBoundingClientRect();
  const v = W.webWins.value.find((u) => u.key === key);
  const got = { x: o.left + v.x, y: o.top + v.y, w: v.w * (v.scale ?? 1), h: v.h * (v.scale ?? 1) };
  if (["x", "y", "w", "h"].some((k) => Math.abs(got[k] - ghost[k]) > 1)) fails.push(`${d.name}: the window opened at ${JSON.stringify(got)}, not its ghost ${JSON.stringify(ghost)}`);
  return fails;
}

export async function dockDragOut(kind) {
  const e = await env();
  e.O.TASK_WAIT.ms = 3000;
  const fails = [];
  await { split: splitCase, float: floatCase, window: windowCase, home: homeCase, place: placeCase }[kind](e, fails, { x: innerWidth / 2, y: innerHeight - 30 });
  return fails;
}
