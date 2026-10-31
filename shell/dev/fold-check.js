/**
 * Fold <-> unfold on home (the user, 10-31 00:18: "sometimes I get the mobile UI in desktop mode when I unfold ... it
 * goes back when I move the page"). Runs in the page (index.html): gate.mjs's fold-* cases drive the viewport between
 * the cover's and the inner screen's sizes; these assert from inside the page, with no input in between.
 *
 * The WebView updates window.screen after a fold's resize event: [pinScreen] keeps the old screen's size over the
 * resize, as the phone's does for a moment, so it is judged with the old screen (hosts/wide.ts screenNow).
 */

/** Pins window.screen at [w]x[h] (headless Chromium's is 800x600 at any viewport): the phone's screen, or its lag. */
export function pinScreen(w, h) {
  Object.defineProperty(screen, "width", { configurable: true, get: () => w });
  Object.defineProperty(screen, "height", { configurable: true, get: () => h });
  return `${w}x${h}`;
}

/** Home's layout as rendered: wide or not, the dock's side - from the classes, as the eye sees them. */
export function homeLayout() {
  const h = document.querySelector(".home:not(.pull-screen)");
  if (!h) return null;
  return { wide: h.classList.contains("wide"), dock: /dock-(bottom|left|right)/.exec(h.className)?.[1] ?? "?" };
}

/**
 * Arms a watch for the next resize to [w]: home's layout read in the first frame drawn after it (the resize event's
 * own frame: rAF callbacks run before that frame's paint, after the signals' render). window.__foldSeen gets it.
 */
export function watchNextResize(w) {
  window.__foldSeen = null;
  const on = () => {
    if (innerWidth !== w) return;
    removeEventListener("resize", on);
    requestAnimationFrame(() => (window.__foldSeen = { ...homeLayout(), at: `${innerWidth}x${innerHeight}`, screen: `${screen.width}x${screen.height}` }));
  };
  addEventListener("resize", on);
}

/** The user's right dock unfolded (their setting), the bottom bar folded. */
export async function setUnfoldedRight() {
  const S = await window.__gw.mod("./state.ts");
  S.unfoldedDockPlacement.value = "right";
  S.editing.value = false;
  await window.__gw.frames(2);
}

/** A long press on home's empty space starting now (grid.tsx useEmptyPress), on the page under the tiles. */
export function pressEmpty() {
  const t = document.querySelector(".page:not(.away)") || document.querySelector(".pages");
  if (!t) return "no page to press on";
  const r = t.getBoundingClientRect();
  const at = { clientX: r.left + r.width / 2, clientY: r.bottom - 8, pointerId: 7, bubbles: true, isPrimary: true, button: 0 };
  t.dispatchEvent(new PointerEvent("pointerdown", at));
  window.__pressUp = () => t.dispatchEvent(new PointerEvent("pointerup", at));
  return "";
}
export async function editingNow() {
  return (await window.__gw.mod("./state.ts")).editing.value;
}
export function releasePress() {
  window.__pressUp?.();
}
