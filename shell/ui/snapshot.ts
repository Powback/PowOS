/**
 * Home's last frame, kept for the next load: before the shell's modules have loaded and compiled (half a second warm,
 * two cold - nothing on screen meanwhile), index.html puts home back as it was last seen - the pages, the dock, the
 * recent apps, their icons - and the shell's first render replaces it once it has the host's state (app.tsx).
 *
 * It's a picture, not the shell: nothing in it answers a tap (it's inert), and the parts that would show something
 * out of date are left empty - widgets' faces (a clock would show the wrong time), the switcher, the notification
 * panel, PowOS AI's chat - and it's home's first page, where a load opens. One per screen width, so a fold opens the layout of the screen it's on.
 * Saved in localStorage (the app's data: kept across updates) as home leaves the screen and once it has settled.
 */
import { drawer, editing, folder, menu, notif, screen, selected, sessionView } from "../state.ts";

/** Bumped (here and in index.html) when the markup changes so much that an old frame would show the wrong layout. */
const VERSION = 1;
const key = () => `powos.snapshot.${Math.round(innerWidth)}`;

/** Inside the frame, emptied: what would be out of date by the next load. */
const STALE = [".snapshot", ".recents", ".notif-panel .panel-body", ".ai-scroll", ".menu", ".menu-scrim", ".folder-scrim", ".carried", ".drop-spot"];
/** Kept as a box, its contents emptied: widgets show live state. */
const FACES = [".home-tile.widget", ".home-tile.appwidget", ".home-tile.panel"];

/** Saves the frame on screen, unless home is in the middle of something (a menu, the drawer, editing, a screen over it). */
export function saveSnapshot() {
  if (document.documentElement.dataset.mode !== "home" || document.body.classList.contains("booting")) return;
  if (drawer.value || menu.value || folder.value || editing.value || notif.value || screen.value.key || sessionView.value || selected.value) return;
  const body = document.body.cloneNode(true) as HTMLElement;
  for (const el of body.querySelectorAll(STALE.join(","))) el.remove();
  for (const el of body.querySelectorAll(FACES.join(","))) {
    // The face's frame stays (where the widget is, its card), its contents don't.
    const frame = el.firstElementChild?.cloneNode(false);
    el.replaceChildren(...(frame ? [frame] : []));
  }
  for (const el of body.querySelectorAll("script")) el.remove();
  // As a load opens: on home's first page (gesture.ts applyTrack's transforms at page 0), whatever page was on screen.
  const at = (sel: string, transform: string) => {
    const el = body.querySelector<HTMLElement>(sel);
    if (!el) return;
    el.style.transform = transform;
    el.classList.remove("sliding", "dragging");
  };
  at(".home", "translateX(calc(0% + 0px))");
  at(".ai-screen", "translateX(calc(-100% + 0px))");
  at(".page-track", "translateX(calc(0% + 0px))");
  try {
    localStorage.setItem(key(), JSON.stringify({ v: VERSION, style: document.documentElement.getAttribute("style") ?? "", html: body.innerHTML }));
  } catch {
    // full or unavailable: the next load starts blank, as before
  }
}

/** Whether index.html put a frame up, and its numbers (performance.now() when shown, its icons and when they were in). */
export const restored =
  (window as unknown as { __snapshot?: { at: number; icons: number; loaded: number; last: number; live?: number } }).__snapshot ?? null;

/**
 * Home itself in place of the frame: [renderHome] draws it into the body while the frame stays up, over the live page
 * kept hidden (index.html's .booting), until the live page has laid itself out - the grid is measured after its first
 * frame (grid.tsx measure), and that frame has every tile at no size. Then one goes, the other shows, in one frame.
 */
export function handOff(renderHome: () => void) {
  if (!restored) return renderHome();
  const frame = document.createElement("div");
  frame.className = "snapshot";
  frame.inert = true;
  frame.append(...document.body.childNodes);
  document.body.inert = false;
  document.body.classList.add("booting");
  renderHome();
  document.body.append(frame);
  let frames = 0;
  const settled = () => {
    const tile = document.querySelector<HTMLElement>("body > :not(.snapshot) .home-tile");
    return !tile || tile.offsetWidth > 0;
  };
  const tick = () => {
    // A few frames at most: a page that never lays out (an error) still shows itself, not the old frame forever.
    if (!settled() && ++frames < 30) return void requestAnimationFrame(tick);
    frame.remove();
    document.body.classList.remove("booting");
    restored!.live = performance.now();
  };
  requestAnimationFrame(tick);
}

/** From now on: kept as home leaves the screen, and once a moment after the shell has drawn. */
export function keepSnapshots() {
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) saveSnapshot();
  });
  addEventListener("pagehide", saveSnapshot);
  setTimeout(saveSnapshot, 3000);
}
