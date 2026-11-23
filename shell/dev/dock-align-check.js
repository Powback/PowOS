// The side dock's alignment in the page (gate.mjs dock-align-*; ui/dockalign.ts): imported with importShim.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const px = (n) => Math.round(n);

/** 4 pinned apps, many recent ones (the host's list says every app, re-read as on a return home), the side, the align. */
async function setup(S, position, align) {
  const keys = [...S.byKey.value.keys()];
  S.setDock(keys.slice(0, 4));
  const B = (await importShim("./bridge.ts")).powos;
  B.usage.recent = async (limit) => keys.slice(4).slice(0, limit);
  document.dispatchEvent(new Event("visibilitychange"));
  S.searchTry.value = "bar";
  S.dockTry.value = position;
  // The other alignment first, then this one: the switch applies in the page (no reload).
  S.dockAlignTry.value = align === "bottom" ? "top" : "bottom";
  await sleep(100);
  S.dockAlignTry.value = align;
  await sleep(400);
  return keys;
}

/** The column, the pinned section and its cells, the recent section and its cells. */
function measure() {
  const col = document.querySelector(".home > .dock .dock-pages")?.getBoundingClientRect();
  const pinnedEl = document.querySelector(".home > .dock .dock-page:not(.dock-recent)");
  const recentEl = document.querySelector(".home > .dock .dock-recent");
  if (!col || !pinnedEl || !recentEl) return null;
  const rects = (el) => [...el.querySelectorAll(":scope > .app")].map((n) => n.getBoundingClientRect());
  return { col, pinned: pinnedEl.getBoundingClientRect(), cells: rects(pinnedEl), recentEl, recents: rects(recentEl) };
}

/** Every pinned app inside the column and the screen. */
function pinnedOnScreen({ col, cells }) {
  const fails = cells.length === 4 ? [] : [`${cells.length} pinned cells, expected 4`];
  const off = cells.find((c) => c.top < col.top - 1 || c.bottom > col.bottom + 1 || c.bottom > innerHeight);
  if (off) fails.push(`a pinned app is off the column (${px(off.top)}..${px(off.bottom)}, column ${px(col.top)}..${px(col.bottom)})`);
  return fails;
}

/** Bottom: pinned at the foot, the recents above (the newest lowest), scrolling on their own. */
function bottomFails({ col, pinned, recentEl, recents }) {
  const fails = [];
  if (pinned.bottom < col.bottom - 2) fails.push(`pinned apps not at the foot: ${px(pinned.bottom)} vs column ${px(col.bottom)}`);
  if (recentEl.getBoundingClientRect().bottom > pinned.top + 1) fails.push("recent apps not above the pinned ones");
  if (recentEl.scrollHeight <= recentEl.clientHeight) fails.push("many recent apps but their section doesn't scroll");
  if (recents.length > 1 && recents[0].top < recents[1].top) fails.push("the newest recent app isn't nearest the pinned ones");
  return fails;
}

/** Top: pinned at the column's top, the recents under them. */
function topFails({ col, pinned, recents }) {
  const fails = pinned.top > col.top + 2 ? [`pinned apps not at the top: ${px(pinned.top)} vs column ${px(col.top)}`] : [];
  if (recents.length && recents[0].top < pinned.bottom) fails.push("recent apps not under the pinned ones");
  return fails;
}

/** A drop on the 3rd pinned app aims its slot. */
async function aimFails(cells, key) {
  const D = await importShim("./ui/dockdrop.ts");
  const t = cells[2];
  const aim = t && D.aimDock({ app: key }, t.left + t.width / 2, t.top + t.height / 2);
  return aim?.slot === 2 ? [] : [`drop on the 3rd pinned app aims slot ${aim?.slot}, expected 2`];
}

/**
 * A side dock at [position] aligned [align] (the user, 2026-11-23: docked icons "so far up"): bottom (the default) keeps
 * every pinned app at the column's foot on screen, the recents above, scrolling on their own; top keeps the pinned group
 * at the top. Drops aim the right slot, search finds the setting, the switch applies live.
 */
export async function dockAlignCheck(position, align) {
  const S = await importShim("./state.ts");
  const fails = S.sideDockAlign.value === "bottom" ? [] : [`default side dock alignment ${S.sideDockAlign.value}, expected bottom`];
  const keys = await setup(S, position, align);
  const end = document.querySelector(".home").classList.contains("dock-end");
  if (end !== (align === "bottom")) fails.push(`home's dock-end class ${end} for ${align} (the switch didn't apply live)`);
  const m = measure();
  if (!m) return [...fails, "no side column, pinned or recent section"];
  fails.push(...pinnedOnScreen(m), ...(align === "bottom" ? bottomFails(m) : topFails(m)), ...(await aimFails(m.cells, keys[6])));
  const search = await importShim("./search.ts");
  if (!search.settingDestinations.some((d) => d.label === "side dock alignment")) fails.push("'side dock alignment' isn't found by search");
  return fails;
}
