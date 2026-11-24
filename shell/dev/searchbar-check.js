/**
 * The search bar's two 11-23 reports (runs in home's page, gate.mjs "searchbar-*"):
 *  - SP1 ("going from the homepage to the search bar, the search bar 're-initializes' with an animation instead of
 *    reusing the EXISTING bar"): a tap on home's bar opens the launcher's search with the SAME nodes - the bar, its pill,
 *    its field and its prompt glyph - and no CSS animation starts anywhere in the bar on the way (the old role cross-fade
 *    bar-role-apps and the glyph swapped for the apps icon were the re-init the user saw). Its face (glyph, hint) is
 *    home's.
 *  - SE1 ("don't edit it on long-press; require edit mode", and the folded "show as dock button" only in edit mode): a
 *    long press on the bar outside edit mode opens no menu; openSpotMenu refuses outside edit mode (the dock button's
 *    path too); in edit mode a tap on the bar shows the menu with its "Show as dock button"; leaving edit mode closes it.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => (requestAnimationFrame(() => r()), setTimeout(r, 500)));
const BAR = ".home > .bar";
/** Own waits (not the gate's __gw): the same file runs on the phone (tools/phone/verify/searchbar.sh). */
async function until(f, ms = 3000) {
  const t0 = performance.now();
  while (!f()) {
    if (performance.now() - t0 > ms) return false;
    await sleep(16);
  }
  return true;
}
const finite = (sel) => document.getAnimations().some((a) => a.playState === "running" && a.timeline === document.timeline && a.effect?.target?.closest?.(sel) && a.effect.getComputedTiming().endTime !== Infinity);
const MENU = ".search-spot-menu";

/** The bar's parts whose identity is the bar's: they must be the same nodes after it opens the search. */
function parts() {
  const bar = document.querySelector(BAR);
  return {
    bar,
    pill: bar?.querySelector(".bar-pill"),
    field: bar?.querySelector("textarea"),
    glyph: bar?.querySelector(".lead > .prompt"),
  };
}

/** The face a user reads: the glyph's text and class, the field's placeholder. */
const face = (p) => ({ glyph: p.glyph?.textContent ?? "", icon: !!p.glyph?.classList.contains("role-icon"), hint: p.field?.getAttribute("placeholder") ?? "" });

/** CSS animations (keyframes, not transitions/WAAPI moves) running on anything in the bar, the caret's blink aside. */
function barAnimations(bar) {
  return document
    .getAnimations()
    .filter((a) => a.animationName && a.animationName !== "prompt-blink" && a.timeline === document.timeline)
    .filter((a) => {
      const t = a.effect?.target;
      return t instanceof Element && bar.contains(t);
    })
    .map((a) => a.animationName);
}

async function homeAtRest(S) {
  S.drawer.value = 0;
  S.editing.value = false;
  S.searchTry.value = "bar";
  await until(() => document.querySelector(BAR));
  await until(() => !finite(BAR));
  await sleep(300);
}

/** SP1: home's bar tapped -> the launcher's search, the same nodes and face, nothing animating in. */
export async function barPersists(label) {
  const S = await importShim("./state.ts");
  await homeAtRest(S);
  const before = parts();
  if (!before.bar || !before.glyph) return [`${label}: no bar on home`];
  const was = face(before);
  const seen = new Set();
  let watching = true;
  const watch = async () => {
    while (watching) {
      for (const n of barAnimations(before.bar)) seen.add(n);
      await frame();
    }
  };
  const w = watch();
  // A finger's tap on the bar (useOwnPress: a script click counts as the bar's).
  before.bar.click();
  await until(() => S.drawer.value === 1, 2000);
  await sleep(900);
  watching = false;
  await w;
  const after = parts();
  const fails = [];
  if (S.drawer.value !== 1) fails.push(`${label}: the tap didn't open the search (drawer ${S.drawer.value})`);
  for (const k of Object.keys(before)) {
    if (after[k] !== before[k] || !before[k].isConnected) fails.push(`${label}: the bar's ${k} is a new node after home -> search (re-initialized)`);
  }
  if (seen.size) fails.push(`${label}: the bar animated in home -> search: ${[...seen].join(", ")}`);
  const now = face(after);
  if (JSON.stringify(now) !== JSON.stringify(was)) fails.push(`${label}: the bar's face changed home -> search: ${JSON.stringify(was)} -> ${JSON.stringify(now)}`);
  S.drawer.value = 0;
  await sleep(400);
  return fails;
}

const fire = (el, type) => {
  const r = el.getBoundingClientRect();
  el.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 9, isPrimary: true, pointerType: "touch", clientX: r.left + r.width / 3, clientY: r.top + r.height / 2 }));
};

/** SE1: no search edit affordance outside edit mode; in edit mode the bar's tap shows it; leaving edit mode closes it. */
export async function editOnly(label) {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/searchwidget.tsx");
  await homeAtRest(S);
  const fails = [];
  const pill = document.querySelector(`${BAR} .bar-pill`);
  if (!pill) return [`${label}: no bar on home`];
  // A long press (the WebView's contextmenu) outside edit mode.
  const ev = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
  pill.dispatchEvent(ev);
  await sleep(400);
  if (document.querySelector(MENU)) fails.push(`${label}: a long press outside edit mode opened the search's menu`);
  if (!ev.defaultPrevented) fails.push(`${label}: a long press on the unfocused bar outside edit mode kept its default (text selection)`);
  W.spotMenu.value = null;
  await sleep(300);
  // The dock button's path (and any other caller): refused outside edit mode.
  if (W.openSpotMenu(pill)) fails.push(`${label}: openSpotMenu opened outside edit mode`);
  await sleep(300);
  if (document.querySelector(MENU)) fails.push(`${label}: the "show as dock button" option is shown outside edit mode`);
  W.spotMenu.value = null;
  await sleep(300);
  return [...fails, ...(await editModeMenu(label, S, W))];
}

/** In edit mode a tap on the bar (grabSearch's let-go without moving) shows the menu with the dock-button option; leaving edit mode closes it. */
async function editModeMenu(label, S, W) {
  const fails = [];
  S.editing.value = true;
  await sleep(500);
  const bar = document.querySelector(`${BAR} .bar-pill`);
  if (bar) fire(bar, "pointerdown"), fire(bar, "pointerup");
  await sleep(500);
  const item = document.querySelector(`${MENU} .menu-item`);
  if (!item) fails.push(`${label}: edit mode's tap on the bar showed no menu`);
  else if (item.textContent.trim() !== "Show as dock button") fails.push(`${label}: edit mode's menu says "${item.textContent.trim()}", not "Show as dock button"`);
  // Leaving edit mode takes it away.
  S.editing.value = false;
  await until(() => !document.querySelector(MENU), 1500);
  if (document.querySelector(MENU) || W.spotMenu.value) fails.push(`${label}: the search's menu stayed after edit mode ended`);
  return fails;
}
