/**
 * LA1: the launcher adopts home's dock and bar (the user, 2026-10-31 15:44-15:45: "It should also reuse the docking, so
 * that we don't get duplicate docking" / "If the docking and recents is already available, we should just reuse that").
 * gate.mjs's launcher-adopt-* cases.
 *
 * adoptsHome (home's page, index.html): the launcher opened over home keeps ONE bar and ONE dock on screen in every
 * frame sampled through the open and after, at the same rects - only the app grid's layer moves.
 * Its frame is THE backdrop (--backdrop-tint, --backdrop-blur-native) over the whole screen, as the pull window's, with
 * home's bar and dock on top of it (what a finger at their centre hits).
 * ownDock (the overlay's page, index.html?mode=pull, over an app): no home dock under it, so it brings its own (one).
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => requestAnimationFrame(() => r()));

/** On screen: laid out, not hidden, not faded out. */
function shown(el) {
  const r = el.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== "hidden" && cs.display !== "none" && Number(cs.opacity) > 0.05;
}

/** The bars and docks (not the wide foot's recents tray) on screen, and their rects. */
function foot() {
  const bars = [...document.querySelectorAll("form.bar")].filter(shown);
  const docks = [...document.querySelectorAll(".dock:not(.dock-tray)")].filter(shown);
  const at = (el) => {
    const r = el.getBoundingClientRect();
    return [r.left, r.top, r.width, r.height].map(Math.round).join(",");
  };
  return { bars: bars.length, docks: docks.length, rects: [...bars, ...docks].map(at).join(" ") };
}

/** Ten frames - five through the open's animation, five after it settled: one bar, one dock, where they were. */
async function sampled(before) {
  const fails = [];
  for (let i = 0; i < 10; i++) {
    if (i === 5) await sleep(450);
    await frame();
    const f = foot();
    if (f.bars !== 1 || f.docks !== 1) fails.push(`frame ${i}: ${f.bars} bars, ${f.docks} docks`);
    else if (f.rects !== before.rects) fails.push(`frame ${i}: moved ${before.rects} -> ${f.rects}`);
  }
  return fails;
}

/** The open launcher's frame: the backdrop's tint and radius, the whole viewport; the bar and dock over it. */
function backdropFails() {
  const frame = document.querySelector(".home > .stage > .launcher-frame");
  if (!frame) return ["no launcher frame on home"];
  const fails = coversScreen(frame);
  const probe = document.createElement("div");
  probe.style.background = "var(--backdrop-tint)";
  document.body.append(probe);
  const tint = getComputedStyle(probe).backgroundColor;
  probe.remove();
  const root = getComputedStyle(document.documentElement).getPropertyValue("--backdrop-blur-native").trim();
  if (getComputedStyle(frame).backgroundColor !== tint) fails.push(`frame fill ${getComputedStyle(frame).backgroundColor}, not --backdrop-tint ${tint}`);
  if (getComputedStyle(frame).getPropertyValue("--glass-blur-native").trim() !== root) fails.push("frame blur isn't --backdrop-blur-native");
  return [...fails, ...["form.bar", ".home > .dock:not(.dock-tray)"].filter(under).map((sel) => `${sel} is under the launcher, not over it`)];
}

/** The frame's rect is the whole viewport. */
function coversScreen(frame) {
  const r = frame.getBoundingClientRect();
  const full = r.left <= 0.5 && r.top <= 0.5 && r.right >= innerWidth - 0.5 && r.bottom >= innerHeight - 0.5;
  return full ? [] : [`frame ${[r.left, r.top, r.right, r.bottom].map(Math.round)} doesn't cover the screen`];
}

/** A finger at [sel]'s centre lands on something else (the launcher over it). */
function under(sel) {
  const el = document.querySelector(sel);
  const b = el?.getBoundingClientRect();
  return !!b && !el.contains(document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2));
}

/** The rects of home's foot on screen: the dock, its search button, the bar. */
function footRects() {
  return [["dock", ".home > .dock:not(.dock-tray)"], ["dock button", ".home > .dock .dock-search"], ["bar", ".home > form.bar"]]
    .map(([name, sel]) => [name, document.querySelector(sel)])
    .filter(([, el]) => el && shown(el))
    .map(([name, el]) => [name, el.getBoundingClientRect()]);
}

const hit = (a, b) => a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5;
const box = (r) => [r.left, r.top, r.right, r.bottom].map(Math.round).join(",");

/** The grid's cells on screen: inside the list's view and above its window's (.launcher-clip) foot. */
function seenCells(list) {
  const l = list.getBoundingClientRect();
  const clip = list.closest(".launcher-clip")?.getBoundingClientRect() ?? l;
  return [...list.querySelectorAll(".app")].filter(shown).map((el) => el.getBoundingClientRect())
    .filter((r) => r.bottom > l.top + 1 && r.top < Math.min(l.bottom, clip.bottom) - 1);
}

