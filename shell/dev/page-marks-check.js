/**
 * PI1 (ui/pagemarks.ts; the user, 2026-10-31 01:34-01:35): the dock marks the apps open on the home page on screen.
 * Runs in home's page (index.html): gate.mjs's page-marks-* cases. Unfolded: two web windows, app A's on the first page
 * and app B's on the second; on page 1 A has the pill (.mark-here) at full opacity, B the dot (.mark-away) faded, the
 * search button unfaded; on page 2 they swap; with no windows nothing fades. Folded: a running app gets the dot only,
 * nothing fades. Each step returns its failures (empty when it holds); gate.mjs renders between them.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let saved = null;

/**
 * Once the dock's opacity/pill transitions are done (no running animation in the dock, max 3 s): a fixed 400 ms read
 * mid-transition under load (10-31 13:2x: "faded to 0.909", "the pill is 17.3px wide", passing alone).
 */
async function settled() {
  await sleep(200);
  const dock = () => document.querySelector(".home > .dock:not(.dock-tray)");
  for (const end = performance.now() + 3000; performance.now() < end; ) {
    const d = dock();
    if (!d || !d.getAnimations({ subtree: true }).length) return;
    await sleep(16);
  }
}

const cell = (key) => document.querySelector(`.home > .dock:not(.dock-tray) .app[data-key="${CSS.escape(key)}"]`);
const iconOpacity = (el) => Number(getComputedStyle(el.querySelector(".app-icon")).opacity);

/** Pins A and B, the search button in the dock, and (unfolded) A's window on page 1, B's on page 2. */
export async function pageMarksSetup(position, unfolded) {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/webwindows.tsx");
  const R = await importShim("./ui/running.ts");
  saved = { dock: S.dock.value, page: S.page.value, running: R.running.value };
  const [a, b] = S.recent.value.filter((k) => S.byKey.value.has(k));
  S.dock.value = [...new Set([a, b, ...S.recent.value.slice(2, 6)])];
  S.dockTry.value = position;
  S.searchTry.value = "dock";
  S.page.value = 0;
  if (unfolded) {
    const [p1, p2] = S.pages.value;
    W.webWins.value = [
      { id: 911, key: a, label: "A", page: p1, x: 120, y: 120, w: 360, h: 300 },
      { id: 912, key: b, label: "B", page: p2, x: 420, y: 160, w: 360, h: 300 },
    ];
  } else R.running.value = { [b]: "running" };
  await sleep(400);
  return { a, b, pages: S.pages.value.length };
}

/** [here]'s cell: the pill, wide, at full opacity. */
function hereFails(at, key) {
  const h = cell(key);
  if (!h) return [`${at}: no dock cell for ${key}`];
  const fails = [];
  if (!h.classList.contains("mark-here")) fails.push(`${at}: ${key} (window here) has no pill: ${h.className}`);
  if (iconOpacity(h) < 0.99) fails.push(`${at}: ${key} (window here) faded to ${iconOpacity(h)}`);
  const pill = getComputedStyle(h.querySelector(".app-icon"), "::after");
  if (parseFloat(pill.width) < 18) fails.push(`${at}: the pill is ${pill.width} wide, want a wide one`);
  return fails;
}

/** [away]'s cell: the dot, at ~0.65 when [fades], else full. */
function awayFails(at, key, fades) {
  const w = cell(key);
  if (!w) return [`${at}: no dock cell for ${key}`];
  const fails = [];
  if (!w.classList.contains("mark-away")) fails.push(`${at}: ${key} (running elsewhere) has no dot: ${w.className}`);
  const o = iconOpacity(w);
  if (fades && !(o > 0.55 && o < 0.75)) fails.push(`${at}: ${key} (elsewhere) at opacity ${o}, want ~0.65`);
  if (!fades && o < 0.99) fails.push(`${at}: ${key} faded to ${o} with nothing open on this page`);
  return fails;
}

