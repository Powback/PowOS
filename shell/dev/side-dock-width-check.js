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