/** The last row: wholly inside the grid's window and (a bottom dock) [gap] px over the dock's top. */
function lastRowFails(list, cells, dock, gap) {
  const last = cells.reduce((a, b) => (b.bottom > a.bottom ? b : a));
  const clip = list.closest(".launcher-clip")?.getBoundingClientRect();
  const fails = [];
  if (dock && last.bottom > dock.top - gap) fails.push(`the last row ends at ${Math.round(last.bottom)}, not ${gap} px over the dock's top ${Math.round(dock.top)}`);
  if (clip && last.bottom > clip.bottom + 0.5) fails.push(`the last row (${Math.round(last.bottom)}) is cut by the grid's window (${Math.round(clip.bottom)})`);
  return fails;
}

/**
 * LB1 (the user, 2026-10-31 18:27: "This doesn't look right in the bottom."): the grid scrolled to its end, its last row
 * sits wholly above home's foot - a bottom dock: the last cell's bottom 8 px over the dock's top - and no cell touches
 * the dock, the dock's search button or the bar (a side dock: the grid ends beside it and above the bar).
 */
async function gridClear(position) {
  const list = document.querySelector(".home > .stage .drawer-list:not(.drawer-folders)");
  if (!list) return ["no drawer list"];
  list.scrollTop = list.scrollHeight;
  await sleep(150);
  await frame();
  const cells = seenCells(list);
  if (!cells.length) return ["no app cells on screen"];
  const feet = footRects();
  const fails = cells.flatMap((r) => feet.filter(([, f]) => hit(r, f)).map(([name]) => `a grid cell (${box(r)}) overlaps the ${name}`));
  const dock = position === "bottom" ? feet.find(([n]) => n === "dock")?.[1] : null;
  fails.push(...lastRowFails(list, cells, dock, 8));
  list.scrollTop = 0;
  return [...new Set(fails)];
}

/**
 * Opens the launcher; one bar and one dock, unmoved, through the open. With home's search as the dock's button there is
 * no bar at rest - the pill comes with the launcher (home.tsx HomeSearch) - so only the open's result is looked at there.
 */
async function openedAdopting(S, button) {
  const before = foot();
  if (button) {
    S.openPanel("apps", { search: true });
    await sleep(500);
    return [];
  }
  const fails = before.bars === 1 && before.docks === 1 ? [] : [`at rest: ${before.bars} bars, ${before.docks} docks`];
  S.openPanel("apps", { search: true });
  return [...fails, ...(await sampled(before))];
}

/** A phone's worth of apps (60), so the grid scrolls and its last row meets the foot (the mock's few fit on one page). */
async function manyApps(powos) {
  const list = await powos.apps.list();
  if (list.length >= 60 || !list.length) return;
  const more = Array.from({ length: 60 - list.length }, (_, i) => ({ ...list[i % list.length], key: `a:dev.lb1/.A${i}`, label: `Zz ${i}` }));
  powos.apps.list = async () => [...list, ...more];
  window.__mockEvents.emit("apps.changed", {});
  await sleep(300);
}

/** [opts]: below - the pill under the dock (footBelow); button - home's search as the dock's button (searchTry "dock"). */
export async function adoptsHome(position, opts = {}) {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/searchwidget.tsx");
  const { powos } = await importShim("./bridge.ts");
  const asked = [];
  powos.pull.open = async (kind) => (asked.push(kind), true);
  await manyApps(powos);
  if (S.dock.value.length < 4) S.dock.value = S.recent.value.slice(0, 4);
  S.dockTry.value = position;
  W.footBelow.value = opts.below ? "1" : "";
  // The pill on home, folded too (folded's default is the dock button since SW1).
  S.searchTry.value = opts.button ? "dock" : "bar";
  await sleep(300);
  const fails = await openedAdopting(S, opts.button);
  if (S.drawer.value !== 1) fails.push("the launcher didn't open in place");
  fails.push(...backdropFails());
  if (asked.length) fails.push("asked the host's overlay over home");
  if (document.querySelector(".pull-screen")) fails.push("a launcher copy (.pull-screen) on home's page");
  fails.push(...(await gridClear(position)));
  S.closeDrawer();
  S.dockTry.value = "";
  S.searchTry.value = "";
  W.footBelow.value = "";
  return [...new Set(fails)].map((f) => `${position}: ${f}`);
}

/** The corner swipe's drag, frame by frame: home's launcher in its page, one bar and one dock. */
async function cornerDragged(E) {
  const fails = [];
  E.emit("home.panel.begin", { kind: "apps" });
  for (const p of [0.2, 0.5, 0.8]) {
    E.emit("home.panel.drag", { p });
    await frame();
    const f = foot();
    if (f.bars !== 1 || f.docks !== 1) fails.push(`dragged to ${p}: ${f.bars} bars, ${f.docks} docks`);
    if (!document.querySelector(".home > .stage .launcher")) fails.push(`dragged to ${p}: no launcher in home's page`);
  }
  return fails;
}

