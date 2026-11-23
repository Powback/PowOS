/**
 * LD1 (the user, 11-23: "the drag to open as window works for the docked icons but not the recent ones"): every app
 * tile of the launcher and the dock starts the same drag. Scripted pointer events on one tile of each:
 * - the launcher's Recent, Suggested, a letter's apps (ui/launcherview.ts) and search's app rows: held then moved, the
 *   launcher's one drag (apps.tsx dragHome) - the app carried with toWindow (dockout.tsx: over an app, a window/half);
 * - the dock's recent apps, as its pinned ones: moved up off the dock with no hold, lifted out as a window's drag
 *   (home.tsx liftOut: fromDock + lifted); moved along the row it stays the row's (no carry: its scroll).
 * Each carry ends with a pointercancel (grid.tsx letGo: cancelled, nothing placed).
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const HOLD_MS = 520;

function fire(el, type, x, y) {
  el.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 11, buttons: type === "pointerup" ? 0 : 1, clientX: x, clientY: y }));
}

/** Presses [el], holds [m.hold] ms, moves it by [m.dx], [m.dy] in steps; the carry it started (or null). */
async function press(S, el, m) {
  const r = el.getBoundingClientRect();
  const x = r.x + r.width / 2, y = r.y + r.height / 2;
  fire(el, "pointerdown", x, y);
  await sleep(m.hold);
  for (let i = 1; i <= 4; i++) {
    fire(el, "pointermove", x + (m.dx * i) / 4, y + (m.dy * i) / 4);
    await sleep(16);
  }
  const c = S.carry.value;
  window.dispatchEvent(new PointerEvent("pointercancel", { pointerId: 11 }));
  fire(el, "pointercancel", x, y);
  S.carry.value = null;
  S.menu.value = null;
  return c;
}

const UP = { hold: 0, dx: 0, dy: -60 };
const ALONG = { hold: 0, dx: -60, dy: 0 };
const HELD_UP = { hold: HOLD_MS, dx: 0, dy: -60 };
const show = (c, flag) => (c ? `${c.app}${c[flag] ? `+${flag}` : ""}` : "none");

/** One tile of each launcher place: [name, its cell] - opened (and set) fresh for each. */
const PLACES = [
  ["recent", async () => document.querySelector(".drawer-page [data-section=recent] .app[data-key]")],
  ["suggested", async () => document.querySelector(".drawer-page [data-section=suggested] .app[data-key]")],
  ["letter", async (D) => ((D.launcherLetter.value = "S"), await sleep(200), document.querySelector(".drawer-page [data-view=letter] .app[data-key]"))],
  ["search", async (D, S) => ((S.query.value = "chrome"), await sleep(900), document.querySelector(".drawer .scr-row[data-key]"))],
];

/** A launcher place's tile, held and moved: the launcher's drag (toWindow). */
async function launcherPlace(S, D, [name, find], seen) {
  S.drawer.value = 1;
  await sleep(400);
  const el = await find(D, S);
  const c = el && (await press(S, el, HELD_UP));
  seen.push(`${name}:${show(c, "toWindow")}`);
  S.query.value = "";
  S.closeDrawer(true);
  await sleep(300);
  if (!el) return [`LD1 ${name}: no app tile to drag`];
  const ok = c && c.app === el.dataset.key && c.toWindow;
  return ok ? [] : [`LD1 ${name}: held and moved, ${el.dataset.key} isn't carried as the launcher's drag (carry ${JSON.stringify(c && { app: c.app, toWindow: c.toWindow })})`];
}

/** The dock's recent apps (its second page / section): out of the dock at once as the pinned ones; along, its scroll. */
async function dockRecent(S, seen) {
  const el = document.querySelector(".home > .dock .dock-recent .app[data-key]");
  if (!el) return ["LD1 dock recents: no recent app in the dock"];
  const c = await press(S, el, UP);
  seen.push(`dock-recent:${show(c, "lifted")}`);
  const fails = c && c.app === el.dataset.key && c.lifted && c.fromDock ? [] : [`LD1 dock recents: moved up off the dock, ${el.dataset.key} isn't lifted out as a window's drag`];
  const along = await press(S, el, ALONG);
  return along ? [...fails, `LD1 dock recents: moved along the row, it was carried (${along.app}) - the row's scroll is lost`] : fails;
}

export async function launcherDrags() {
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/drawer.tsx");
  const fails = [];
  const seen = [];
  for (const place of PLACES) fails.push(...(await launcherPlace(S, D, place, seen)));
  fails.push(...(await dockRecent(S, seen)));
  window.__launcherDrag = seen.join(" ");
  return fails;
}
