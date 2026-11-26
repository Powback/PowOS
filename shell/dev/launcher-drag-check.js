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

/**
 * LD2 (e2e 1125-1924, launcher-letter: "dragging a:com.oplus.camera/.Camera out opened no window"): a launcher tile held
 * and dragged mostly UP by a REAL finger (gate.mjs launcherDropCheck, CDP touches) opens its web window. The launcher's
 * list is touch-action pan-y: the browser took a vertical move past the hold as the list's scroll and sent the carry a
 * pointercancel (grid.tsx letGo: cancelled, nothing opened) - a sideways drag (the Recent row's, to the middle) never
 * showed it. In the page: unfolded home, a mock web-windows host with a window open on the page (the dock a taskbar),
 * the launcher open on [place]'s tile; where it is and where the finger takes it.
 */
export async function launcherDropSetup(place) {
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/drawer.tsx");
  const W = await importShim("./ui/webwindows.tsx");
  const H = await importShim("./hosts/wide.ts");
  const B = await importShim("./bridge.ts");
  H.wideHome.value = true;
  let next = 300;
  B.powos.webwindows = { enabled: async () => true, open: async () => ++next, close: async () => true, input: async () => true, minimise: async () => true, restore: async () => true };
  W.webWins.value = [{ id: 951, key: "a:gate.open", label: "Open", page: S.pages.value[Math.max(0, S.page.value)], x: 80, y: 120, w: 300, h: 240, live: true }];
  S.closeDrawer(true);
  D.launcherLetter.value = null;
  await sleep(300);
  S.drawer.value = 1;
  await sleep(500);
  if (place === "letter") {
    D.launcherLetter.value = "C";
    await sleep(300);
  }
  const sel = place === "letter" ? ".drawer-page [data-view=letter] .app[data-key]" : ".drawer-page [data-section=recent] .app[data-key]";
  // The lowest tile: room above it for a long drag up.
  const cells = [...document.querySelectorAll(sel)].filter((a) => !a.dataset.key.startsWith("l:") && a.dataset.key !== "pow");
  const el = cells.at(-1);
  if (!el) return { err: `no ${place} tile (${sel})` };
  const r = el.getBoundingClientRect();
  const x = r.x + r.width / 2, y = r.y + r.height / 2;
  return { key: el.dataset.key, x, y, to: { x: x + 40, y: Math.max(80, y - 260) } };
}

/** After the drop: did [key] open as a web window (polled up to 3 s), and how did the carry end. */
export async function launcherDropResult(key) {
  const W = await importShim("./ui/webwindows.tsx");
  const S = await importShim("./state.ts");
  for (let t = 0; t < 30 && !W.webWins.value.some((w) => w.key === key); t++) await sleep(100);
  const opened = W.webWins.value.some((w) => w.key === key);
  const stuck = !!S.carry.value;
  S.carry.value = null;
  W.webWins.value = [];
  S.closeDrawer(true);
  return { opened, stuck };
}