/** After the release: open in place with the apps, the overlay never asked, no launcher copy. */
function cornerOpened(S, asked) {
  return [
    S.drawer.value !== 1 && "the corner swipe didn't open the launcher in place",
    S.pullKind.value !== "apps" && `opened ${S.pullKind.value}, not the apps`,
    asked.length > 0 && "asked the host's overlay over home",
    !!document.querySelector(".pull-screen") && "a launcher copy (.pull-screen) on home's page",
  ].filter(Boolean);
}

/**
 * LC1: the host's corner swipe over home (CornerPull.kt "home.panel.begin" / ".drag" / ".end") opens home's launcher in
 * place, following the finger: one bar and one dock in every frame, unmoved, the overlay never asked.
 */
export async function cornerOverHome() {
  const S = await importShim("./state.ts");
  const { powos } = await importShim("./bridge.ts");
  const E = window.__mockEvents;
  const asked = [];
  powos.pull.open = async (kind) => (asked.push(kind), true);
  if (S.dock.value.length < 4) S.dock.value = S.recent.value.slice(0, 4);
  S.searchTry.value = "bar";
  await sleep(300);
  const before = foot();
  const fails = before.bars === 1 && before.docks === 1 ? [] : [`at rest: ${before.bars} bars, ${before.docks} docks`];
  fails.push(...(await cornerDragged(E)));
  E.emit("home.panel.end", { open: true });
  fails.push(...(await sampled(before)), ...cornerOpened(S, asked));
  S.closeDrawer();
  S.searchTry.value = "";
  return [...new Set(fails)];
}

export async function ownDock() {
  const E = window.__mockEvents;
  E.emit("pull.begin", { kind: "apps" });
  E.emit("pull.end", { open: true });
  await sleep(450);
  const f = foot();
  const fails = f.docks === 1 && f.bars === 1 ? [] : [`over an app: ${f.bars} bars, ${f.docks} docks (its own, one each)`];
  E.emit("pull.end", { open: false });
  return fails;
}

/**
 * LH1 (the user, 2026-10-31 15:15-15:16: "When I swipe up to show the switcher while it's already active, it should be
 * deactivated. ... I mean the launcher."): the home gesture with the launcher (grid or PowOS AI) open closes it, back
 * to where it was opened - never the switcher, a second launcher, or nothing. The page tells the host the panel is open
 * (panels.open, Panels.kt) - then NavGesture's Home/Switcher ends in "panel.close.*" { shut: true }, which this sends.
 * [kind]: "apps" or "ai". On home (index.html) home's bar and dock stay; in the pull window (?mode=pull) it shuts.
 */
/** NavGesture's home gesture over a live panel: begin on the down, the finger's drag, the release (Home/Switcher: shut). */
async function homeGesture(kind) {
  const host = (event, data) => window.__mockEvents.emit(event, data);
  host("panel.close.begin", { kind });
  for (const p of [0.2, 0.5, 0.9]) {
    host("panel.close.drag", { p });
    await frame();
  }
  host("panel.close.end", { shut: true });
  await sleep(600);
}

/** After the gesture: shut, the host told, no switcher; on home its bar and dock as before ([before]: null in the pull window). */
function afterHomeGesture(kind, S, Gs, before) {
  const fails = [];
  if (S.drawer.value > 0 || Gs.drawerOpen.value) fails.push(`${kind}: the home gesture did not close the launcher`);
  if (window.__mockPanel != null) fails.push(`${kind}: the host still thinks the ${window.__mockPanel} panel is open`);
  if (document.querySelector(".recents.open")) fails.push(`${kind}: the switcher opened`);
  if (!before) return fails;
  const f = foot();
  if (f.bars !== before.bars || f.docks !== before.docks) fails.push(`${kind}: home's bar/dock changed (${before.bars}/${before.docks} -> ${f.bars}/${f.docks})`);
  if (document.querySelector(".home.open")) fails.push(`${kind}: home still shows the launcher open (.home.open)`);
  return fails;
}

export async function homeGestureCloses(kind = "apps") {
  const G = window.__gw;
  const [S, Gs] = await Promise.all([G.mod("./state.ts"), G.mod("./ui/gesture.ts")]);
  const pull = new URLSearchParams(location.search).get("mode") === "pull";
  const before = pull ? null : foot();
  S.openPanel(kind);
  await sleep(500);
  if (!(S.drawer.value > 0)) return [`${kind}: the launcher did not open`];
  const told = window.__mockPanel === kind ? [] : [`${kind}: the page did not tell the host the ${kind} panel is open (panels.open: ${window.__mockPanel}) - its home gesture would go home / to the switcher instead`];
  await homeGesture(kind);
  return [...told, ...afterHomeGesture(kind, S, Gs, before)];
}
