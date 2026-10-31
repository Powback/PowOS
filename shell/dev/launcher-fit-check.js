/**
 * The launcher overlay's panel fits its window (index.html?mode=pull): gate.mjs's launcher-fit-* cases.
 * LP1 (the user, 2026-10-31: "I can't see the bottom of the search bar"): PowOS AI's panel's pill ends above the
 * navigation inset (or the keyboard), folded and unfolded, whatever side home's dock is on.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const INSETS = { top: 45.6, bottom: 16.3 };
const KEYBOARD = 330;

/** The pill the user types in: the panel's own (wide) or the launcher's bar pill, whichever is shown. */
function shownPill() {
  for (const sel of [".pull-screen .ai-compose", ".pull-screen > .bar .bar-pill", ".pull-screen > .bar"]) {
    const el = document.querySelector(sel);
    if (!el) continue;
    const r = el.getBoundingClientRect();
    if (r.height > 0 && getComputedStyle(el).visibility !== "hidden" && !el.closest("[style*='visibility: hidden']")) return { sel, r };
  }
  return null;
}

/** PowOS AI's panel opened: its pill above the nav inset or the keyboard ([at]: the case, for the message). */
async function aiPillFits(E, keyboard, at) {
  E.emit("pull.begin", { kind: "ai" });
  E.emit("pull.end", { open: true });
  await sleep(500);
  const pill = shownPill();
  const floor = innerHeight - (keyboard ? KEYBOARD : INSETS.bottom);
  E.emit("pull.end", { open: false });
  await sleep(500);
  if (!pill) return [`${at}: PowOS AI's panel shows no pill`];
  if (pill.r.bottom <= floor + 0.5) return [];
  return [`${at}: PowOS AI's pill (${pill.sel}) ends at ${Math.round(pill.r.bottom)}, below ${Math.round(floor)} (the viewport's foot less the ${keyboard ? "keyboard" : "nav inset"})`];
}

/** [position]: home's dock placement; [keyboard]: up as it opens. The failures, empty when it fits. */
export async function launcherFits(position, keyboard) {
  const S = await importShim("./state.ts");
  const E = window.__mockEvents;
  const at = `${innerWidth}x${innerHeight} dock-${position}${keyboard ? " +keyboard" : ""}`;
  S.dockTry.value = position;
  E.emit("system.insets", { top: INSETS.top, bottom: INSETS.bottom, left: 0, right: 0, keyboard: keyboard ? KEYBOARD : 0 });
  return aiPillFits(E, keyboard, at);
}