/** On page [index]: [here] has the pill at full opacity, [away] the dot (and faded when [fades]), search unfaded. */
export async function pageMarksAt(index, here, away, fades) {
  const S = await importShim("./state.ts");
  S.page.value = index;
  await settled();
  const at = `page ${index + 1}`;
  const fails = [...(here ? hereFails(at, here) : []), ...awayFails(at, away, fades)];
  const btn = document.querySelector(".home > .dock .dock-search");
  if (!btn) fails.push("no search button in the dock");
  else if (Number(getComputedStyle(btn).opacity) < 0.99) fails.push(`the search button faded to ${getComputedStyle(btn).opacity}`);
  return fails;
}

/** No windows: nothing marked here, nothing fades; then everything as it was. */
export async function pageMarksNone(probe) {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/webwindows.tsx");
  const R = await importShim("./ui/running.ts");
  W.webWins.value = [];
  R.running.value = {};
  await sleep(400);
  const fails = [];
  if (document.querySelector(".home > .dock.page-focus")) fails.push("no windows: the dock still fades its icons");
  const c = cell(probe);
  if (c && (c.classList.contains("mark-here") || c.classList.contains("mark-away"))) fails.push(`no windows: ${probe} still marked (${c.className})`);
  S.searchTry.value = "";
  S.dockTry.value = "";
  S.dock.value = saved.dock;
  S.page.value = saved.page;
  R.running.value = saved.running;
  return fails;
}

/**
 * DR1 (the user, 2026-10-31 15:55: "the docking is redrawing every time I change page"; perf-1793458475110: AppCell
 * 161x and Recents 16x by a signal over page swipes): after pageMarksSetup (unfolded, A's window on page 1, B's on
 * page 2), three page swipes - each with the host's "apps.running" and "recents.tasks" sent again, equal, as the phone
 * does on a task-stack change. AppCell renders at most once per cell whose mark changed, Recents not at all.
 */
export async function pageSwipeRenders() {
  const S = await importShim("./state.ts");
  const R = await importShim("./ui/running.ts");
  const ev = window.__mockEvents;
  const runningNow = () => ({ ...R.running.value });
  const tasksNow = () => [
    { id: 41, label: "One", key: "a:chrome", icon: null, snapshot: "/icons/none.png" },
    { id: 42, label: "Two", key: "a:camera", icon: null, snapshot: "/icons/none.png" },
  ];
  if (!ev) return { fails: ["no __mockEvents (mock bridge) to send host events with"], cells: 0, recents: 0, changed: 0 };
  ev.emit("apps.running", runningNow());
  ev.emit("recents.tasks", { tasks: tasksNow() });
  await settled();
  const classes = () => new Map([...document.querySelectorAll(".app[data-key]")].map((el, i) => [`${i} ${el.dataset.key}`, el.className]));
  window.__powosRenders.start();
  window.__powosRenders.reset();
  let changed = 0;
  for (const to of [1, 0, 1]) {
    const before = classes();
    S.page.value = to;
    ev.emit("apps.running", runningNow());
    ev.emit("recents.tasks", { tasks: tasksNow() });
    await settled();
    changed += [...classes()].filter(([k, c]) => before.has(k) && before.get(k) !== c).length;
  }
  const rows = window.__powosRenders.top(500).byCount;
  window.__powosRenders.stop();
  const count = (name) => rows.filter((r) => r.name === name).reduce((n, r) => n + r.renders, 0);
  const cells = count("AppCell");
  const recents = count("Recents");
  const fails = swipeFails(cells, recents, changed);
  console.warn(`[gate] dock-renders: AppCell ${cells} (marks changed ${changed}), Recents ${recents}`);
  return { fails, cells, recents, changed };
}

/** DR1's verdict: AppCell renders within the marks that changed, no Recents render, and some mark did change. */
function swipeFails(cells, recents, changed) {
  const fails = [];
  if (cells > changed) fails.push(`DR1: ${cells} AppCell renders over 3 page swipes, but only ${changed} cell marks changed`);
  if (recents) fails.push(`DR1: Recents rendered ${recents}x over 3 page swipes (want 0)`);
  if (!changed) fails.push("DR1: no cell's mark changed over the swipes - the scene isn't testing the marks");
  return fails;
}
