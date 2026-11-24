// The AI page's tab screens (Agents, Progress, Devices) have their header - back, name, glance - under the status bar,
// whole and uncovered, and the tab strip whole on screen, at every layout (gate.mjs ai-tab-head-*; board
// ai-page-agents-progress-devices-tabs-cut-off-at, the user 11-23: "surely we can do the page dock cutoff thing more
// nicely"). Imported with importShim.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const px = (n) => Math.round(n * 10) / 10;

/** [el]'s box cut by every ancestor that clips (overflow other than visible), up to the page. */
function clippedBox(el) {
  let r = el.getBoundingClientRect();
  let box = { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
  for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
    const cs = getComputedStyle(p);
    if (cs.overflowX === "visible" && cs.overflowY === "visible" && cs.clipPath === "none") continue;
    r = p.getBoundingClientRect();
    box = { top: Math.max(box.top, r.top), bottom: Math.min(box.bottom, r.bottom), left: Math.max(box.left, r.left), right: Math.min(box.right, r.right) };
  }
  return box;
}

/** [r] runs off the screen. */
const offScreen = (r) => r.bottom > innerHeight + 0.5 || r.right > innerWidth + 0.5 || r.left < -0.5;

/** [el]'s box against the status bar [inset], its clipping ancestors and the screen. */
function boxFails(el, what, inset) {
  const r = el.getBoundingClientRect();
  const fails = [];
  if (r.top < inset - 0.5) fails.push(`${what}'s top ${px(r.top)} px is above the status bar's ${px(inset)} px`);
  const c = clippedBox(el);
  if (c.top > r.top + 0.5 || c.bottom < r.bottom - 0.5) fails.push(`${what} clipped: ${px(r.top)}..${px(r.bottom)} shows only ${px(c.top)}..${px(c.bottom)}`);
  if (offScreen(r)) fails.push(`${what} runs off the screen (${px(r.left)},${px(r.top)} ${px(r.width)}x${px(r.height)} in ${innerWidth}x${innerHeight})`);
  return fails;
}

/** [el] (named [what]) whole: sized, not clipped or off screen, its top at or under [inset], on top at its centre. */
function wholeFails(el, what, inset) {
  const r = el.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) return [`${what} has no size (${px(r.width)}x${px(r.height)})`];
  const fails = boxFails(el, what, inset);
  if (fails.length) return fails;
  const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
  return hit && !el.contains(hit) && !hit.contains(el) ? [`${what} covered by ${hit.tagName.toLowerCase()}.${[...hit.classList].join(".")}`] : [];
}

const TABS = [
  ["fleet", "Agents"],
  ["progress", "Progress"],
  ["devices", "Devices"],
];

/** The one shown header on [name]'s screen: it names the tab, has a back, and it, its title, back and the tab strip are whole. */
function tabFails(name, inset) {
  const heads = [...document.querySelectorAll(".ai-screen .ag-top")].filter((h) => h.getBoundingClientRect().height > 0);
  if (heads.length !== 1) return [`${heads.length} headers (.ag-top), want 1`];
  const h = heads[0];
  const title = h.querySelector(".ai-title");
  const back = h.querySelector(".session-back");
  const segs = document.querySelector(".ai-screen .ai-segs");
  const fails = [];
  if (title?.textContent.trim() !== name) fails.push(`header names "${title?.textContent.trim() ?? ""}", want "${name}"`);
  const parts = [[h, "header"], [title, "header title"], [back, "header back"], [segs, "tab strip"]];
  for (const [el, what] of parts) fails.push(...(el ? wholeFails(el, what, inset) : [`no ${what}`]));
  return fails;
}

/**
 * Each tab screen with the status bar [top] px tall and home's dock at [dock] ("bottom" | "left" | "right"): one header
 * (.ag-top) naming the tab, with its back; it and the tab strip (.ai-segs) whole, both at or under the status bar.
 */
export async function aiTabHeadCheck(dock, top) {
  const S = await importShim("./state.ts");
  window.__mockEvents.emit("system.insets", { top, bottom: 16, left: 0, right: 0, keyboard: 0 });
  S.dockTry.value = dock;
  S.page.value = -1;
  await sleep(500);
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 0;
  if (Math.abs(inset - top) > 1) return [`--inset-top is ${inset}, the mock status bar ${top}`];
  const fails = [];
  for (const [k, name] of TABS) {
    S.aiScreen.value = k;
    await sleep(450);
    fails.push(...tabFails(name, inset).map((f) => `${name} tab: ${f}`));
  }
  S.aiScreen.value = "chat";
  return fails;
}
