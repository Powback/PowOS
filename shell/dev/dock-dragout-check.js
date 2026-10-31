/**
 * A dock app dragged out of the dock (ui/dockout.tsx; the user, 2026-10-31 03:00: "I should be able to tap and hold an
 * app and drag it out of the taskbar to open it in split view or in a floating window"). Runs in the page: gate.mjs's
 * dock-dragout-* cases. The carry is grid.tsx's own (startCarry, then window pointer events, as moveInDock hands over).
 *
 * - "split" (index.html?mode=pull, a screen wider than tall, the mock's top task Chrome in front): to the left half -
 *   the ghost on the left half, tasks.split(dragged, front); an app with no task is launched and its task split.
 * - "float" (?mode=pull folded, Chrome in front): to the middle - tasks.float(its task).
 * - "window" (home unfolded, a mock web-windows host, a window open on the page): to the middle - a new .webwindow.
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
  await sleep(250); // the ghost's 140 ms glide between zones (shell.css .ww-drop)
  const ghost = document.querySelector(".ww-drop.dock-out");
  const seen = ghost ? { zone: ghost.dataset.zone, rect: ghost.getBoundingClientRect() } : null;
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

export async function dockDragOut(kind) {
  const e = await env();
  e.O.TASK_WAIT.ms = 3000;
  const fails = [];
  await { split: splitCase, float: floatCase, window: windowCase, home: homeCase }[kind](e, fails, { x: innerWidth / 2, y: innerHeight - 30 });
  return fails;
}
