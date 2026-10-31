/**
 * The theme's alignment per surface (ui/align.ts; the user, 2026-10-31 15:42-15:43): gate.mjs's align-* cases.
 * AL1: unfolded, each surface - the launcher (over home in place, and the overlay over an app), the notifications, the
 * control center - in each mode puts its content where it says: bottom, the content's foot within 24 px of the
 * surface's (its inset: padding, the header row); middle, centred within 24 px; top, from the surface's top as before.
 * AL2: unset, unfolded is bottom and folded top. AL3: a pick in the settings applies on the page at once, no reload.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frames = (n) => new Promise((r) => { const f = () => (--n <= 0 ? r() : requestAnimationFrame(f)); requestAnimationFrame(f); });
const TOL = 24;

const pad = (el, side) => parseFloat(getComputedStyle(el)[`padding${side}`]) || 0;
/** [r] clipped to [clip]'s top and bottom; full: its whole height. */
const shownPart = (r, clip) => ({ top: Math.max(r.top, clip.top), bottom: Math.min(r.bottom, clip.bottom), full: r.height });

/** The launcher's app grid (what shows of it in the list), the list's box less its padding, and its A-Z bar. */
function launcherBoxes() {
  const list = [...document.querySelectorAll(".drawer.shown .drawer-page > .drawer-list:not(.drawer-folders):not(.results)")].at(-1);
  const grid = list?.querySelector(".grid.az");
  if (!grid) return null;
  const l = list.getBoundingClientRect();
  const area = { top: l.top + pad(list, "Top"), bottom: l.bottom - pad(list, "Bottom") };
  return { area, content: shownPart(grid.getBoundingClientRect(), l), bar: list.parentElement.querySelector(".letter-bar")?.getBoundingClientRect() };
}

/** The notifications' cards in their column, under its header. */
function shadeBoxes() {
  const col = document.querySelector(".notif-panel.shown .panel-body.two > .notif-col");
  const items = col?.querySelector(":scope > .notif-items");
  if (!items) return null;
  const c = col.getBoundingClientRect();
  const head = col.querySelector(":scope > .notif-bar")?.getBoundingClientRect();
  return { area: { top: head?.bottom ?? c.top, bottom: c.bottom }, content: shownPart(items.getBoundingClientRect(), c) };
}

/** The control center's body (all but its header) in its card, under the header. */
function controlBoxes() {
  const cc = document.querySelector(".notif-panel.shown .panel-body.two > .cc-col > .cc");
  const parts = cc ? [...cc.children].filter((el) => !el.classList.contains("notif-bar")).map((el) => el.getBoundingClientRect()).filter((r) => r.height > 0) : [];
  if (!parts.length) return null;
  const k = cc.getBoundingClientRect();
  const head = cc.querySelector(":scope > .notif-bar")?.getBoundingClientRect();
  const top = Math.min(...parts.map((r) => r.top)), bottom = Math.max(...parts.map((r) => r.bottom));
  return { area: { top: head?.bottom ?? k.top, bottom: k.bottom - pad(cc, "Bottom") }, content: { top, bottom, full: bottom - top } };
}

const BOXES = { launcher: launcherBoxes, shade: shadeBoxes, control: controlBoxes };
const r0 = (v) => Math.round(v);
/** Per mode: how far the content is off its place (px), and what that reads as. */
const OFF = {
  bottom: ({ area, content }) => [content.bottom - area.bottom, `the content ends at ${r0(content.bottom)}, the surface at ${r0(area.bottom)}`],
  middle: ({ area, content }) => {
    // Content taller than the surface fills it ("safe": from its top, scrolling) - nothing to centre.
    if (content.full >= area.bottom - area.top - 1) return [0, ""];
    const c = (content.top + content.bottom) / 2, a = (area.top + area.bottom) / 2;
    return [c - a, `the content's centre ${r0(c)}, the surface's ${r0(a)}`];
  },
  top: ({ area, content }) => [content.top - area.top, `the content starts at ${r0(content.top)}, the surface at ${r0(area.top)}`],
};

/** Where [s]'s content sits against [mode]'s edge: the failures. */
function placed(s, mode, at) {
  const b = BOXES[s]();
  if (!b) return [`${at}: ${s} not on screen`];
  const [off, why] = OFF[mode](b);
  const fails = Math.abs(off) > TOL ? [`${at}: ${why}`] : [];
  // The A-Z bar ends with the grid, bottom-aligned.
  if (mode === "bottom" && b.bar && Math.abs(b.bar.bottom - b.area.bottom) > TOL) fails.push(`${at}: the A-Z bar ends at ${r0(b.bar.bottom)}, the grid at ${r0(b.area.bottom)}`);
  return fails;
}

/** The surface open: [where] "home" (the launcher in place), "pull" (the overlay) or "shade". */
export async function alignOpen(where) {
  const S = await importShim("./state.ts");
  if (where === "home") S.openPanel("apps");
  else if (where === "pull") (window.__mockEvents.emit("pull.begin", { kind: "apps" }), window.__mockEvents.emit("pull.end", { open: true }));
  else S.notif.value = true;
  await sleep(600);
  return [];
}

/** [s] shown in [mode] (a check's try, not stored): its content at that edge. */
export async function alignAt(s, mode, at) {
  const A = await importShim("./ui/align.ts");
  A.alignTry.value = { ...A.alignTry.value, [s]: mode };
  await frames(3);
  await sleep(150);
  return attr(s) === mode ? placed(s, mode, at) : [`${at}: html shows ${s} ${attr(s)}, not ${mode}`];
}

const attr = (s) => document.documentElement.dataset[`align${s[0].toUpperCase()}${s.slice(1)}`];

/** One surface unset in [mode]: [want] shown; a pick of middle shown at once (where the page shows that mode). */
async function defaultsOf(A, s, mode, want) {
  const c = A.alignChoice(s, mode);
  const was = localStorage.getItem(`powos.align.${s}.${mode}`);
  c.value = "";
  await frames(2);
  const fails = c.value === want ? [] : [`${mode} ${s}: unset is ${c.value}, not ${want}`];
  // The launcher follows home's mode: not on the shade's page.
  if (s !== "launcher" || !document.querySelector(".shade-screen")) {
    if (attr(s) !== want) fails.push(`${mode} ${s}: html shows ${attr(s)} unset, not ${want}`);
    c.value = "middle";
    await frames(2);
    if (attr(s) !== "middle") fails.push(`${mode} ${s}: picked middle, html still shows ${attr(s)} (no live apply)`);
  }
  c.value = was ?? "";
  await frames(2);
  return fails;
}

/** AL2 + AL3: unset, this page's mode default ([mode]: "folded" | "unfolded"); a pick applies at once, then as it was. */
export async function alignDefaults(mode) {
  const A = await importShim("./ui/align.ts");
  A.alignTry.value = {};
  const fails = [];
  for (const s of ["launcher", "shade", "control"]) fails.push(...(await defaultsOf(A, s, mode, mode === "unfolded" ? "bottom" : "top")));
  return fails;
}
