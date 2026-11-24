// The launcher and PowOS AI fill the width with a side dock (gate.mjs side-dock-width-*; board
// side-dock-on-the-right-launcher-and-ai-chat-aren): imported with importShim.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const px = (n) => Math.round(n);

/** Home's side dock: on screen (not slid out past its edge) and not faded out. */
function dockShown() {
  const d = document.querySelector(".home > .dock:not(.dock-tray)");
  if (!d) return false;
  const r = d.getBoundingClientRect();
  return r.width > 0 && r.right > 1 && r.left < innerWidth - 1 && Number(getComputedStyle(d).opacity) > 0.05;
}

/** The launcher open with a side dock at [position] on [kind]. */
async function openWith(position, kind) {
  const S = await importShim("./state.ts");
  S.searchTry.value = "bar";
  S.dockTry.value = position;
  await sleep(200);
  if (kind === "ai") S.openPanel("ai");
  else S.drawer.value = 1;
  await sleep(600);
}

/** The reserve on each side against whether the dock is shown beside the launcher. */
function reserveFails(pad, side) {
  const other = side === "left" ? "right" : "left";
  const dock = document.querySelector(".home > .dock:not(.dock-tray)");
  const dockW = dockShown() ? dock.getBoundingClientRect().width : 0;
  const fails = [];
  if (dockW && pad[side] < dockW - 1) fails.push(`dock shown (${px(dockW)} px) but the launcher keeps only ${px(pad[side])} px clear on the ${side}`);
  if (!dockW && pad[side] > 1) fails.push(`dock slid out but the launcher still reserves ${px(pad[side])} px on the ${side}`);
  if (Math.abs(pad[other]) > 1) fails.push(`the launcher reserves ${px(pad[other])} px on the ${other}, where no dock is`);
  return fails;
}

/** The content fills the clip's box. */
function contentFails(clip, pad, kind) {
  const inner = document.querySelector(kind === "ai" ? ".home .drawer-clip > .ai-panel" : ".home .drawer-clip > .drawer");
  if (!inner) return [`no ${kind} content in the launcher`];
  const want = clip.getBoundingClientRect().width - pad.left - pad.right;
  const w = inner.getBoundingClientRect().width;
  return w < want - 2 ? [`${kind} content is ${px(w)} px wide, its window ${px(want)} px`] : [];
}

/**
 * A side dock at [position], the launcher open on [kind] ("apps" | "ai"): the launcher's window keeps clear of the dock
 * only while the dock is shown beside it; otherwise it takes the full width on both sides (the user, 2026-11-23: "A
 * launcher is not full width if the docking is on the right").
 */
export async function sideDockWidthCheck(position, kind) {
  await openWith(position, kind);
  const clip = document.querySelector(".home .drawer-clip");
  if (!clip) return ["no .drawer-clip with the launcher open"];
  const cs = getComputedStyle(clip);
  const pad = { left: parseFloat(cs.paddingLeft), right: parseFloat(cs.paddingRight) };
  return [...reserveFails(pad, position === "left" ? "left" : "right"), ...contentFails(clip, pad, kind)];
}

/** [el] or one of its ancestors matches [sel]. */
const within = (el, sel) => !!el?.closest(sel);

/** Unfolded: the adopted dock is shown, takes the touch at its centre and stays clear of the app grid. */
function wideFails(d, g, hit, what) {
  const fails = [];
  if (!dockShown()) fails.push("unfolded: the launcher did not adopt the side dock (it slid out or faded)");
  if (!within(hit, ".home > .dock")) fails.push(`unfolded: a touch at the dock's centre lands on ${what}, not the dock`);
  const overlap = Math.min(d.right, g.right) - Math.max(d.left, g.left);
  if (overlap > 1) fails.push(`unfolded: the dock covers ${px(overlap)} px of the app grid (dock ${px(d.left)}-${px(d.right)}, grid ${px(g.left)}-${px(g.right)})`);
  return fails;
}

/** Folded: the dock gave way and the launcher takes the touch at its spot. */
function foldedFails(hit) {
  const fails = [];
  if (dockShown()) fails.push("folded: the side dock stays shown over the launcher");
  if (within(hit, ".home > .dock")) fails.push("folded: a touch at the dock's spot lands on the dock, not the launcher");
  return fails;
}

/**
 * The launcher open over home with a side dock at [position] (device check side-dock-layout.sh "dock covers launcher",
 * board side-dock-align-bottom): unfolded (.wide) home's launcher ADOPTS the dock (shell.css .home.adopts.wide > .dock,
 * the user 2026-10-31: "reuse the docking") - shown, tappable, BESIDE the app grid, never over it; folded the dock gives
 * way and the launcher is what a touch at the dock's spot lands on. Judged by hit-testing and boxes, after the
 * transition, never by opacity alone (opacity 1 is the adopted dock's intended state).
 */
export async function sideDockLauncherCheck(position) {
  await openWith(position, "apps");
  await sleep(600);
  const dock = document.querySelector(".home > .dock:not(.dock-tray)");
  const grid = document.querySelector(".home .drawer-clip > .drawer");
  if (!dock || !grid) return [`no ${dock ? "launcher grid" : "dock"} with the launcher open`];
  const d = dock.getBoundingClientRect();
  const hit = document.elementFromPoint(Math.min(Math.max(d.left + d.width / 2, 1), innerWidth - 1), d.top + d.height / 2);
  const what = hit ? `${hit.tagName.toLowerCase()}.${[...hit.classList].join(".")}` : "nothing";
  return document.querySelector(".home").classList.contains("wide") ? wideFails(d, grid.getBoundingClientRect(), hit, what) : foldedFails(hit);
}
