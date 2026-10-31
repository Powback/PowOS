/**
 * Home's search as a dock button (ui/docksearch.tsx; the user, 2026-10-31 01:24-01:26). Runs in home's page
 * (index.html): gate.mjs's dock-search-* cases. [position]: the dock's placement. The failures, empty when it holds:
 * in "dock button" no .bar on home; the button in the dock's centre slot (and centred on the bottom row); a tap expands
 * it in place into the bar, focused, the launcher not opened; dismissed it folds back; "bar" brings the pill back.
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

function tap(el) {
  const r = el.getBoundingClientRect();
  const at = { bubbles: true, pointerId: 7, isPrimary: true, clientX: r.left + r.width / 2 - 6, clientY: r.top + r.height / 2 - 6 };
  el.dispatchEvent(new PointerEvent("pointerdown", at));
  el.dispatchEvent(new PointerEvent("pointerup", at));
}

/** A tap on the button: the bar expanded over the dock, focused, the launcher not opened; Escape folds it back. */
async function tapExpands(S, D, position) {
  const fails = [];
  const btn = document.querySelector(".home > .dock .dock-search");
  if (!btn) return fails;
  tap(btn);
  await sleep(400);
  const field = document.querySelector(".home > .dock-search-bar textarea");
  if (!field) fails.push("a tap didn't expand the bar");
  else if (document.activeElement !== field) fails.push(`the expanded bar isn't focused (${document.activeElement?.tagName})`);
  if (S.drawer.value !== 0) fails.push("the tap opened the launcher");
  if (position === "bottom") fails.push(...overDock());
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
  await sleep(400);
  if (document.querySelector(".home > .dock-search-bar")) fails.push("Escape didn't fold it back");
  if (D.dockSearch.value !== "closed") fails.push(`after folding: ${D.dockSearch.value}`);
  return fails;
}

/** The expanded pill over the bottom dock's row, most of its width. */
function overDock() {
  const bar = document.querySelector(".home > .dock-search-bar .pill")?.getBoundingClientRect();
  const dock = document.querySelector(".home > .dock:not(.dock-tray)")?.getBoundingClientRect();
  if (!bar || !dock) return ["no expanded pill or dock to compare"];
  const off = bar.top < dock.top - 1 || bar.bottom > dock.bottom + 1 || bar.width < dock.width * 0.6;
  return off ? [`expanded bar not over the dock: ${Math.round(bar.top)}..${Math.round(bar.bottom)} w${Math.round(bar.width)} vs ${Math.round(dock.top)}..${Math.round(dock.bottom)} w${Math.round(dock.width)}`] : [];
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
  const D = await importShim("./ui/docksearch.tsx");
  const was = S.dock.value;
  if (S.dock.value.length < 6) S.dock.value = S.recent.value.slice(0, 6);
  S.dockTry.value = position;
  S.searchTry.value = "dock";
  await sleep(300);
  const fails = [];
  if (document.querySelector(".home > .bar")) fails.push("a .bar on home in dock-button mode");
  const c = centred(position);
  if (c) fails.push(c);
  fails.push(...(await tapExpands(S, D, position)), ...(await backToBar(S)));
  S.searchTry.value = "";
  S.dockTry.value = "";
  S.dock.value = was;
  return fails.map((f) => `${position}: ${f}`);
}
