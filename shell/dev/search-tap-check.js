/**
 * ST1 (device check e2e-lookw-relaunch 11-03 "home's search didn't take the focus"; gate E2E1 flaky in full runs since
 * the bar's --bar-drop/seat moves, 9879c7e7/bb7e7159): home's search where a finger finds it. Runs in home's page
 * (index.html): gate.mjs homeGesturesScene, and the same rules as tools/phone/verify/e2e-lib.sh searchpt.
 *  - searchAt: measured once at rest - no animation on it or on what carries it (the drawer's --p settle, the seat's
 *    translate, edit mode's rise): under a loaded gate the 500 ms after the drawer closed left the bar mid its slide
 *    down, so the tap went where it had been - and hit-tested: the point lands on the search itself (a bar parked under
 *    the grid's search widget is there by its rect but takes no touch).
 *  - toPage: PowOS AI's page (the bar seated on it, bar.tsx seatOnAi) and back, so the bar is tapped after its seat
 *    move and after its way back (the one bar, reused). The launcher's close doesn't move it: at rest the next frame.
 */
const frame = () => new Promise((ok) => requestAnimationFrame(() => ok()));

/** Home's search: its bar (when it takes touches), else the dock's search button. */
function pick() {
  const bar = document.querySelector(".home > .bar");
  if (bar && bar.getBoundingClientRect().height > 2 && getComputedStyle(bar).pointerEvents !== "none") return { el: bar, bar: true };
  const btn = document.querySelector(".home .dock .app.dock-search");
  return btn ? { el: btn, bar: false } : null;
}

const touches = (a, el) => {
  const t = a.effect?.target;
  return t instanceof Element && (t.contains(el) || el.contains(t));
};
const moving = (el) => document.getAnimations().some((a) => a.playState === "running" && touches(a, el));

/** Frames until the search's rect held still with nothing animating it, 3 in a row (at most ~400 frames). */
async function settled() {
  let last = "", still = 0;
  for (let i = 0; i < 400 && still < 3; i++) {
    await frame();
    const p = pick();
    const k = p ? JSON.stringify(p.el.getBoundingClientRect()) : "";
    still = p && k === last && !moving(p.el) ? still + 1 : 0;
    last = k;
  }
}

/** Why [at] isn't a tap on [el] ("" when it is). */
function hitWhy(el, at) {
  const hit = document.elementFromPoint(at[0], at[1]);
  if (hit && el.contains(hit)) return "";
  return `at ${at} is under ${hit ? `${hit.tagName.toLowerCase()}.${String(hit.className).slice(0, 60)}` : "nothing"}, not the search`;
}

/** The point to tap on [p]'s face: its middle, or ("edge") its pill's left end (the mic is at the right). */
function pointOn(p, where) {
  const face = (p.bar && p.el.querySelector(".bar-pill")) || p.el;
  const b = face.getBoundingClientRect();
  const x = where === "edge" && p.bar ? b.left + Math.min(16, b.width / 4) : b.x + b.width / 2;
  return [Math.round(x), Math.round(b.y + b.height / 2)];
}

/** {at, bar}, null (no search on home) or why it can't be tapped. */
export async function searchAt(where = "middle") {
  await settled();
  const p = pick();
  if (!p) return null;
  const at = pointOn(p, where);
  return hitWhy(p.el, at) || { at, bar: p.bar };
}

/** Home on [page] (-1: PowOS AI's, the bar seated on it), at rest: then searchAt says where its bar is. */
export async function toPage(page) {
  (await importShim("./state.ts")).page.value = page;
  await settled();
}
const TAP_EVENTS = ["touchstart", "touchend", "pointerdown", "pointerup", "pointercancel", "click", "contextmenu", "focusin", "focusout"];
/** What a tap on the search did, for a failure's message: each event's type, target and ms after the first. */
export function watchTap() {
  const log = [], t0 = performance.now();
  const on = (e) => log.push(`${e.type}@${Math.round(e.timeStamp - t0)}:${String(e.target?.className ?? e.target?.nodeName).split(" ")[0]}${e.defaultPrevented ? "!" : ""}`);
  for (const t of TAP_EVENTS) addEventListener(t, on, true);
  window.__stTap = () => {
    for (const t of TAP_EVENTS) removeEventListener(t, on, true);
    return log.join(" ") || "no event at all";
  };
}
export const tapLog = () => window.__stTap?.() ?? "";
